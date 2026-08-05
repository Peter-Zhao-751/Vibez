#!/usr/bin/env bash
#
# End-to-end hook-path test for the Claude Code plugin: invokes notify.sh
# with the same "<event>" argv + stdin JSON that Claude Code uses, against
# a sandboxed HOME and a local stub /notify backend, then asserts on the
# JSON bodies the script POSTs. Complements `notify.sh _selftest`
# (helper-level).
#
# Focus: the permission-grant shield lifecycle. Notification (permission
# prompt) raises shield:on + the pending marker; the granted tool's
# completion is the only post-approval signal Claude Code gives us, and it
# arrives as PostToolUse on success but PostToolUseFailure on error — BOTH
# must lift the shield, or a granted-but-failed command strands the phone
# blocked until the 15-min timeout (the 2026-06-11 stuck-shield bug).
#
# Usage: bash test/hooks.e2e.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTIFY="${ROOT}/scripts/notify.sh"
HOOKS_JSON="${ROOT}/hooks/hooks.json"

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
export VIBEZ_APPROVAL_ROOT_PID=$$       # test seam: this shell is the process-tree root
export VIBEZ_APPROVAL_WATCH_SECONDS=5   # no 10-minute stragglers after the suite exits

pass=0; fail=0
ok()   { pass=$((pass+1)); printf 'PASS %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s — %s\n' "$1" "$2"; }

# fire <event> <payload-json> → stdout of notify.sh
fire() {
    printf '%s' "$2" | bash "${NOTIFY}" "$1"
}

requests()      { cat "${CAPTURE}" 2>/dev/null || true; }
request_count() { requests | grep -c . || true; }
last_request()  { requests | tail -n 1; }
reset_capture() { : >"${CAPTURE}"; }

# The approval watcher posts from a detached process — wait up to 5s for
# the expected request count.
await_requests() {
    local want="$1" i
    for i in $(seq 1 50); do
        [ "$(request_count)" -ge "${want}" ] && return 0
        sleep 0.1
    done
    return 1
}

SID="e2e-claude-sess-1"
MARKER="${HOME}/.config/vibez/pending.${SID}"
# transcript_path deliberately nonexistent: title falls back to cwd basename.
BASE="\"session_id\":\"${SID}\",\"transcript_path\":\"${SANDBOX}/none.jsonl\",\"cwd\":\"/Users/dev/my-proj\""

# --- hooks.json wires PostToolUseFailure to the failure event ---
if jq -e '.hooks.PostToolUseFailure[0].hooks[0].command
          | test("post-tool-use-failure")' "${HOOKS_JSON}" >/dev/null 2>&1; then
    ok "hooks-json-registers-failure-hook"
else
    bad "hooks-json-registers-failure-hook" "no PostToolUseFailure entry in hooks.json"
fi

# --- notification (permission prompt) → needs-input/on + pending marker ---
reset_capture
fire notification "{${BASE},\"hook_event_name\":\"Notification\",\"message\":\"Claude needs your permission to use Bash\"}" >/dev/null
req="$(last_request)"
if [ "$(printf '%s' "${req}" | jq -r '.shield + "/" + .event + "/" + .session + "/" + .agent')" = "on/needs-input/${SID}/cc" ]; then
    ok "permission-prompt-posts-shield-on"
else
    bad "permission-prompt-posts-shield-on" "request was [${req}]"
fi
if [ -f "${MARKER}" ]; then
    ok "permission-prompt-sets-pending-marker"
else
    bad "permission-prompt-sets-pending-marker" "marker missing"
fi

# --- granted tool SUCCEEDS → replied/off + marker cleared ---
date +%s >"${MARKER}"
reset_capture
fire post-tool-use "{${BASE},\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi\"},\"tool_response\":{\"stdout\":\"hi\"}}" >/dev/null
req="$(last_request)"
if [ "$(printf '%s' "${req}" | jq -r '.shield + "/" + .event + "/" + .session')" = "off/replied/${SID}" ]; then
    ok "granted-tool-success-posts-shield-off"
else
    bad "granted-tool-success-posts-shield-off" "request was [${req}]"
