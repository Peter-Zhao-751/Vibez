#!/usr/bin/env bash
#
# End-to-end hook-path test: pipes realistic Cursor hook payloads into
# notify.sh (stdin dispatch on hook_event_name, exactly as Cursor invokes
# it) against a sandboxed HOME and a local stub /notify backend, then
# asserts on the JSON bodies the script POSTs. Complements _selftest
# (helper-level) and install.test.js (installer-level).
#
# Usage: bash test/hooks.e2e.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTIFY="${ROOT}/scripts/notify.sh"

SANDBOX="$(mktemp -d)"
CAPTURE="${SANDBOX}/requests.jsonl"
PORT_FILE="${SANDBOX}/port"
SERVER_PID=""
cleanup() {
    if [ -n "${SERVER_PID}" ]; then
        kill "${SERVER_PID}" 2>/dev/null
        wait "${SERVER_PID}" 2>/dev/null
    fi
    rm -rf "${SANDBOX}"
}
trap cleanup EXIT

# Stub backend: 200 + {"ok":true} for every POST, bodies appended to a file.
python3 - "${CAPTURE}" "${PORT_FILE}" <<'PY' &
import json, sys, http.server

capture, port_file = sys.argv[1], sys.argv[2]

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        with open(capture, "ab") as f:
            f.write(body + b"\n")
        payload = json.dumps({"ok": True}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def log_message(self, *a):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(port_file, "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
PY
SERVER_PID=$!

for _ in $(seq 1 50); do
    [ -s "${PORT_FILE}" ] && break
    sleep 0.1
done
[ -s "${PORT_FILE}" ] || { echo "FATAL: stub backend never came up" >&2; exit 1; }
PORT="$(cat "${PORT_FILE}")"

export HOME="${SANDBOX}/home"
mkdir -p "${HOME}"
export VIBEZ_BACKEND_URL="http://127.0.0.1:${PORT}"
export VIBEZ_ID="test-test-test-test"
export VIBEZ_BLOCK_DEBOUNCE_SECONDS=0   # each case stands alone

pass=0; fail=0
ok()   { pass=$((pass+1)); printf 'PASS %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s — %s\n' "$1" "$2"; }

# fire <payload-json> → stdout of notify.sh
fire() {
    printf '%s' "$1" | bash "${NOTIFY}"
}

requests()      { cat "${CAPTURE}" 2>/dev/null || true; }
request_count() { requests | grep -c . || true; }
last_request()  { requests | tail -n 1; }
reset_capture() { : >"${CAPTURE}"; }

# The reply send is detached (beforeSubmitPrompt answers Cursor before the
# POST happens) — wait up to 5s for the expected request count.
await_requests() {
    local want="$1" i
    for i in $(seq 1 50); do
        [ "$(request_count)" -ge "${want}" ] && return 0
        sleep 0.1
    done
    return 1
}

BASE='"conversation_id":"e2e-sess-1","generation_id":"g1","model":"m","cursor_version":"3.7.0","workspace_roots":["/Users/dev/my-proj"],"user_email":null,"transcript_path":null'

# --- beforeSubmitPrompt: sends replied/off, answers {"continue": true} ---
reset_capture
out="$(fire "{${BASE},\"hook_event_name\":\"beforeSubmitPrompt\",\"prompt\":\"fix the login bug\",\"attachments\":[]}")"
if [ "$(printf '%s' "${out}" | jq -c . 2>/dev/null)" = '{"continue":true}' ]; then
    ok "prompt-submit-answers-continue"
else
    bad "prompt-submit-answers-continue" "stdout was [${out}]"
fi
await_requests 1 || bad "prompt-submit-detached-send-arrives" "no request within 5s"
req="$(last_request)"
if [ "$(printf '%s' "${req}" | jq -r '.shield + "/" + .event + "/" + .agent')" = "off/replied/cu" ]; then
    ok "prompt-submit-posts-shield-off"
else
    bad "prompt-submit-posts-shield-off" "request was [${req}]"
fi
if [ "$(printf '%s' "${req}" | jq -r '.title')" = "fix the login bug" ]; then
    ok "prompt-submit-title-is-first-prompt"
else
    bad "prompt-submit-title-is-first-prompt" "request was [${req}]"
fi

# --- slash commands: still {"continue": true}, no push ---
reset_capture
out="$(fire "{${BASE},\"hook_event_name\":\"beforeSubmitPrompt\",\"prompt\":\"/summarize\",\"attachments\":[]}")"
sleep 0.5   # settle window: a (buggy) detached send would land here
if [ "$(printf '%s' "${out}" | jq -c . 2>/dev/null)" = '{"continue":true}' ] && [ "$(request_count)" = "0" ]; then
    ok "slash-command-silent-but-continues"
else
    bad "slash-command-silent-but-continues" "stdout=[${out}] requests=$(request_count)"
fi

# --- afterAgentResponse: stash only, no network ---
reset_capture
out="$(fire "{${BASE},\"hook_event_name\":\"afterAgentResponse\",\"text\":\"All tests pass. Should I also update the docs?\"}")"
if [ "$(request_count)" = "0" ] && [ -z "${out}" ]; then
    ok "agent-response-stashes-silently"
else
    bad "agent-response-stashes-silently" "stdout=[${out}] requests=$(request_count)"
fi

# --- stop(completed) with an asking last message → needs-input/on, stashed body, stashed title ---
reset_capture
fire "{${BASE},\"hook_event_name\":\"stop\",\"status\":\"completed\",\"loop_count\":0}" >/dev/null
req="$(last_request)"
if [ "$(printf '%s' "${req}" | jq -r '.shield + "/" + .event')" = "on/needs-input" ]; then
    ok "stop-asking-posts-needs-input"
else
    bad "stop-asking-posts-needs-input" "request was [${req}]"
fi
if [ "$(printf '%s' "${req}" | jq -r '.body')" = "All tests pass. Should I also update the docs?" ]; then
    ok "stop-body-is-stashed-text"
else
    bad "stop-body-is-stashed-text" "request was [${req}]"
fi
if [ "$(printf '%s' "${req}" | jq -r '.title')" = "fix the login bug" ]; then
    ok "stop-title-is-first-prompt"
else
    bad "stop-title-is-stashed-prompt" "request was [${req}]"
fi
if [ "$(printf '%s' "${req}" | jq -r '.session')" = "e2e-sess-1" ]; then
    ok "stop-session-is-conversation-id"
else
    bad "stop-session-is-conversation-id" "request was [${req}]"
fi

# --- stop(completed) with a non-asking last message → done/on ---
reset_capture
fire "{${BASE},\"hook_event_name\":\"afterAgentResponse\",\"text\":\"Done. The fix is committed.\"}" >/dev/null
fire "{${BASE},\"hook_event_name\":\"stop\",\"status\":\"completed\",\"loop_count\":0}" >/dev/null
if [ "$(last_request | jq -r '.event')" = "done" ]; then
    ok "stop-done-posts-done"
else
    bad "stop-done-posts-done" "request was [$(last_request)]"
fi

# --- stop(aborted): user hit stop in the IDE — no push ---
reset_capture
fire "{${BASE},\"hook_event_name\":\"stop\",\"status\":\"aborted\",\"loop_count\":0}" >/dev/null
if [ "$(request_count)" = "0" ]; then
    ok "stop-aborted-is-silent"
else
    bad "stop-aborted-is-silent" "requests=$(request_count)"
fi

# --- stop(error): pushes needs-input ---
reset_capture
fire "{${BASE},\"hook_event_name\":\"stop\",\"status\":\"error\",\"loop_count\":0}" >/dev/null
if [ "$(last_request | jq -r '.event + "/" + .shield')" = "needs-input/on" ]; then
    ok "stop-error-posts-needs-input"
else
    bad "stop-error-posts-needs-input" "request was [$(last_request)]"
fi

# --- instant stop after a reply: the detached shield:off must reach the
# --- backend BEFORE the stop's shield:on (server-side seq ordering) ---
reset_capture
fire "{${BASE},\"hook_event_name\":\"beforeSubmitPrompt\",\"prompt\":\"quick question\",\"attachments\":[]}" >/dev/null
fire "{${BASE},\"hook_event_name\":\"stop\",\"status\":\"completed\",\"loop_count\":0}" >/dev/null
await_requests 2 || bad "instant-stop-both-arrive" "fewer than 2 requests within 5s"
first_shield="$(requests | head -n 1 | jq -r '.shield')"
second_shield="$(requests | tail -n 1 | jq -r '.shield')"
if [ "${first_shield}/${second_shield}" = "off/on" ]; then
    ok "reply-ordered-before-instant-stop"
else
    bad "reply-ordered-before-instant-stop" "order was ${first_shield} then ${second_shield}"
fi

# --- background sessions are mute for their whole lifecycle ---
BGBASE='"conversation_id":"e2e-bg-1","generation_id":"g1","model":"m","cursor_version":"3.7.0","workspace_roots":["/Users/dev/my-proj"],"user_email":null,"transcript_path":null'
reset_capture
fire "{${BGBASE},\"hook_event_name\":\"sessionStart\",\"session_id\":\"e2e-bg-1\",\"is_background_agent\":true}" >/dev/null
fire "{${BGBASE},\"hook_event_name\":\"beforeSubmitPrompt\",\"prompt\":\"auto task\",\"attachments\":[]}" >/dev/null
fire "{${BGBASE},\"hook_event_name\":\"afterAgentResponse\",\"text\":\"working\"}" >/dev/null
fire "{${BGBASE},\"hook_event_name\":\"stop\",\"status\":\"completed\",\"loop_count\":0}" >/dev/null
sleep 0.5   # settle window for any (buggy) detached send
if [ "$(request_count)" = "0" ]; then
    ok "background-session-never-posts"
else
    bad "background-session-never-posts" "requests=$(request_count): $(requests)"
fi

# --- sessionStart on a fresh machine mints an ID + injects context ---
reset_capture
saved_id="${VIBEZ_ID}"
unset VIBEZ_ID
rm -rf "${HOME}/.config/vibez"
out="$(fire "{${BASE},\"hook_event_name\":\"sessionStart\",\"session_id\":\"e2e-sess-1\",\"is_background_agent\":false}")"
minted="$(cat "${HOME}/.config/vibez/vibez-id" 2>/dev/null || true)"
if printf '%s' "${minted}" | grep -Eq '^[a-z]{3,5}(-[a-z]{3,5}){3}$'; then
    ok "session-start-mints-id"
else
    bad "session-start-mints-id" "id file was [${minted}]"
fi
if printf '%s' "${out}" | jq -r '.additional_context' 2>/dev/null | grep -q "${minted}"; then
    ok "session-start-injects-context"
else
    bad "session-start-injects-context" "stdout was [${out}]"
fi
export VIBEZ_ID="${saved_id}"

# --- sessionEnd cleans the per-session stash ---
fire "{${BASE},\"hook_event_name\":\"afterAgentResponse\",\"text\":\"leftover\"}" >/dev/null
fire "{${BASE},\"hook_event_name\":\"sessionEnd\",\"session_id\":\"e2e-sess-1\",\"reason\":\"user_close\",\"duration_ms\":5,\"is_background_agent\":false}" >/dev/null
leftovers="$(find "${HOME}/.config/vibez" -maxdepth 1 \( -name 'cursor*.e2e-sess-1' -o -name 'lastevent.e2e-sess-1' \) 2>/dev/null | wc -l | tr -d '[:space:]')"
if [ "${leftovers}" = "0" ]; then
    ok "session-end-cleans-state"
else
    bad "session-end-cleans-state" "${leftovers} files left"
fi

# --- unknown events are ignored quietly ---
reset_capture
out="$(fire "{${BASE},\"hook_event_name\":\"preCompact\",\"trigger\":\"auto\"}")"
if [ "$(request_count)" = "0" ] && [ -z "${out}" ]; then
    ok "unknown-event-ignored"
else
    bad "unknown-event-ignored" "stdout=[${out}] requests=$(request_count)"
fi

# --- machine field rides every push ----------------------------------------
reset_capture
fire "{${BASE},\"hook_event_name\":\"stop\",\"status\":\"error\",\"loop_count\":0}" >/dev/null
expected_machine="$(hostname -s 2>/dev/null | LC_ALL=C tr -cd 'A-Za-z0-9.-' | cut -c1-64)"
got_machine="$(last_request | jq -r '.machine // empty')"
if [ -n "${expected_machine}" ] && [ "${got_machine}" = "${expected_machine}" ]; then
    ok "machine field rides the push"
else
    bad "machine field rides the push" "expected '${expected_machine}' got '${got_machine}'"
fi

printf '%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
