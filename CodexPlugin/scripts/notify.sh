#!/usr/bin/env bash
#
# vibez hook script (Codex side).
#
# Dispatches Codex lifecycle events to the Vibez Firebase backend as
# push notifications. Vibez ID is shared with the Claude Code vibez
# plugin at ~/.config/vibez/vibez-id so a single ID on the phone covers
# both agents.
#
# Hooks must never block Codex — this script always exits 0, network
# failures are swallowed.

set -uo pipefail

EVENT="${1:-}"

CONFIG_DIR="${HOME}/.config/vibez"
ID_FILE="${CONFIG_DIR}/vibez-id"
LEGACY_TOPIC_FILE="${CONFIG_DIR}/topic"
LOG_FILE="${CONFIG_DIR}/log"
BACKEND_URL="${VIBEZ_BACKEND_URL:-https://us-central1-vibez-backend.cloudfunctions.net}"

# Where setup.sh lives. Codex doesn't set a CLAUDE_PLUGIN_ROOT env
# var, so we resolve via BASH_SOURCE — works for the cache layout
# where notify.sh sits at <plugin>/scripts/notify.sh.
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
    printf '[%s] cx %s\n' "$(date -u +%FT%TZ)" "$*" >>"${LOG_FILE}" 2>/dev/null || true
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

# Codex has no hook that fires on the user's response to a PermissionRequest
# (approve/deny tap in Codex Desktop). The closest observable signal is the
# PostToolUse on the underlying tool — but PostToolUse also fires for every
# autonomous tool call in dontAsk/bypassPermissions sessions, which would
# blow through the backend for nothing. To gate it, permission-request and
# pre-tool-use(ask_user_question) drop a per-session marker; post-tool-use
# only pushes shield-off when the marker exists, then clears it. stop and
# user-prompt-submit also clear it so a stale marker doesn't trigger a
# false shield-off later.
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
# point). Used to suppress pushes for scheduled cron-style commands.
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
        # welcome banner on the very first run (no ID file yet);
        # subsequent startups are silent.
        if [ -z "${VIBEZ_ID}" ]; then
            ensure_vibez_id
            if [ -n "${VIBEZ_ID}" ]; then
                log "generated Vibez ID ${VIBEZ_ID}"
                msg="vibez plugin: your Vibez ID is ${VIBEZ_ID}. Type it into the Vibez iPhone app (Set up notifications widget) to pair this Mac with your phone."
                # Codex accepts the same systemMessage / hookSpecificOutput
                # shape as Claude Code; SessionStartHookSpecificOutputWire
                # supports additionalContext.
                printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"vibez first-run setup complete. Vibez ID: %s. The iOS app pairs with this ID."}}\n' \
                    "${msg}" "${VIBEZ_ID}"
            else
                log "vibez ID generation failed"
            fi
        else
            log "session-start (Vibez ID exists)"
        fi
        [ -f "${LEGACY_TOPIC_FILE}" ] && rm -f "${LEGACY_TOPIC_FILE}" 2>/dev/null || true
        # Sweep stale debounce stamps so dead sessions don't pile up.
        # (BSD find: -mtime +1 deletes after ~2 days. Stamps go inert
        # seconds after the window closes anyway — this is hygiene.)
        find "${CONFIG_DIR}" -maxdepth 1 -name 'lastevent.*' -mtime +1 -delete 2>/dev/null || true
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

        post_vibez "$(clip_title "${title_raw}")" "$(clip_body "${body}")" \
            "needs-input" "on" "${sid}" "cx"
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
            post_vibez "${title}" "${body}" "needs-input" "on" "${sid}" "cx"
        else
            post_vibez "${title}" "${body}" "done" "on" "${sid}" "cx"
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

        post_vibez "$(clip_title "${title_raw}")" "$(clip_body "${question}")" \
            "needs-input" "on" "${sid}" "cx"
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

        post_vibez "$(clip_title "${title_raw}")" "$(clip_body "${body}")" \
            "replied" "off" "${sid}" "cx"
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
        post_vibez "${title}" "$(clip_body "${prompt}")" \
            "replied" "off" "${sid}" "cx"
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
        post_vibez "t" "b" "replied" "off" "pvA" "cx"
        check_eq "stamp-off-send-no-claim"     "$(stampprobe pvA)" "clean"
        post_vibez "t" "b" "needs-input" "on" "pvA" "cx"
        check_eq "stamp-reply-then-ask-sends"  "$(grep -c 'debounced:' "${LOG_FILE}")" "0"
        check_eq "stamp-on-send-claims"        "$(stampprobe pvA)" "stamped"
        post_vibez "t" "b" "done" "on" "pvA" "cx"
        check_eq "stamp-burst-still-debounced" "$(grep -c 'debounced:' "${LOG_FILE}")" "1"
        curl() { return 22; }
        post_vibez "t" "b" "replied" "off" "pvA" "cx"
        check_eq "stamp-off-fail-preserves"    "$(stampprobe pvA)" "stamped"
        post_vibez "t" "b" "needs-input" "on" "pvB" "cx"
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
