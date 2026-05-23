#!/usr/bin/env bash
#
# vibez hook script.
#
# Dispatches Claude Code lifecycle events to the Vibez Firebase backend
# as push notifications. The user's Vibez ID is generated on first
# SessionStart (or via /vibez:setup) and persisted at
# ~/.config/vibez/vibez-id. VIBEZ_ID env var overrides if set.
#
# Hooks must never block Claude — this script always exits 0, network
# failures are swallowed.

set -uo pipefail

EVENT="${1:-}"

CONFIG_DIR="${HOME}/.config/vibez"
ID_FILE="${CONFIG_DIR}/vibez-id"
LEGACY_TOPIC_FILE="${CONFIG_DIR}/topic"
LOG_FILE="${CONFIG_DIR}/log"
BACKEND_URL="${VIBEZ_BACKEND_URL:-https://us-central1-vibez-backend.cloudfunctions.net}"

# Where setup.sh lives. CLAUDE_PLUGIN_ROOT is set by Claude Code when
# invoking the hook; we fall back to BASH_SOURCE-relative for direct
# `bash notify.sh` runs (mostly _selftest).
SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts"

# One-shot migration from the old claude-ntfy-named directory.
OLD_CONFIG_DIR="${HOME}/.config/claude-ntfy"
if [ -d "${OLD_CONFIG_DIR}" ] && [ ! -d "${CONFIG_DIR}" ]; then
    mv "${OLD_CONFIG_DIR}" "${CONFIG_DIR}" 2>/dev/null || true
fi

mkdir -p "${CONFIG_DIR}" 2>/dev/null || true
chmod 700 "${CONFIG_DIR}" 2>/dev/null || true

log() {
    printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >>"${LOG_FILE}" 2>/dev/null || true
}

# Read stdin once if present, into INPUT.
INPUT=""
if [ ! -t 0 ]; then
    INPUT="$(cat 2>/dev/null || true)"
fi

# Resolve the Vibez ID: env wins, else file.
VIBEZ_ID="${VIBEZ_ID:-}"
if [ -z "${VIBEZ_ID}" ] && [ -f "${ID_FILE}" ]; then
    VIBEZ_ID="$(cat "${ID_FILE}" 2>/dev/null | tr -d '[:space:]')"
fi

# Lazy bridge to setup.sh for first-run ID generation. Keeps the
# wordlist in one place (setup.sh) instead of duplicating it here.
ensure_vibez_id() {
    if [ -n "${VIBEZ_ID}" ]; then
        return 0
    fi
    local setup="${SCRIPT_DIR}/setup.sh"
    if [ -x "${setup}" ] || [ -f "${setup}" ]; then
        # Discard human-readable output; we only care about the side
        # effect of writing the ID file.
        bash "${setup}" show >/dev/null 2>&1 || true
        if [ -f "${ID_FILE}" ]; then
            VIBEZ_ID="$(cat "${ID_FILE}" 2>/dev/null | tr -d '[:space:]')"
        fi
    fi
}

