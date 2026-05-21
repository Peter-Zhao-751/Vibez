#!/usr/bin/env bash
#
# vibez hook script (Codex side).
#
# Dispatches Codex lifecycle events to ntfy.sh as push notifications.
# Topic is shared with the Claude Code vibez plugin at ~/.config/vibez/topic
# so a single ntfy subscription on the phone covers both agents.
#
# Hooks must never block Codex — this script always exits 0, network
# failures are swallowed.

set -uo pipefail

EVENT="${1:-}"

CONFIG_DIR="${HOME}/.config/vibez"
TOPIC_FILE="${CONFIG_DIR}/topic"
LOG_FILE="${CONFIG_DIR}/log"

# One-shot migration from the old claude-ntfy-named directory used by the
# pre-0.9 Claude Code plugin. Same machine, same topic, same subscription.
OLD_CONFIG_DIR="${HOME}/.config/claude-ntfy"
if [ -d "${OLD_CONFIG_DIR}" ] && [ ! -d "${CONFIG_DIR}" ]; then
    mv "${OLD_CONFIG_DIR}" "${CONFIG_DIR}" 2>/dev/null || true
fi

mkdir -p "${CONFIG_DIR}" 2>/dev/null || true
chmod 700 "${CONFIG_DIR}" 2>/dev/null || true

log() {
    printf '[%s] cx %s\n' "$(date -u +%FT%TZ)" "$*" >>"${LOG_FILE}" 2>/dev/null || true
}

# Read stdin once if present, into INPUT.
INPUT=""
if [ ! -t 0 ]; then
    INPUT="$(cat 2>/dev/null || true)"
fi

# Resolve topic: env wins, else file.
TOPIC="${NTFY_TOPIC:-}"
if [ -z "${TOPIC}" ] && [ -f "${TOPIC_FILE}" ]; then
    TOPIC="$(cat "${TOPIC_FILE}" 2>/dev/null | tr -d '[:space:]')"
fi

SERVER="${NTFY_SERVER:-https://ntfy.sh}"

generate_topic() {
    # 32 alphanumeric chars, ~190 bits of entropy.
    LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 32
}

post_ntfy() {
    local title="$1"
    local body="$2"
    local tags="${3:-}"

    if [ -z "${TOPIC}" ]; then
        log "skip: no topic configured (event=${EVENT})"
        return 0
    fi

    local -a curl_args=(
        -fsS --max-time 5
        -H "Title: ${title}"
    )
    if [ -n "${tags}" ]; then
        curl_args+=(-H "Tags: ${tags}")
    fi
    if [ -n "${NTFY_AUTH:-}" ]; then
        curl_args+=(-H "Authorization: Bearer ${NTFY_AUTH}")
    fi
    curl_args+=(-d "${body}" "${SERVER}/${TOPIC}")

    curl "${curl_args[@]}" >/dev/null 2>&1 \
        && log "sent: ${title}" \
        || log "send failed: ${title}"
}

# Codex has no hook that fires on the user's response to a PermissionRequest
# (approve/deny tap in Codex Desktop). The closest observable signal is the
# PostToolUse on the underlying tool — but PostToolUse also fires for every
# autonomous tool call in dontAsk/bypassPermissions sessions, which would
# blow through ntfy.sh's 250/day cap. To gate it, permission-request and
# pre-tool-use(ask_user_question) drop a per-session marker; post-tool-use
# only pushes shield-off when the marker exists, then clears it.
# stop and user-prompt-submit also clear it so a stale marker doesn't
# trigger a false shield-off later.
pending_marker_path() {
    local sid="$1"
    [ -z "${sid}" ] || [ "${sid}" = "nosid" ] && return 1
    printf '%s/pending.%s' "${CONFIG_DIR}" "${sid}"
}

mark_pending() {
    local sid="$1" path
    path="$(pending_marker_path "${sid}")" || return 0
    : >"${path}" 2>/dev/null || true
}

clear_pending() {
    local sid="$1" path
    path="$(pending_marker_path "${sid}")" || return 0
    rm -f "${path}" 2>/dev/null || true
}

has_pending() {
    local sid="$1" path
    path="$(pending_marker_path "${sid}")" || return 1
    [ -f "${path}" ]
}

