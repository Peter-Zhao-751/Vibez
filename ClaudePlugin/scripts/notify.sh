#!/usr/bin/env bash
#
# vibez-ntfy hook script.
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

last_assistant_excerpt() {
    local transcript
    transcript="$(jq_get '.transcript_path')"
    [ -z "${transcript}" ] && return 0
    [ ! -f "${transcript}" ] && return 0
    command -v jq >/dev/null 2>&1 || return 0

    # Pull the last non-empty text block from any assistant turn.
    jq -r '
        select(.type == "assistant")
        | .message.content[]?
        | select(.type == "text")
        | .text
    ' "${transcript}" 2>/dev/null \
        | grep -v '^[[:space:]]*$' \
        | tail -n 1 \
        | tr '\n' ' ' \
        | cut -c 1-160
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
                msg="vibez-ntfy plugin: notification topic generated. Subscribe in the ntfy app: ${url}  —  or run /ntfy-setup for a QR code. Until you subscribe, push notifications won't reach your phone."

                # systemMessage = visible warning banner shown to the user.
                # additionalContext = injected so Claude can answer follow-ups.
                printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"vibez-ntfy plugin first-run setup complete. Subscribe URL: %s. Run /ntfy-setup for a QR code."}}\n' \
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
        title="$(jq_get '.title' 'Claude Code')"
        if [ -z "${message}" ]; then
            ntype="$(jq_get '.notification_type' 'unknown')"
            message="Claude needs your attention (${ntype})"
        fi
        post_ntfy "${title} — needs you" "${message}" "high" "bell"
        ;;

    stop)
        cwd="$(jq_get '.cwd')"
        proj="$(basename "${cwd:-unknown}")"
        excerpt="$(last_assistant_excerpt)"
        if [ -z "${excerpt}" ]; then
            excerpt="Claude finished a turn in ${proj}."
        fi
        post_ntfy "Claude finished — ${proj}" "${excerpt}" "default" "white_check_mark"
        ;;

    *)
        log "unknown event: ${EVENT}"
        ;;
esac

exit 0
