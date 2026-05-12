#!/usr/bin/env bash
#
# Show the user's ntfy.sh subscribe URL.
# Invoked from the vibez-setup skill.
#
# Args:
#   regenerate    discard the existing topic and create a new one
#   test          send a test push to the configured topic

set -uo pipefail

CONFIG_DIR="${HOME}/.config/vibez"
TOPIC_FILE="${CONFIG_DIR}/topic"
SERVER="${NTFY_SERVER:-https://ntfy.sh}"

# One-shot migration from the old claude-ntfy-named directory.
OLD_CONFIG_DIR="${HOME}/.config/claude-ntfy"
if [ -d "${OLD_CONFIG_DIR}" ] && [ ! -d "${CONFIG_DIR}" ]; then
    mv "${OLD_CONFIG_DIR}" "${CONFIG_DIR}" 2>/dev/null || true
fi

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
            printf 'No topic configured yet. Run the vibez-setup skill first.\n'
            exit 0
        fi
        auth_args=()
        if [ -n "${NTFY_AUTH:-}" ]; then
            auth_args=(-H "Authorization: Bearer ${NTFY_AUTH}")
        fi
        # ${arr[@]+"${arr[@]}"} expands to nothing when arr is empty —
        # required under set -u on bash 3.2 (macOS default).
        if curl -fsS --max-time 5 \
            -H "Title: vibez-codex test" \
            -H "Tags: _vibez:event:done,_vibez:agent:cx" \
            ${auth_args[@]+"${auth_args[@]}"} \
            -d "If you can read this on your phone, the Codex plugin is wired up." \
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

printf 'Your ntfy URL:\n\n  %s\n\nPaste it into the "Set up notifications" widget in the Vibez app on your phone (or subscribe in the ntfy app) and you'\''re done.\n' "${SERVER}/${TOPIC}"

exit 0