fi
if [ ! -f "${MARKER}" ]; then
    ok "granted-tool-success-clears-marker"
else
    bad "granted-tool-success-clears-marker" "marker survived"
fi

# --- granted tool FAILS → replied/off + marker cleared (the stuck-shield
# --- bug: PostToolUse never fires for an errored tool, so without the
# --- PostToolUseFailure leg no shield:off was ever sent) ---
date +%s >"${MARKER}"
reset_capture
fire post-tool-use-failure "{${BASE},\"hook_event_name\":\"PostToolUseFailure\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ffmpeg -i missing.mp4\"},\"tool_response\":{\"error\":\"Exit code 254\"}}" >/dev/null
req="$(last_request)"
if [ "$(printf '%s' "${req}" | jq -r '.shield + "/" + .event + "/" + .session')" = "off/replied/${SID}" ]; then
    ok "granted-tool-failure-posts-shield-off"
else
    bad "granted-tool-failure-posts-shield-off" "request was [${req}]"
fi
if [ ! -f "${MARKER}" ]; then
    ok "granted-tool-failure-clears-marker"
else
    bad "granted-tool-failure-clears-marker" "marker survived"
fi
if [ "$(printf '%s' "${req}" | jq -r '.body')" = "(answered: Bash)" ]; then
    ok "granted-tool-failure-body-is-answered"
else
    bad "granted-tool-failure-body-is-answered" "request was [${req}]"
fi

# --- autonomous tool failure (no marker) → silent, no spam ---
rm -f "${MARKER}"
reset_capture
fire post-tool-use-failure "{${BASE},\"hook_event_name\":\"PostToolUseFailure\",\"tool_name\":\"Grep\",\"tool_input\":{\"pattern\":\"x\"},\"tool_response\":{\"error\":\"no matches\"}}" >/dev/null
if [ "$(request_count)" = "0" ]; then
    ok "autonomous-failure-is-silent"
else
    bad "autonomous-failure-is-silent" "requests=$(request_count): $(requests)"
fi

# --- hooks.json wires PermissionRequest to the permission-request event ---
if jq -e '.hooks.PermissionRequest[0].hooks[0].command
          | test("permission-request")' "${HOOKS_JSON}" >/dev/null 2>&1; then
    ok "hooks-json-registers-permission-request"
else
    bad "hooks-json-registers-permission-request" "no PermissionRequest entry in hooks.json"
fi

# --- permission-request → needs-input/on, tool-rich body, pending marker ---
rm -f "${MARKER}"
reset_capture
fire permission-request "{${BASE},\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"true vibez-e2e-noexec-$$\"}}" >/dev/null
req="$(last_request)"
if [ "$(printf '%s' "${req}" | jq -r '.shield + "/" + .event + "/" + .session + "/" + .agent')" = "on/needs-input/${SID}/cc" ]; then
    ok "permission-request-posts-shield-on"
else
    bad "permission-request-posts-shield-on" "request was [${req}]"
fi
if [ "$(printf '%s' "${req}" | jq -r '.body')" = "Bash: true vibez-e2e-noexec-$$" ]; then
    ok "permission-request-body-has-command"
else
    bad "permission-request-body-has-command" "request was [${req}]"
fi
if [ -f "${MARKER}" ]; then
    ok "permission-request-sets-pending-marker"
else
    bad "permission-request-sets-pending-marker" "marker missing"
fi

# --- grant: the approved command's process starting → shield:off within
# --- seconds of approval, NOT at command completion ---
GRANT_NEEDLE="vibez-e2e-grant-$$"
rm -f "${MARKER}"
reset_capture
fire permission-request "{${BASE},\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"${GRANT_NEEDLE}\"}}" >/dev/null
sleep 0.3   # watcher baseline snapshot happens before the spawn
bash -c 'sleep 30 & wait' "${GRANT_NEEDLE}" &   # "the user approved": process starts
GRANT_PID=$!
if await_requests 2; then
    ok "grant-process-start-triggers-second-request"
else
    bad "grant-process-start-triggers-second-request" "no shield:off within 5s of process start"
