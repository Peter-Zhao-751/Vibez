#!/usr/bin/env bash
#
# Show the user's ntfy.sh subscribe URL and a QR code.
# Invoked from the /vibez:setup slash command.
#
# Args:
#   regenerate    discard the existing topic and create a new one
#   test          send a test push to the configured topic

set -uo pipefail

CONFIG_DIR="${HOME}/.config/claude-ntfy"
TOPIC_FILE="${CONFIG_DIR}/topic"
SERVER="${NTFY_SERVER:-https://ntfy.sh}"

mkdir -p "${CONFIG_DIR}" 2>/dev/null || true
chmod 700 "${CONFIG_DIR}" 2>/dev/null || true

generate_topic() {
    LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 32
}

read_topic() {
    if [ -n "${NTFY_TOPIC:-}" ]; then
        printf '%s' "${NTFY_TOPIC}"
        return
    fi
    if [ -f "${TOPIC_FILE}" ]; then
        cat "${TOPIC_FILE}" 2>/dev/null | tr -d '[:space:]'
    fi
}

write_topic() {
    printf '%s\n' "$1" >"${TOPIC_FILE}"
    chmod 600 "${TOPIC_FILE}" 2>/dev/null || true
}

ACTION="${1:-show}"

TOPIC="$(read_topic)"

case "${ACTION}" in
    regenerate)
        TOPIC="$(generate_topic)"
        write_topic "${TOPIC}"
        printf 'Generated a new topic. Old subscribers stop receiving; resubscribe to the new URL below.\n\n'
        ;;
    test)
        if [ -z "${TOPIC}" ]; then
            printf 'No topic configured yet. Run /vibez:setup first.\n'
            exit 0
        fi
        auth_args=()
        if [ -n "${NTFY_AUTH:-}" ]; then
            auth_args=(-H "Authorization: Bearer ${NTFY_AUTH}")
        fi
        if curl -fsS --max-time 5 \
            -H "Title: vibez test" \
            "${auth_args[@]}" \
            -d "If you can read this on your phone, the plugin is wired up." \
            "${SERVER}/${TOPIC}" >/dev/null 2>&1; then
            printf 'Test push sent to %s/%s\n' "${SERVER}" "${TOPIC}"
        else
            printf 'Test push failed. Check network or ntfy server (%s).\n' "${SERVER}"
        fi
        exit 0
        ;;
    show|"")
        if [ -z "${TOPIC}" ]; then
            TOPIC="$(generate_topic)"
            write_topic "${TOPIC}"
            printf 'No topic was set, so I generated one.\n\n'
        fi
        ;;
    *)
        printf 'Unknown action: %s\n' "${ACTION}"
        printf 'Usage: setup.sh [show|regenerate|test]\n'
        exit 1
        ;;
esac

printf 'Your ntfy URL:\n\n  %s\n\nPaste it into the ntfy app on your phone (tap +, then paste) and you'\''re done.\n' "${SERVER}/${TOPIC}"

exit 0