# POST a Vibez payload to the backend's /notify endpoint. Title and
# body are required; the four trailing args are the same control axes
# the old ntfy bridge carried as `_vibez:...` tags.
post_vibez() {
    local title="$1"
    local body="$2"
    local event="${3:-}"
    local shield="${4:-}"
    local session="${5:-}"
    local agent="${6:-}"

    if [ -z "${VIBEZ_ID}" ]; then
        log "skip: no Vibez ID configured (event=${EVENT})"
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log "skip: jq not installed (event=${EVENT})"
        return 0
    fi

    local payload
    payload=$(jq -nc \
        --arg vibezId "${VIBEZ_ID}" \
        --arg title "${title}" \
        --arg body "${body}" \
        --arg event "${event}" \
        --arg shield "${shield}" \
        --arg session "${session}" \
        --arg agent "${agent}" \
        '{vibezId:$vibezId,title:$title,body:$body}
         + (if $event   != "" then {event:$event}     else {} end)
         + (if $shield  != "" then {shield:$shield}   else {} end)
         + (if $session != "" then {session:$session} else {} end)
         + (if $agent   != "" then {agent:$agent}     else {} end)')

    curl -fsS --max-time 5 \
        -H "content-type: application/json" \
        -X POST -d "${payload}" \
        "${BACKEND_URL}/notify" >/dev/null 2>&1 \
        && log "sent: ${title} (event=${event})" \
        || log "send failed: ${title} (event=${event})"
}

# Per-session pending marker — set by PreToolUse:AskUserQuestion so the
# Notification hook can skip its near-duplicate push (~5-7s after the
# picker appears). PostToolUse:AskUserQuestion clears it; Stop and
# UserPromptSubmit clear defensively. Marker file holds an epoch-second
# timestamp and auto-expires after PENDING_TTL_SECONDS, so a missed
# PostToolUse (Claude Code crash, chat closed mid-question, etc.) can't
# silently silence every later Notification for the rest of the session.
PENDING_TTL_SECONDS=30

pending_marker_path() {
    local sid="$1"
    [ -z "${sid}" ] || [ "${sid}" = "nosid" ] && return 1
    printf '%s/pending.%s' "${CONFIG_DIR}" "${sid}"
}

mark_pending() {
    local sid="$1" path
    path="$(pending_marker_path "${sid}")" || return 0
    date +%s >"${path}" 2>/dev/null || true
}

clear_pending() {
    local sid="$1" path
    path="$(pending_marker_path "${sid}")" || return 0
    rm -f "${path}" 2>/dev/null || true
}

has_pending() {
    local sid="$1" path ts now
    path="$(pending_marker_path "${sid}")" || return 1
    [ -f "${path}" ] || return 1
    ts="$(cat "${path}" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    if [ "$((now - ts))" -gt "${PENDING_TTL_SECONDS}" ]; then
        rm -f "${path}" 2>/dev/null || true
        return 1
    fi
    return 0
}

# True when the argument is a slash-command invocation — either the bare
# "/foo" form (.prompt of a UserPromptSubmit) or the
# "<command-name>...</command-name>" wrapper Claude Code stores in the
# transcript. Used to suppress phone pushes for scheduled cron-style
# commands that would otherwise spam the phone with bot-driven traffic.
is_slash_command() {
    case "$1" in
        "<command-name>"*|"<command-message>"*|"/"[a-zA-Z]*) return 0 ;;
    esac
    return 1
}

# Pull a JSON field with a default, swallowing jq errors.
jq_get() {
    local query="$1"
    local default="${2:-}"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "${INPUT}" | jq -r "${query} // empty" 2>/dev/null || printf '%s' "${default}"
    else
        printf '%s' "${default}"
    fi
}

# Look up the desktop Claude app's own conversation title. The desktop
# app stores per-session metadata under
#   ~/Library/Application Support/Claude/claude-code-sessions/<workspace>/<some>/local_<uuid>.json
# with a .title field ("auto"-generated like "Fix plugin showing environment name…")
# and a .cliSessionId that matches the hook's session_id. This is the
# title the user actually sees in the desktop app's sidebar.
read_desktop_app_title() {
    local sid="$1"
    [ -z "${sid}" ] && return 0
    [ "${sid}" = "nosid" ] && return 0
    command -v jq >/dev/null 2>&1 || return 0

    local base="${HOME}/Library/Application Support/Claude/claude-code-sessions"
    [ -d "${base}" ] || return 0

    # Fast pre-filter via grep — the bare UUID is unique enough to land
    # on the right file with no false positives. Then validate via jq
    # so we don't accidentally pick a file that mentions the UUID for
    # some other reason.
    local match
    match=$(grep -rl --include='local_*.json' -F "${sid}" "${base}" 2>/dev/null | head -n 1)
    [ -z "${match}" ] && return 0

    jq -r --arg sid "${sid}" '
        select(.cliSessionId == $sid)
        | .title // empty
    ' "${match}" 2>/dev/null
}