# True when the argument is a slash-command invocation — either the bare
# "/foo" form or Claude Code's "<command-name>...</command-name>" wrapper
# (also produced by Codex's transcript when a slash command is the entry
# point). Used to suppress pushes for scheduled cron-style commands that
# would otherwise blow past ntfy.sh's 250 msgs/day free-tier cap.
is_slash_command() {
    case "$1" in
        "<command-name>"*|"<command-message>"*|"/"[a-zA-Z]*) return 0 ;;
    esac
    return 1
}

# True when this hook is firing for an ephemeral / internal sub-LLM thread
# spawned by Codex Desktop, not a real user-facing conversation. Codex Desktop
# fires the full SessionStart / UserPromptSubmit / Stop hook lifecycle on
# ephemeral threads it starts internally for thread-title generation, message
# summarization, ambient-suggestion safety classification, and similar
# bookkeeping. Those threads use prompts like
# "You are a helpful assistant. You will be presented with a user prompt…"
# and return structured JSON like {"title":"…"} — neither of which is useful
# noise to wake the user's phone for. They also use `ephemeral: true` /
# `persistExtendedHistory: false`, so Codex never writes a rollout file for
# them; transcript_path is either null or points at a path that was never
# created. A real Codex session always writes its session_meta record (and
# therefore creates the rollout file) before any UserPromptSubmit or Stop
# fires, so a missing transcript file at hook-firing time is a reliable
# ephemeral-session signal.
is_ephemeral_session() {
    [ -z "${transcript}" ] && return 0
    [ ! -f "${transcript}" ] && return 0
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

# Pull the most recent thread name Codex Desktop has generated for this
# session. Codex Desktop spawns an ephemeral sub-LLM call per turn to
# produce a short title (see Wt() in the Codex Desktop bundle) and writes
# the result back to the parent rollout as an event_msg payload of shape
# {type:"thread_name_updated", thread_name:"<title>"}. This is what the
# user sees in the app's sidebar, so it's the least-surprising thing to
# put on their phone. Returns empty for codex-tui CLI sessions (the CLI
# doesn't generate titles), in which case the caller should fall back to
# first_user_prompt_from_transcript.
read_thread_name_from_transcript() {
    local transcript="$1"
    [ -z "${transcript}" ] && return 0
    [ ! -f "${transcript}" ] && return 0
    command -v jq >/dev/null 2>&1 || return 0

    jq -r '
        select(.payload.type == "thread_name_updated")
        | .payload.thread_name // empty
    ' "${transcript}" 2>/dev/null \
        | grep -v '^[[:space:]]*$' \
        | tail -n 1 \
        | tr '\n' ' '
}

# Pull the first real user prompt from a Codex rollout transcript so we
# have a meaningful title instead of always using basename(cwd). Codex
# writes records like {"type":"response_item","payload":{"type":"message",
# "role":"user","content":[{"text":"<the prompt>"}]}} — but the first user
# record is always an "<environment_context>…</environment_context>" block
# injected by Codex itself, which we skip.
#
# Returns nothing if no usable prompt is found (caller falls back to
# basename(cwd) which is fine in that edge case).
first_user_prompt_from_transcript() {
    local transcript="$1"
    [ -z "${transcript}" ] && return 0
    [ ! -f "${transcript}" ] && return 0
    command -v jq >/dev/null 2>&1 || return 0

    jq -r '
        select(.type == "response_item" and .payload.type == "message" and .payload.role == "user")
        | (.payload.content // [])
        | map(.text // .input_text // "")
        | join(" ")
        | select(length > 0)
        | select(startswith("<environment_context>") | not)
        | select(startswith("<user_instructions>") | not)
    ' "${transcript}" 2>/dev/null \
        | head -n 1 \
        | tr '\n' ' '
}

# Cap a string at 72 chars with a trailing ellipsis for titles.
clip_title() {
    local raw="$1"
    raw="$(printf '%s' "${raw}" | tr '\n' ' ' | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
    if [ "${#raw}" -gt 72 ]; then
        printf '%s…' "${raw:0:71}"
    else
        printf '%s' "${raw}"
    fi
}

# Cap a string at 160 chars for the body.
clip_body() {
    local raw="$1"
    raw="$(printf '%s' "${raw}" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g;s/^[[:space:]]+//;s/[[:space:]]+$//')"
    if [ "${#raw}" -gt 160 ]; then
        printf '%s…' "${raw:0:159}"
    else
        printf '%s' "${raw}"
    fi
}

# Returns 0 (true) when the assistant text looks like Codex is waiting on the
# user. Mirrors the Claude Code plugin's heuristic so the iOS app's shield
# behavior is consistent across both agents.
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

    case "${cleaned}" in
        *\?*) return 0 ;;
    esac

    local last
    last="$(printf '%s' "${cleaned}" \
        | tr '\n' ' ' \
        | sed -E 's/([.!?]+)[[:space:]]+/\1\n/g' \
        | grep -v '^[[:space:]]*$' \
        | tail -n 1 \
        | sed -E 's/^[[:space:]]+//')"

    [ -z "${last}" ] && return 1

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
        # Codex passes source ∈ {startup, resume, clear}. Only do the
        # welcome banner on the very first run (no topic file yet);
        # subsequent startups are silent.
        if [ -z "${TOPIC}" ]; then
            TOPIC="$(generate_topic)"
            if [ -n "${TOPIC}" ]; then
                printf '%s\n' "${TOPIC}" >"${TOPIC_FILE}"
                chmod 600 "${TOPIC_FILE}" 2>/dev/null || true
                log "generated topic ${TOPIC}"

                url="${SERVER}/${TOPIC}"
                msg="vibez plugin: notification topic generated. Subscribe in the ntfy app: ${url}  —  until you subscribe, push notifications won't reach your phone."

                # Codex accepts the same systemMessage / hookSpecificOutput
                # shape as Claude Code; SessionStartHookSpecificOutputWire
                # supports additionalContext.
                printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"vibez first-run setup complete. Subscribe URL: %s."}}\n' \
                    "${msg}" "${url}"
            else
                log "topic generation failed"
            fi
        else
            log "session-start (topic exists)"
        fi
        ;;

    permission-request)
        # Skip modes where the user has explicitly opted out of being asked —
        # no point pinging the phone for a decision that won't be shown.
        mode="$(jq_get '.permission_mode' 'default')"
        case "${mode}" in
            dontAsk|bypassPermissions)
                log "permission-request: skipping (mode=${mode})"
                exit 0 ;;
        esac

        sid="$(jq_get '.session_id' 'nosid')"
        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        is_ephemeral_session && { log "permission-request: skipping ephemeral session"; exit 0; }
        tool_name="$(jq_get '.tool_name' 'tool')"
        proj="$(basename "${cwd:-unknown}")"
        title_raw="$(read_thread_name_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="$(first_user_prompt_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="${proj}"

        # Build a short body: tool name + a snippet of the input. tool_input
        # is `any`, so we re-serialize to JSON via jq when present.
        tool_input_str=""
        if command -v jq >/dev/null 2>&1 && [ -n "${INPUT}" ]; then
            tool_input_str="$(printf '%s' "${INPUT}" | jq -rc '.tool_input // empty | if type == "string" then . else tostring end' 2>/dev/null || true)"
        fi

        if [ -n "${tool_input_str}" ]; then
            body="${tool_name}: ${tool_input_str}"
        else
            body="Permission required to run ${tool_name}"
        fi

        post_ntfy "$(clip_title "${title_raw}")" "$(clip_body "${body}")" \
            "_vibez:event:needs-input,_vibez:session:${sid},_vibez:shield:on,_vibez:agent:cx"
        mark_pending "${sid}"
        ;;

    stop)
        sid="$(jq_get '.session_id' 'nosid')"
        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        is_ephemeral_session && { log "stop: skipping ephemeral session"; exit 0; }
        proj="$(basename "${cwd:-unknown}")"
        title_raw="$(read_thread_name_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="$(first_user_prompt_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="${proj}"
        is_slash_command "${title_raw}" && exit 0
        # Codex puts the final assistant text directly in the Stop payload —
        # no transcript polling needed for the body (unlike the Claude Code
        # plugin), but we still read the transcript for the title.
        excerpt="$(jq_get '.last_assistant_message')"
        if [ -z "${excerpt}" ]; then
            log "stop: empty last_assistant_message, skipping"
            exit 0
        fi
        body="$(clip_body "${excerpt}")"
        title="$(clip_title "${title_raw}")"
        if last_turn_is_asking "${excerpt}"; then
            post_ntfy "${title}" "${body}" \
                "_vibez:event:needs-input,_vibez:session:${sid},_vibez:shield:on,_vibez:agent:cx"
        else
            post_ntfy "${title}" "${body}" \
                "_vibez:event:done,_vibez:session:${sid},_vibez:shield:on,_vibez:agent:cx"
        fi
        # Stop is a terminal "needs you" signal — any pending shield-on from
        # an earlier permission/picker in this turn has been superseded.
        clear_pending "${sid}"
        ;;

    pre-tool-use)
        # ask_user_question is Codex's interactive picker — turn is paused
        # mid-flight until the user submits, so neither Stop nor
        # PermissionRequest fires while it's pending. This is the only
        # hook that can ping the phone in time.
        tool_name="$(jq_get '.tool_name')"
        case "${tool_name}" in
            ask_user_question|AskUserQuestion) ;;
            *) exit 0 ;;
        esac

        sid="$(jq_get '.session_id' 'nosid')"
        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        is_ephemeral_session && { log "pre-tool-use: skipping ephemeral session"; exit 0; }
        proj="$(basename "${cwd:-unknown}")"
        title_raw="$(read_thread_name_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="$(first_user_prompt_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="${proj}"
        is_slash_command "${title_raw}" && exit 0

        # Try Claude-style (.questions[0].question) and singular (.question)
        # shapes — the exact ask_user_question input schema isn't public,
        # so be permissive and fall back to a generic body.
        question="$(jq_get '.tool_input.questions[0].question')"
        [ -z "${question}" ] && question="$(jq_get '.tool_input.question')"
        [ -z "${question}" ] && question="Codex is asking a question."

        post_ntfy "$(clip_title "${title_raw}")" "$(clip_body "${question}")" \
            "_vibez:event:needs-input,_vibez:session:${sid},_vibez:shield:on,_vibez:agent:cx"
        mark_pending "${sid}"
        ;;

    post-tool-use)
        # Codex doesn't fire a hook the moment the user taps Approve/Deny
        # on a PermissionRequest, or picks an option in ask_user_question.
        # The earliest observable signal is this PostToolUse: by the time
        # it fires, the user has engaged. Only push when permission-request
        # or pre-tool-use(ask_user_question) earlier in this session left
        # a pending marker — otherwise this fires for every tool call in
        # autonomous mode and drowns the phone.
        sid="$(jq_get '.session_id' 'nosid')"
        has_pending "${sid}" || exit 0

        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        is_ephemeral_session && { log "post-tool-use: skipping ephemeral session"; exit 0; }
        proj="$(basename "${cwd:-unknown}")"
        title_raw="$(read_thread_name_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="$(first_user_prompt_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="${proj}"

        tool_name="$(jq_get '.tool_name' 'tool')"
        # For ask_user_question the response is the user's actual answer,
        # which is meaningful body content. For shell/apply_patch/etc. the
        # tool_response is command output that may be huge or contain
        # secrets — keep it generic.
        case "${tool_name}" in
            ask_user_question|AskUserQuestion)
                body="$(jq_get '.tool_response.content')"
                [ -z "${body}" ] && body="(answered)"
                ;;
            *)
                body="(approved: ${tool_name})"
                ;;
        esac

        post_ntfy "$(clip_title "${title_raw}")" "$(clip_body "${body}")" \
            "_vibez:event:replied,_vibez:session:${sid},_vibez:shield:off,_vibez:agent:cx"
        clear_pending "${sid}"
        ;;

    user-prompt-submit)
        sid="$(jq_get '.session_id' 'nosid')"
        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        is_ephemeral_session && { log "user-prompt-submit: skipping ephemeral session"; exit 0; }
        proj="$(basename "${cwd:-unknown}")"
        prompt="$(jq_get '.prompt')"
        is_slash_command "${prompt}" && exit 0
        # Title preference order: Codex Desktop's agent-generated thread name
        # (what the user sees in the app sidebar), then the transcript's first
        # user prompt (CLI fallback — CLI doesn't generate titles), then the
        # just-submitted prompt, then cwd basename.
        title_raw="$(read_thread_name_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="$(first_user_prompt_from_transcript "${transcript}")"
        [ -z "${title_raw}" ] && title_raw="${prompt:-${proj}}"
        title="$(clip_title "${title_raw}")"
        if [ -z "${prompt}" ]; then
            prompt="(replied)"
        fi
        post_ntfy "${title}" "$(clip_body "${prompt}")" \
            "_vibez:event:replied,_vibez:session:${sid},_vibez:shield:off,_vibez:agent:cx"
        clear_pending "${sid}"
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
