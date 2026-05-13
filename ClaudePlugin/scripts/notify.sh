#!/usr/bin/env bash
#
# vibez hook script.
#
# Dispatches Claude Code lifecycle events to ntfy.sh as push notifications.
# Topic is auto-generated on first SessionStart and persisted at
# ~/.config/vibez/topic. NTFY_TOPIC env var overrides if set.
#
# Hooks must never block Claude — this script always exits 0, network
# failures are swallowed.

set -uo pipefail

EVENT="${1:-}"

CONFIG_DIR="${HOME}/.config/vibez"
TOPIC_FILE="${CONFIG_DIR}/topic"
LOG_FILE="${CONFIG_DIR}/log"

# One-shot migration from the old claude-ntfy-named directory. Single user
# (Peter) — same machine, same topic, no phone re-subscribe needed.
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

# Resolve topic: env wins, else file.
TOPIC="${NTFY_TOPIC:-}"
if [ -z "${TOPIC}" ] && [ -f "${TOPIC_FILE}" ]; then
    TOPIC="$(cat "${TOPIC_FILE}" 2>/dev/null | tr -d '[:space:]')"
fi

SERVER="${NTFY_SERVER:-https://ntfy.sh}"

generate_topic() {
    # 32 alphanumeric chars, ~190 bits of entropy. Plenty for a private
    # public-ntfy topic where security is the topic name.
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
    # status (done / needs-input / replied) lives in the _vibez:event tag.
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
        if [ -z "${TOPIC}" ]; then
            TOPIC="$(generate_topic)"
            if [ -n "${TOPIC}" ]; then
                printf '%s\n' "${TOPIC}" >"${TOPIC_FILE}"
                chmod 600 "${TOPIC_FILE}" 2>/dev/null || true
                log "generated topic ${TOPIC}"

                url="${SERVER}/${TOPIC}"
                msg="vibez plugin: notification topic generated. Subscribe in the ntfy app: ${url}  —  or run /vibez:setup for a QR code. Until you subscribe, push notifications won't reach your phone."

                # systemMessage = visible warning banner shown to the user.
                # additionalContext = injected so Claude can answer follow-ups.
                printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"vibez plugin first-run setup complete. Subscribe URL: %s. Run /vibez:setup for a QR code."}}\n' \
                    "${msg}" "${url}"
            else
                log "topic generation failed"
            fi
        else
            log "session-start (topic exists)"
        fi
        ;;

    notification)
        message="$(jq_get '.message')"
        # Skip Claude Code's idle-timer ping — it fires whenever the user
        # walks away mid-conversation and is just noise on the phone.
        # Permission requests ("Permission required to run ...") still pass.
        case "${message}" in
            *"waiting for your input"*) exit 0 ;;
        esac
        transcript="$(jq_get '.transcript_path')"
        cwd="$(jq_get '.cwd')"
        sid="$(jq_get '.session_id' 'nosid')"
        proj="$(basename "${cwd:-unknown}")"
        convo_title="$(read_conversation_title "${transcript}" "${proj}" "" "${sid}")"
        if [ -z "${message}" ]; then
            ntype="$(jq_get '.notification_type' 'unknown')"
            message="Claude needs your attention (${ntype})"
        fi
        # _vibez:shield:on tells the app to shield. _vibez:session:<sid>
        # lets it match this against an upcoming user reply (which
        # arrives with shield:off) and lift the shield for this exact
        # conversation. _vibez:agent:cc tells the app this came from
        # Claude Code (vs cx for Codex), so it can route + badge without
        # sniffing the title/body.
        post_ntfy "${convo_title}" "${message}" "_vibez:event:needs-input,_vibez:session:${sid},_vibez:shield:on,_vibez:agent:cc"
        ;;

    stop)
        cwd="$(jq_get '.cwd')"
        sid="$(jq_get '.session_id' 'nosid')"
        proj="$(basename "${cwd:-unknown}")"
        transcript="$(jq_get '.transcript_path')"
        convo_title="$(read_conversation_title "${transcript}" "${proj}" "" "${sid}")"
        excerpt="$(last_assistant_excerpt)"
        # Skip when polling didn't surface a fresh excerpt — sending a
        # generic "Claude finished a turn." is just noise on the phone.
        if [ -z "${excerpt}" ]; then
            exit 0
        fi
        if last_turn_is_asking "${excerpt}"; then
            post_ntfy "${convo_title}" "${excerpt}" "_vibez:event:needs-input,_vibez:session:${sid},_vibez:shield:on,_vibez:agent:cc"
        else
            post_ntfy "${convo_title}" "${excerpt}" "_vibez:event:done,_vibez:session:${sid},_vibez:shield:on,_vibez:agent:cc"
        fi
        ;;

    user-prompt-submit)
        # User replied in Claude — fire a push with _vibez:shield:off so
        # the iOS app lifts the shield for this session. Body is mostly
        # informational; the Vibez app routes on the tag axes.
        sid="$(jq_get '.session_id' 'nosid')"
        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        proj="$(basename "${cwd:-unknown}")"
        prompt="$(jq_get '.prompt')"
        # Pass the current prompt as a hint — for desktop sessions the
        # transcript file frequently doesn't exist yet at this point,
        # so falling back to .prompt beats falling back to basename.
        convo_title="$(read_conversation_title "${transcript}" "${proj}" "${prompt}" "${sid}")"
        # Truncate prompt to a short excerpt for the body
        if [ "${#prompt}" -gt 80 ]; then
            prompt="${prompt:0:79}…"
        fi
        [ -z "${prompt}" ] && prompt="(replied)"
        post_ntfy "${convo_title}" "${prompt}" "_vibez:event:replied,_vibez:session:${sid},_vibez:shield:off,_vibez:agent:cc"
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