fi
req="$(last_request)"
if [ "$(printf '%s' "${req}" | jq -r '.shield + "/" + .event + "/" + .session')" = "off/replied/${SID}" ]; then
    ok "grant-unblocks-at-process-start"
else
    bad "grant-unblocks-at-process-start" "request was [${req}]"
fi
if [ ! -f "${MARKER}" ]; then
    ok "grant-clears-pending-marker"
else
    bad "grant-clears-pending-marker" "marker survived"
fi
hud_log="${HOME}/.config/vibez/hud/events.jsonl"
watch_rec="$(grep '"kind":"tool"' "${hud_log}" 2>/dev/null | tail -1)"
if printf '%s' "${watch_rec}" | jq -e '.tool == "Bash" and (.body | startswith("(approved:"))' >/dev/null 2>&1; then
    ok "watcher grant writes a HUD tool record"
else
    bad "watcher grant writes a HUD tool record" "got: ${watch_rec:-<none>}"
fi
kill "${GRANT_PID}" 2>/dev/null; wait "${GRANT_PID}" 2>/dev/null

# --- denial: command never starts → no shield:off, marker survives so the
# --- completion-time fallback (post-tool-use) stays armed ---
DENY_NEEDLE="vibez-e2e-deny-$$"
rm -f "${MARKER}"
reset_capture
VIBEZ_APPROVAL_WATCH_SECONDS=1 fire permission-request "{${BASE},\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"${DENY_NEEDLE}\"}}" >/dev/null
sleep 2   # past the 1s watch window
if [ "$(request_count)" = "1" ]; then
    ok "denial-sends-no-shield-off"
else
    bad "denial-sends-no-shield-off" "requests=$(request_count): $(requests)"
fi
if [ -f "${MARKER}" ]; then
    ok "denial-keeps-marker-for-fallback"
else
    bad "denial-keeps-marker-for-fallback" "marker gone — completion fallback disarmed"
fi

# --- watch loop honors the marker by RAW existence, not the 30s-TTL'd
# --- has_pending: a grant slower than the TTL must still unshield. Drive
# --- _watch-approval directly with an expired-by-TTL marker + a matching
# --- process already running (empty baseline → first poll matches). ---
TTL_NEEDLE="vibez-e2e-ttl-$$"
printf '%s' "$(( $(date +%s) - 3600 ))" >"${MARKER}"
bash -c 'sleep 30 & wait' "${TTL_NEEDLE}" &
TTL_PID=$!
sleep 0.1
STATE="${HOME}/.config/vibez/approval-watch.${SID}.e2e.json"
jq -nc --arg sid "${SID}" --arg cmd "${TTL_NEEDLE}" --arg root "$$" \
    '{sid:$sid,title:"my-proj",toolName:"Bash",command:$cmd,rootPid:$root,baseline:""}' >"${STATE}"
reset_capture
bash "${NOTIFY}" _watch-approval "${STATE}" </dev/null
if [ "$(last_request | jq -r '.shield + "/" + .event')" = "off/replied" ] && [ ! -f "${MARKER}" ]; then
    ok "slow-grant-past-ttl-still-unblocks"
else
    bad "slow-grant-past-ttl-still-unblocks" "requests=$(requests) marker=$([ -f "${MARKER}" ] && echo present || echo gone)"
fi
kill "${TTL_PID}" 2>/dev/null; wait "${TTL_PID}" 2>/dev/null

# --- machine field rides every push ----------------------------------------
reset_capture
fire notification "{${BASE},\"hook_event_name\":\"Notification\",\"message\":\"Claude needs permission to use Bash\"}" >/dev/null
expected_machine="$(hostname -s 2>/dev/null | LC_ALL=C tr -cd 'A-Za-z0-9.-' | cut -c1-64)"
got_machine="$(last_request | jq -r '.machine // empty')"
if [ -n "${expected_machine}" ] && [ "${got_machine}" = "${expected_machine}" ]; then
    ok "machine field rides the push"
else
    bad "machine field rides the push" "expected '${expected_machine}' got '${got_machine}'"
fi

printf '%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
