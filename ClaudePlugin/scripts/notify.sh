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

# One-shot migration from the old claude-ntfy-named directory used by the
# pre-0.9 Claude Code plugin. Same machine, same ID, same pairing.
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

# Hard-cap a payload field at N chars with a trailing ellipsis. Call
# sites already clip for display (72/160); this is the defensive floor
# inside post_vibez itself so no future call site can bypass clipping.
# Server mirrors these caps (title 100 / body 200) and clamps too.
# Note: ${#raw} counts bytes under a C locale (chars under UTF-8) — a
# multibyte cut is possible there; the server's surrogate-safe clamp
# is the authoritative bound either way.
clamp_field() {
    local raw="$1" max="$2"
    if [ "${#raw}" -gt "${max}" ]; then
        printf '%s…' "${raw:0:$((max - 1))}"
    else
        printf '%s' "${raw}"
    fi
}

# Per-session block debounce. An agent can fire several block-type
# events for one conversation within seconds — sequential question
# asks before the user answers the first, or paired hooks double-
# firing the same ask. The first shield:on of a burst blocks +
# banners the phone; followers inside the window are pure noise
# (the phone is already blocked). A shield:on send is therefore
# SKIPPED when an AGENT event (shield:on, sent or suppressed) for
# the same session landed within the last
# VIBEZ_BLOCK_DEBOUNCE_SECONDS. shield:off (replies) is invisible
# to the debounce in BOTH directions: it always sends (it's what
# unblocks the phone) and it never touches the stamp — a reply must
# not silence the ask/done that lands seconds later; that's real
# agent activity, not a duplicate. Stamp files hold an epoch
# second; 0 disables the debounce.
DEBOUNCE_SECONDS="${VIBEZ_BLOCK_DEBOUNCE_SECONDS:-5}"
case "${DEBOUNCE_SECONDS}" in
    ''|*[!0-9]*) DEBOUNCE_SECONDS=5 ;;
esac

lastevent_path() {
    local sid="$1"
    [ -z "${sid}" ] || [ "${sid}" = "nosid" ] && return 1
    printf '%s/lastevent.%s' "${CONFIG_DIR}" "${sid}"
}

mark_event() {
    local sid="$1" path
    path="$(lastevent_path "${sid}")" || return 0
    date +%s >"${path}" 2>/dev/null || true
}

clear_event() {
    local sid="$1" path
    path="$(lastevent_path "${sid}")" || return 0
    rm -f "${path}" 2>/dev/null || true
}

within_debounce_window() {
    local sid="$1" path ts now delta
    [ "${DEBOUNCE_SECONDS}" -gt 0 ] || return 1
    path="$(lastevent_path "${sid}")" || return 1
    [ -f "${path}" ] || return 1
    ts="$(tr -cd '0-9' <"${path}" 2>/dev/null)"
    [ -n "${ts}" ] || return 1
    now="$(date +%s)"
    delta="$((now - ts))"
    # A future-dated stamp (clock stepped backward mid-session) must
    # not debounce — a negative delta would pass -lt until wall-clock
    # catches up, eating every block for the session in the meantime.
    # Check-then-stamp is also not atomic across hook processes: two
    # near-simultaneous events can both pass and both send. Accepted —
    # worst case is the pre-debounce behavior, one extra banner.
    [ "${delta}" -ge 0 ] && [ "${delta}" -lt "${DEBOUNCE_SECONDS}" ]
}