# Best identifier we can give the user for "which conversation this is".
# Tries, in order:
#   1. The desktop Claude app's own .title for this session (lookup
#      by cliSessionId in ~/Library/Application Support/Claude/...).
#      This is the title the user actually sees in the app.
#   2. ai-title in the transcript (CLI auto-generated label).
#   3. lastPrompt in the transcript (CLI writes this synchronously;
#      desktop app writes it AFTER hooks fire, so often empty).
#   4. The latest "user" record's string content (desktop app's
#      synchronously-written prompt text, used while the app hasn't
#      generated its real title yet).
#   5. The $hint argument, used by user-prompt-submit which has the
#      typed prompt directly even when the transcript doesn't exist.
#   6. The $fallback argument (usually the project basename).
# Caps at 60 chars with a trailing ellipsis if longer.
read_conversation_title() {
    local transcript="$1"
    local fallback="${2:-Claude Code}"
    local hint="${3:-}"
    local sid="${4:-}"

    local title=""

    # Desktop app's own title takes priority — it's what the user sees
    # in their app sidebar, so the iPhone matching it is least surprising.
    title=$(read_desktop_app_title "${sid}")

    if [ -z "${title}" ] && [ -n "${transcript}" ] && [ -f "${transcript}" ] && command -v jq >/dev/null 2>&1; then
        title=$(jq -r '
            select(.type == "ai-title")
            | .aiTitle // empty
        ' "${transcript}" 2>/dev/null \
            | grep -v '^[[:space:]]*$' \
            | tail -n 1)

        if [ -z "${title}" ]; then
            title=$(jq -r '
                select(.type == "last-prompt")
                | .lastPrompt // empty
            ' "${transcript}" 2>/dev/null \
                | grep -v '^[[:space:]]*$' \
                | tail -n 1 \
                | tr '\n' ' ')
        fi

        # Desktop fallback while the app hasn't generated its title yet:
        # pull the latest user record whose content is a plain string
        # (CLI user records are arrays — last-prompt covers the CLI case).
        if [ -z "${title}" ]; then
            title=$(jq -r '
                select(.type == "user" and (.message.content | type == "string"))
                | .message.content
            ' "${transcript}" 2>/dev/null \
                | grep -v '^[[:space:]]*$' \
                | tail -n 1 \
                | tr '\n' ' ')
        fi
    fi

    # Hint path: typically .prompt from a user-prompt-submit hook,
    # used when the transcript file doesn't exist yet (desktop app
    # creates the file lazily on first user message).
    if [ -z "${title}" ] && [ -n "${hint}" ]; then
        title="${hint}"
    fi

    if [ -z "${title}" ]; then
        printf '%s' "${fallback}"
        return
    fi

    # Cap at 72 chars — the title is the conversation name on its own;
    # status (done / needs-input / replied) lives in the event field.
    if [ "${#title}" -gt 72 ]; then
        printf '%s…' "${title:0:71}"
    else
        printf '%s' "${title}"
    fi
}

# Read the current "last assistant text" from the transcript file.
# Truncates to 160 chars and appends a single-char ellipsis when cut,
# so consumers can tell the body was clipped instead of just stopping
# mid-sentence.
read_last_text() {
    local transcript="$1"
    local raw
    raw=$(jq -r '
        select(.type == "assistant")
        | .message.content[]?
        | select(.type == "text")
        | .text
    ' "${transcript}" 2>/dev/null \
        | grep -v '^[[:space:]]*$' \
        | tail -n 1 \
        | tr '\n' ' ')
    # Drop trailing space from the tr above.
    raw="${raw% }"

    if [ "${#raw}" -gt 160 ]; then
        printf '%s…' "${raw:0:159}"
    else
        printf '%s' "${raw}"
    fi
}

last_assistant_excerpt() {
    local transcript
    transcript="$(jq_get '.transcript_path')"
    [ -z "${transcript}" ] && return 0
    [ ! -f "${transcript}" ] && return 0
    command -v jq >/dev/null 2>&1 || return 0

    # Per-transcript cache: stores the last excerpt we've already sent
    # for this session. Stop fires before Claude flushes the
    # just-finished assistant.text — a naive read returns the prior
    # turn's text. Polling + dedupe against this cache fixes the
    # off-by-one.
    local hash cache_file previous=""
    hash="$(printf '%s' "${transcript}" | shasum 2>/dev/null | cut -c 1-12)"
    cache_file="${CONFIG_DIR}/last_excerpt.${hash}"
    [ -f "${cache_file}" ] && previous="$(cat "${cache_file}" 2>/dev/null)"

    # Brief initial pause so an in-flight write has a chance to land.
    sleep 0.4

    local excerpt="" attempt
    for attempt in 1 2 3 4 5 6; do
        excerpt="$(read_last_text "${transcript}")"
        if [ -n "${excerpt}" ] && [ "${excerpt}" != "${previous}" ]; then
            break
        fi
        sleep 0.35
    done

    # If after ~2.5s of polling the excerpt is still empty or identical
    # to what we sent last turn, the just-finished response hasn't been
    # flushed yet. Return empty so the caller skips the push entirely —
    # a generic "Claude finished a turn." is just noise.
    if [ -z "${excerpt}" ] || [ "${excerpt}" = "${previous}" ]; then
        log "stop: no fresh excerpt after polling (transcript=${transcript})"
        return 0
    fi

    printf '%s' "${excerpt}" >"${cache_file}"
    printf '%s' "${excerpt}"
}

# Returns 0 (true) when the assistant excerpt looks like Claude is waiting
# on the user (a "?" anywhere outside code fences, or last sentence
# matches a common asking phrase). 1 (false) otherwise. Operates on the
# already-extracted excerpt so we don't re-read the transcript.
last_turn_is_asking() {
    local text="$1"
    [ -z "${text}" ] && return 1

    # Strip anything that displays as code or as a literal quoted span,
    # so a "?" inside a code sample or quoted phrase doesn't false-positive.
    # Order matters: fenced blocks first (multi-line), then inline spans
    # (paired single-line). Apostrophes are too noisy to handle safely
    # (don't / can't / it's), so single quotes are left alone.
    local cleaned
    cleaned="$(printf '%s' "${text}" \
        | awk 'BEGIN{infence=0}
               /^```/ { infence = 1 - infence; next }
               { if (!infence) print }' \
        | sed -E 's/`[^`]*`//g' \
        | sed -E 's/"[^"]*"//g' \
        | sed -E 's/“[^”]*”//g')"

    # A "?" anywhere in the cleaned text → asking. Catches mid-paragraph
    # questions that a last-sentence-only check would miss (e.g.
    # "Want me to retry? Anyway, moving on.").
    case "${cleaned}" in
        *\?*) return 0 ;;
    esac

    # No "?". Fall back to phrase matching on the last sentence so
    # directive asks ("Let me know what you want.") still register.
    local last
    last="$(printf '%s' "${cleaned}" \
        | tr '\n' ' ' \
        | sed -E 's/([.!?]+)[[:space:]]+/\1\n/g' \
        | grep -v '^[[:space:]]*$' \
        | tail -n 1 \
        | sed -E 's/^[[:space:]]+//')"

    [ -z "${last}" ] && return 1

    # Common interrogative openers, case-insensitive.
    local lower
    lower="$(printf '%s' "${last}" | tr '[:upper:]' '[:lower:]')"
    case "${lower}" in
        "should i "*|"do you want"*|"would you like"*|"would you prefer"*|\
        "want me to"*|"shall i"*|"ready to"*|"let me know"*|\
        "which one"*|"which of"*|"how would you"*|"do we"*)
            return 0 ;;
    esac

    return 1
}

case "${EVENT}" in

    session-start)
        if [ -z "${VIBEZ_ID}" ]; then
            ensure_vibez_id
            if [ -n "${VIBEZ_ID}" ]; then
                log "generated Vibez ID ${VIBEZ_ID}"
                msg="vibez plugin: your Vibez ID is ${VIBEZ_ID}. Type it into the Vibez iPhone app (Set up notifications widget) to pair this Mac with your phone. Run /vibez:setup to surface it again."
                # systemMessage = visible banner shown to the user.
                # additionalContext = injected so Claude can answer follow-ups.
                printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"vibez plugin first-run setup complete. Vibez ID: %s. The iOS app pairs with this ID via the registerPushToken Cloud Function."}}\n' \
                    "${msg}" "${VIBEZ_ID}"
            else
                log "vibez ID generation failed"
            fi
        else
            log "session-start (Vibez ID exists)"
        fi
        # Clean up the legacy ntfy topic file if it's still around.
        [ -f "${LEGACY_TOPIC_FILE}" ] && rm -f "${LEGACY_TOPIC_FILE}" 2>/dev/null || true
        ;;

    stop)
        cwd="$(jq_get '.cwd')"
        sid="$(jq_get '.session_id' 'nosid')"
        proj="$(basename "${cwd:-unknown}")"
        transcript="$(jq_get '.transcript_path')"
        convo_title="$(read_conversation_title "${transcript}" "${proj}" "" "${sid}")"
        is_slash_command "${convo_title}" && exit 0
        excerpt="$(last_assistant_excerpt)"
        # Skip when polling didn't surface a fresh excerpt — sending a
        # generic "Claude finished a turn." is just noise on the phone.
        if [ -z "${excerpt}" ]; then
            exit 0
        fi
        if last_turn_is_asking "${excerpt}"; then
            post_vibez "${convo_title}" "${excerpt}" "needs-input" "on" "${sid}" "cc"
        else
            post_vibez "${convo_title}" "${excerpt}" "done" "on" "${sid}" "cc"
        fi
        clear_pending "${sid}"
        ;;

    pre-tool-use)
        # AskUserQuestion blocks Claude mid-turn waiting for the user's
        # pick. Stop doesn't fire here (stop_reason is tool_use, not
        # end_turn), so this PreToolUse hook is what pings the phone
        # while the picker is pending. The Notification hook is
        # intentionally not registered — it would fire a second
        # needs-input push ~5-7s later and look like a duplicate.
        tool_name="$(jq_get '.tool_name')"
        [ "${tool_name}" = "AskUserQuestion" ] || exit 0

        sid="$(jq_get '.session_id' 'nosid')"
        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        proj="$(basename "${cwd:-unknown}")"
        convo_title="$(read_conversation_title "${transcript}" "${proj}" "" "${sid}")"
        is_slash_command "${convo_title}" && exit 0

        question="$(jq_get '.tool_input.questions[0].question')"
        [ -z "${question}" ] && question="Claude is asking a question."
        if [ "${#question}" -gt 160 ]; then
            question="${question:0:159}…"
        fi
        post_vibez "${convo_title}" "${question}" "needs-input" "on" "${sid}" "cc"
        mark_pending "${sid}"
        ;;

    post-tool-use)
        # Two paths land here now that PostToolUse matches every tool:
        #
        # 1. AskUserQuestion just returned — the user picked an option
        #    (or clicked Clarify). Picker answers arrive as tool_result
        #    on the next user record, NOT as a typed prompt, so
        #    UserPromptSubmit doesn't fire. This is the only hook that
        #    can lift the shield the PreToolUse push raised. Always
        #    push shield:off.
        #
        # 2. Any other tool — this fires whenever Claude runs a tool
        #    (Bash, Edit, Write, …). When Claude needed permission, the
        #    Notification hook fired earlier and set the pending marker;
        #    the tool only ran because the user pressed 1/2 to grant it.
        #    Push shield:off in that case and clear pending. When no
        #    marker is set, Claude is just autonomously running tools
        #    (accept-edits / bypass / pre-approved) — exit silently so
        #    we don't drown the phone with one shield:off per tool call.
        #
        #    File existence is checked directly instead of has_pending
        #    so the TTL doesn't apply: the marker's 30s window exists
        #    only to dedup Notification's near-duplicate push, but the
        #    user's permission response itself can take longer than
        #    that. PostToolUse firing for the gated tool is itself
        #    proof the user responded, no matter how long they took.
        tool_name="$(jq_get '.tool_name')"
        sid="$(jq_get '.session_id' 'nosid')"

        case "${tool_name}" in
            "AskUserQuestion")
                ;;
            *)
                marker="$(pending_marker_path "${sid}")" || exit 0
                [ -f "${marker}" ] || exit 0
                ;;
        esac

        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        proj="$(basename "${cwd:-unknown}")"
        convo_title="$(read_conversation_title "${transcript}" "${proj}" "" "${sid}")"
        is_slash_command "${convo_title}" && exit 0

        # AskUserQuestion's tool_response is the user's actual answer,
        # which is meaningful body content. For shell/edit/etc. the
        # response is command output that may be huge or contain
        # secrets — keep it generic, mirroring the Codex side.
        case "${tool_name}" in
            "AskUserQuestion")
                body="$(jq_get '.tool_response.content')"
                [ -z "${body}" ] && body="(answered)"
                ;;
            *)
                body="(approved: ${tool_name})"
                ;;
        esac
        if [ "${#body}" -gt 160 ]; then
            body="${body:0:159}…"
        fi
        post_vibez "${convo_title}" "${body}" "replied" "off" "${sid}" "cc"
        clear_pending "${sid}"
        ;;

    user-prompt-submit)
        # User replied in Claude — fire a push with shield:off so the
        # iOS app lifts the shield for this session. Body is mostly
        # informational; the Vibez app routes on the event + shield axes.
        sid="$(jq_get '.session_id' 'nosid')"
        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        proj="$(basename "${cwd:-unknown}")"
        prompt="$(jq_get '.prompt')"
        is_slash_command "${prompt}" && exit 0
        # Pass the current prompt as a hint — for desktop sessions the
        # transcript file frequently doesn't exist yet at this point,
        # so falling back to .prompt beats falling back to basename.
        convo_title="$(read_conversation_title "${transcript}" "${proj}" "${prompt}" "${sid}")"
        # Truncate prompt to a short excerpt for the body
        if [ "${#prompt}" -gt 80 ]; then
            prompt="${prompt:0:79}…"
        fi
        [ -z "${prompt}" ] && prompt="(replied)"
        post_vibez "${convo_title}" "${prompt}" "replied" "off" "${sid}" "cc"
        clear_pending "${sid}"
        ;;

    notification)
        # Claude Code fires Notification when Claude needs the user — either
        # asking permission to run a tool (Bash, Edit, Write, etc.) or after
        # ~60s of idle awaiting a response. This hook is the only signal for
        # permission prompts because the plugin's PreToolUse matcher is
        # AskUserQuestion-only.
        #
        # Skip when an AskUserQuestion PreToolUse just pushed for this
        # session — Claude Code fires Notification ~5-7s after the picker
        # appears, which would otherwise look like a duplicate. The marker
        # is cleared by PostToolUse:AskUserQuestion (or Stop /
        # UserPromptSubmit as a safety net).
        sid="$(jq_get '.session_id' 'nosid')"
        message="$(jq_get '.message')"
        log "notification: received (sid=${sid}, message=${message})"

        if has_pending "${sid}"; then
            log "notification: skip — AskUserQuestion still pending for ${sid}"
            exit 0
        fi

        # Filter out the 60s-idle reminder. Anchored prefix match against
        # Claude Code's default idle text — won't accidentally catch a
        # permission message that happens to contain the substring later.
        case "${message}" in
            "Claude is waiting"*)
                log "notification: skip — idle reminder"
                exit 0 ;;
        esac

        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        proj="$(basename "${cwd:-unknown}")"
        convo_title="$(read_conversation_title "${transcript}" "${proj}" "" "${sid}")"
        is_slash_command "${convo_title}" && { log "notification: skip — slash command title"; exit 0; }

        [ -z "${message}" ] && message="Claude needs your input."
        if [ "${#message}" -gt 160 ]; then
            message="${message:0:159}…"
        fi
        post_vibez "${convo_title}" "${message}" "needs-input" "on" "${sid}" "cc"
        # Mark pending so the next PostToolUse can detect the user's
        # response to this permission prompt and push shield:off. The
        # AskUserQuestion path marks pending via PreToolUse; this is
        # the equivalent for tool-permission prompts that arrive via
        # Notification instead.
        mark_pending "${sid}"
        ;;

    _selftest)
        pass=0; fail=0
        check() {
            local name="$1" input="$2" expected="$3" got
            if last_turn_is_asking "$input"; then got=1; else got=0; fi
            if [ "$got" = "$expected" ]; then
                pass=$((pass+1))
                printf 'PASS %s\n' "$name"
            else
                fail=$((fail+1))
                printf 'FAIL %s (expected=%s got=%s)\n' "$name" "$expected" "$got"
            fi
        }
        check "trailing-q"       "Should I commit this?"          1
        check "mid-q"            "I changed X. Did that work?"     1
        check "no-q"             "I committed the change."         0
        check "code-fence"       "$(printf 'See:\n```bash\nrm -rf /?\n```\nDone.')" 0
        check "phrase-letmeknow" "Let me know if you want this."   1
        check "phrase-done"      "All done."                       0
        check "phrase-shouldi"   "Should I rebase before merging?" 1
        check "trailing-period"  "Looks good."                     0
        check "mid-q-not-trailing" "Want me to retry? Anyway, moving on." 1
        check "mid-q-multi-sentence" "Implemented X. Curious about that bug? Done for now." 1
        check "inline-backtick-q"  "Method \`isReady?\` returns bool. Done."         0
        check "quoted-q-only"      "Set placeholder to \"Should I commit?\" — done." 0
        check "quoted-plus-real-q" "Renamed \`foo?\`. Anything else?"                1
        check "smart-quoted-q"     "Updated to “Should I commit?” — done."           0
        printf '%d passed, %d failed\n' "$pass" "$fail"
        if [ "$fail" = "0" ]; then exit 0; else exit 1; fi
        ;;

    *)
        log "unknown event: ${EVENT}"
        ;;
esac

exit 0
