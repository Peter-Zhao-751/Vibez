#!/usr/bin/env bash
#
# vibez hook script.
#
# Dispatches Claude Code lifecycle events to ntfy.sh as push notifications.
# Topic is auto-generated on first SessionStart and persisted at
# ~/.config/claude-ntfy/topic. NTFY_TOPIC env var overrides if set.
#
# Hooks must never block Claude — this script always exits 0, network
# failures are swallowed.

set -uo pipefail

EVENT="${1:-}"

CONFIG_DIR="${HOME}/.config/claude-ntfy"
TOPIC_FILE="${CONFIG_DIR}/topic"
LOG_FILE="${CONFIG_DIR}/log"

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
    local priority="${3:-default}"
    local tags="${4:-}"

    if [ -z "${TOPIC}" ]; then
        log "skip: no topic configured (event=${EVENT})"
        return 0
    fi

    local -a curl_args=(
        -fsS --max-time 5
        -H "Title: ${title}"
        -H "Priority: ${priority}"
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

# Read Claude Code's auto-generated conversation title from the
# transcript ("ai-title" records, latest wins). Returns the project
# basename as a fallback if the title hasn't been generated yet
# (titles only appear after a few turns).
read_conversation_title() {
    local transcript="$1"
    local fallback="${2:-Claude Code}"
    [ -z "${transcript}" ] && { printf '%s' "${fallback}"; return; }
    [ ! -f "${transcript}" ] && { printf '%s' "${fallback}"; return; }
    command -v jq >/dev/null 2>&1 || { printf '%s' "${fallback}"; return; }

    local title
    title=$(jq -r '
        select(.type == "ai-title")
        | .aiTitle // empty
    ' "${transcript}" 2>/dev/null \
        | grep -v '^[[:space:]]*$' \
        | tail -n 1)

    if [ -z "${title}" ]; then
        printf '%s' "${fallback}"
        return
    fi

    # Cap at 80 chars so iOS notification banners don't wrap awkwardly.
    if [ "${#title}" -gt 80 ]; then
        printf '%s…' "${title:0:79}"
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
    # flushed yet. Return empty so the caller falls back to a generic
    # message — better than misleading the user with stale text.
    if [ -z "${excerpt}" ] || [ "${excerpt}" = "${previous}" ]; then
        log "stop: no fresh excerpt after polling (transcript=${transcript})"
        return 0
    fi

    printf '%s' "${excerpt}" >"${cache_file}"
    printf '%s' "${excerpt}"
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
        transcript="$(jq_get '.transcript_path')"
        cwd="$(jq_get '.cwd')"
        sid="$(jq_get '.session_id' 'nosid')"
        proj="$(basename "${cwd:-unknown}")"
        convo_title="$(read_conversation_title "${transcript}" "${proj}")"
        if [ -z "${message}" ]; then
            ntype="$(jq_get '.notification_type' 'unknown')"
            message="Claude needs your attention (${ntype})"
        fi
        # Control tag _vibez:block:<sid> lets the iOS app match this
        # block request against an upcoming UserPromptSubmit and
        # auto-unblock when the user replies in this exact conversation.
        post_ntfy "${convo_title} — needs you" "${message}" "high" "bell,_vibez:block:${sid}"
        ;;

    stop)
        cwd="$(jq_get '.cwd')"
        sid="$(jq_get '.session_id' 'nosid')"
        proj="$(basename "${cwd:-unknown}")"
        transcript="$(jq_get '.transcript_path')"
        convo_title="$(read_conversation_title "${transcript}" "${proj}")"
        excerpt="$(last_assistant_excerpt)"
        if [ -z "${excerpt}" ]; then
            excerpt="Claude finished a turn."
        fi
        post_ntfy "${convo_title} — done" "${excerpt}" "default" "white_check_mark,_vibez:block:${sid}"
        ;;

    user-prompt-submit)
        # User replied in Claude — fire a low-priority push tagged
        # _vibez:unblock:<sid> so the iOS app can release the matching
        # block. Body is mostly for the official ntfy app's history;
        # the Vibez app routes on the control tag.
        sid="$(jq_get '.session_id' 'nosid')"
        cwd="$(jq_get '.cwd')"
        transcript="$(jq_get '.transcript_path')"
        proj="$(basename "${cwd:-unknown}")"
        convo_title="$(read_conversation_title "${transcript}" "${proj}")"
        prompt="$(jq_get '.prompt')"
        # Truncate prompt to a short excerpt for the body
        if [ "${#prompt}" -gt 80 ]; then
            prompt="${prompt:0:79}…"
        fi
        [ -z "${prompt}" ] && prompt="(replied)"
        post_ntfy "${convo_title} — replied" "${prompt}" "low" "leftwards_arrow_with_hook,_vibez:unblock:${sid}"
        ;;

    *)
        log "unknown event: ${EVENT}"
        ;;
esac

exit 0