# POST a Vibez payload to the backend's /notify endpoint. Title and
# body are required; the four trailing args become the event / shield /
# session / agent fields of the JSON payload (omitted when empty).
post_vibez() {
    local title="$1"
    local body="$2"
    local event="${3:-}"
    local shield="${4:-}"
    local session="${5:-}"
    local agent="${6:-}"
    title="$(clamp_field "${title}" 100)"
    body="$(clamp_field "${body}" 200)"
    session="${session:0:128}"

    if [ -z "${VIBEZ_ID}" ]; then
        log "skip: no Vibez ID configured (event=${EVENT})"
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log "skip: jq not installed (event=${EVENT})"
        return 0
    fi

    # Same-conversation debounce: skip block-type sends fired within
    # the window of this session's last AGENT event. Suppressed sends
    # still refresh the stamp (rolling window), so a machine-gun burst
    # stays silent for its whole run, not just its first few seconds.
    if [ "${shield}" = "on" ] && within_debounce_window "${session}"; then
        mark_event "${session}"
        log "debounced: ${title} (event=${event} session=${session})"
        return 0
    fi

    # Claim the stamp BEFORE the network call, not after — shield:on
    # only, since the stamp tracks agent block events exclusively.
    # Hooks run in parallel (Codex fires paired events in the same
    # second); a stamp written only on curl success leaves a 0.5-5s
    # hole during which a concurrent shield:on sees "no stamp" and
    # double-sends. Claiming here narrows the race to the one-liner
    # above. A failed send rolls the claim back (below) so a network
    # blip can't leave a phantom stamp that silences the burst's next
    # event.
    [ "${shield}" = "on" ] && mark_event "${session}" || true

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

    if curl -fsS --max-time 5 \
        -H "content-type: application/json" \
        -X POST -d "${payload}" \
        "${BACKEND_URL}/notify" >/dev/null 2>&1; then
        log "sent: ${title} (event=${event})"
    else
        log "send failed: ${title} (event=${event})"
        # Roll the claim back — shield:on only (off never claimed, and
        # clearing here would erase a legitimate agent stamp): the
        # phone never got this push, so the next agent event for the
        # session must not be debounced against it.
        [ "${shield}" = "on" ] && clear_event "${session}" || true
    fi
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

# Read the current "last assistant text" from the transcript file, in
# full. No truncation here: last_turn_is_asking must see the entire
# message (the question that flips done→needs-input is often past the
# 160-char display cut), so clipping happens at the call site via
# clip_body — mirroring the Codex plugin's stop handler.
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
    printf '%s' "${raw% }"
}

# Cap a string at 160 chars for the push body, with a trailing ellipsis
# so consumers can tell the body was clipped instead of just stopping
# mid-sentence. Same implementation as the Codex plugin's clip_body.
clip_body() {
    local raw="$1"
    raw="$(printf '%s' "${raw}" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g;s/^[[:space:]]+//;s/[[:space:]]+$//')"
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
        # Sweep stale debounce stamps so dead sessions don't pile up.
        # (BSD find: -mtime +1 deletes after ~2 days. Stamps go inert
        # seconds after the window closes anyway — this is hygiene.)
        find "${CONFIG_DIR}" -maxdepth 1 -name 'lastevent.*' -mtime +1 -delete 2>/dev/null || true
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
        # Classify on the full excerpt, clip only the push body — the
        # question that flips done→needs-input is often past the
        # 160-char display cut.
        body="$(clip_body "${excerpt}")"
        if last_turn_is_asking "${excerpt}"; then
            post_vibez "${convo_title}" "${body}" "needs-input" "on" "${sid}" "cc"
        else
            post_vibez "${convo_title}" "${body}" "done" "on" "${sid}" "cc"
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

        # Stop-path regression: classification must see the FULL assistant
        # text. A question past the 160-char display clip was previously
        # cut off before last_turn_is_asking ran and misread as done.
        check_eq() {
            local name="$1" got="$2" expected="$3"
            if [ "${got}" = "${expected}" ]; then
                pass=$((pass+1))
                printf 'PASS %s\n' "$name"
            else
                fail=$((fail+1))
                printf 'FAIL %s (expected=[%s] got=[%s])\n' "$name" "$expected" "$got"
            fi
        }
        long_q="Some of what we're working on might be easier to explain if I can show it to you in a web browser. I can put together mockups, diagrams, comparisons, and other visuals as we go, especially for the permission screens and onboarding flow. This feature is still new and can be token-intensive. Want to try it?"
        tmp_transcript="$(mktemp)"
        jq -nc --arg t "${long_q}" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}' >"${tmp_transcript}"
        check_eq "read-full-text"          "$(read_last_text "${tmp_transcript}")" "${long_q}"
        check    "late-question-after-160" "$(read_last_text "${tmp_transcript}")" 1
        check_eq "clip-body-caps-at-160"   "$(clip_body "${long_q}" 2>/dev/null)" "${long_q:0:159}…"
        rm -f "${tmp_transcript}"

        long_field="$(printf 'a%.0s' $(seq 1 150))"
        check_eq "clamp-field-caps"   "$(clamp_field "${long_field}" 100)" "${long_field:0:99}…"
        check_eq "clamp-field-passes" "$(clamp_field "short" 100)" "short"

        # Debounce predicate — exercised against a throwaway CONFIG_DIR
        # so a selftest never touches real ~/.config/vibez state, and a
        # pinned window so an env override can't skew the stale test.
        # (LOG_FILE was resolved at startup, so logging is unaffected.)
        dbprobe() {
            if within_debounce_window "$1"; then printf 'debounced'; else printf 'send'; fi
        }
        saved_debounce="${DEBOUNCE_SECONDS}"
        DEBOUNCE_SECONDS=5
        CONFIG_DIR="$(mktemp -d)"
        check_eq "debounce-no-stamp"    "$(dbprobe sess1)" "send"
        mark_event "sess1"
        check_eq "debounce-fresh-stamp" "$(dbprobe sess1)" "debounced"
        printf '%s' "$(( $(date +%s) - 60 ))" >"${CONFIG_DIR}/lastevent.sess2"
        check_eq "debounce-stale-stamp" "$(dbprobe sess2)" "send"
        printf 'junk' >"${CONFIG_DIR}/lastevent.sess3"
        check_eq "debounce-junk-stamp"  "$(dbprobe sess3)" "send"
        printf '%s' "$(( $(date +%s) + 60 ))" >"${CONFIG_DIR}/lastevent.sess4"
        check_eq "debounce-future-stamp" "$(dbprobe sess4)" "send"
        check_eq "debounce-nosid"       "$(dbprobe nosid)" "send"
        DEBOUNCE_SECONDS=0
        check_eq "debounce-disabled"    "$(dbprobe sess1)" "send"

        # post_vibez stamp policy — only agent block events (shield:on)
        # may touch the stamp: claim on send, refresh on suppress, roll
        # back on failure. A user reply (shield:off) must do NONE of
        # those — the debounce dedupes what the AGENT fires; a reply
        # must never silence the ask/done that lands seconds later.
        # curl is shadowed (no network), VIBEZ_ID is forced non-empty,
        # and LOG_FILE points into the throwaway CONFIG_DIR.
        stampprobe() {
            if [ -f "${CONFIG_DIR}/lastevent.$1" ]; then
                printf 'stamped'
            else
                printf 'clean'
            fi
        }
        saved_log="${LOG_FILE}"
        saved_id="${VIBEZ_ID}"
        DEBOUNCE_SECONDS=5
        LOG_FILE="${CONFIG_DIR}/testlog"
        VIBEZ_ID="self-test-self-test"
        curl() { return 0; }
        post_vibez "t" "b" "replied" "off" "pvA" "cc"
        check_eq "stamp-off-send-no-claim"     "$(stampprobe pvA)" "clean"
        post_vibez "t" "b" "needs-input" "on" "pvA" "cc"
        check_eq "stamp-reply-then-ask-sends"  "$(grep -c 'debounced:' "${LOG_FILE}")" "0"
        check_eq "stamp-on-send-claims"        "$(stampprobe pvA)" "stamped"
        post_vibez "t" "b" "done" "on" "pvA" "cc"
        check_eq "stamp-burst-still-debounced" "$(grep -c 'debounced:' "${LOG_FILE}")" "1"
        curl() { return 22; }
        post_vibez "t" "b" "replied" "off" "pvA" "cc"
        check_eq "stamp-off-fail-preserves"    "$(stampprobe pvA)" "stamped"
        post_vibez "t" "b" "needs-input" "on" "pvB" "cc"
        check_eq "stamp-on-fail-rolls-back"    "$(stampprobe pvB)" "clean"
        unset -f curl
        LOG_FILE="${saved_log}"
        VIBEZ_ID="${saved_id}"

        DEBOUNCE_SECONDS="${saved_debounce}"
        rm -rf "${CONFIG_DIR}"

        printf '%d passed, %d failed\n' "$pass" "$fail"
        if [ "$fail" = "0" ]; then exit 0; else exit 1; fi
        ;;

    *)
        log "unknown event: ${EVENT}"
        ;;
esac

exit 0
