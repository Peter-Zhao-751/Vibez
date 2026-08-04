#!/usr/bin/env bash
#
# End-to-end test for the HUD sidecar log the notch app tails (Cursor side).
#
# Feeds realistic hook payloads through the REAL notify.sh with curl shadowed,
# then asserts what landed in ~/.config/vibez/hud/events.jsonl. Sandboxing is
# by HOME (notify.sh derives CONFIG_DIR from it) — VIBEZ_CONFIG_DIR is a no-op
# in this script.
#
# Cursor dispatches on the payload's hook_event_name with NO argument, so
# `fire` pipes JSON into an argless invocation, exactly as Cursor runs it.
#
# Two load-bearing cases:
#   - an aborted stop pushes nothing (the user is at the keyboard) but MUST
#     still record `end`, or the panel keeps claiming the session is working;
#   - beforeSubmitPrompt GATES the user's prompt, so its stdout must stay
#     exactly {"continue": true} with hud_record in the path.
#
# Usage: bash test/hud.e2e.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="${HERE}/../scripts/notify.sh"
ORIG_PATH="${PATH}"
ORIG_HOME="${HOME}"
FAILURES=0

setup() {
    SANDBOX="$(mktemp -d)"
    export HOME="${SANDBOX}/home"
    mkdir -p "${HOME}"
    export VIBEZ_ID="moss-pine-fox-jazz"
    export VIBEZ_BACKEND_URL="http://127.0.0.1:1"   # never reached; curl is shadowed
    export VIBEZ_BLOCK_DEBOUNCE_SECONDS=0
    export VIBEZ_HUD_LOG_MAX_BYTES=2097152
    HUD_LOG="${HOME}/.config/vibez/hud/events.jsonl"
    # Shadow curl so nothing leaves the machine — and so every push attempt is
    # counted, which is how the "pushes nothing" cases prove anything at all.
    CURL_LOG="${SANDBOX}/curl.log"
    BIN="${SANDBOX}/bin"; mkdir -p "${BIN}"
    printf '#!/bin/sh\nprintf "curl\\n" >> "%s"\nexit 0\n' "${CURL_LOG}" > "${BIN}/curl"
    chmod +x "${BIN}/curl"
    export PATH="${BIN}:${ORIG_PATH}"
}
teardown() {
    rm -rf "${SANDBOX}"
    export PATH="${ORIG_PATH}"
    export HOME="${ORIG_HOME}"
}

# Cursor registers ONE argless command for every event and dispatches on the
# payload's hook_event_name.
fire() { printf '%s' "$1" | bash "${NOTIFY}" >/dev/null 2>&1; }

check() {
    local label="$1" want="$2" got="$3"
    if [ "${want}" = "${got}" ]; then printf '  ok   %s\n' "${label}"
    else printf '  FAIL %s\n       want=%s\n       got =%s\n' "${label}" "${want}" "${got}"; FAILURES=$((FAILURES+1)); fi
}

kinds()      { jq -r '.kind' "${HUD_LOG}" 2>/dev/null | tr '\n' ',' ; }
curl_count() { [ -f "${CURL_LOG}" ] && grep -c . "${CURL_LOG}" || echo 0; }

printf 'CursorPlugin HUD writer\n'

# --- every hook writes exactly one record, with the right kind -------------
setup
fire '{"hook_event_name":"sessionStart","conversation_id":"cu1","workspace_roots":["/tmp/proj"]}'
fire '{"hook_event_name":"beforeSubmitPrompt","conversation_id":"cu1","workspace_roots":["/tmp/proj"],"prompt":"go"}'
fire '{"hook_event_name":"afterAgentResponse","conversation_id":"cu1","workspace_roots":["/tmp/proj"],"text":"done thinking"}'
fire '{"hook_event_name":"stop","conversation_id":"cu1","workspace_roots":["/tmp/proj"],"status":"completed"}'
fire '{"hook_event_name":"sessionEnd","conversation_id":"cu1","workspace_roots":["/tmp/proj"]}'
check "cursor kind sequence" "start,prompt,tool,done,end," "$(kinds)"
check "every line is valid json" "ok" "$(jq -e -s 'length > 0' "${HUD_LOG}" >/dev/null 2>&1 && echo ok || echo bad)"
check "agent tag is cu" "cu" "$(jq -r '.agent' "${HUD_LOG}" | sort -u | tr '\n' ' ' | sed 's/ $//')"
check "proj from workspace root" "proj" "$(jq -r '.proj' "${HUD_LOG}" | head -1)"
check "cwd is the workspace root" "/tmp/proj" "$(jq -r '.cwd' "${HUD_LOG}" | head -1)"
check "records carry the schema version" "1" "$(jq -r '.v' "${HUD_LOG}" | sort -u)"
check "start carries the liveness pair" "yes" "$(jq -r 'select(.kind=="start") | if (.agentPid != null and .agentStart != null) then "yes" else "no" end' "${HUD_LOG}" | head -1)"
check "ts is epoch MILLIseconds" "yes" "$(jq -r '.ts | if . > 1000000000000 then "yes" else "no" end' "${HUD_LOG}" | head -1)"
check "prompt record carries the prompt body" "go" "$(jq -r 'select(.kind=="prompt") | .body' "${HUD_LOG}" | head -1)"
check "the stop carries the stashed response" "done thinking" "$(jq -r 'select(.kind=="done") | .body' "${HUD_LOG}" | head -1)"
check "the first prompt becomes the title" "go" "$(jq -r 'select(.kind=="done") | .title' "${HUD_LOG}" | head -1)"
teardown

# --- beforeSubmitPrompt's stdout contract ----------------------------------
# This hook GATES the user's prompt — Cursor waits on its stdout. hud_record
# must not be able to add a single byte to it.
setup
STDOUT="$(printf '%s' '{"hook_event_name":"beforeSubmitPrompt","conversation_id":"cu3","workspace_roots":["/tmp/proj"],"prompt":"go"}' | bash "${NOTIFY}" 2>/dev/null)"
check "beforeSubmitPrompt stdout is exactly the permit" '{"continue": true}' "${STDOUT}"
check "and the prompt still reached the HUD" "prompt," "$(kinds)"
teardown

# --- THE REGRESSION THAT MATTERS -------------------------------------------
# aborted stop = the user hit Stop in the IDE. No push (they're at the
# keyboard), but skipping the RECORD would leave the panel showing WORKING
# until staleness ended it.
setup
fire '{"hook_event_name":"sessionStart","conversation_id":"cu2","workspace_roots":["/tmp/proj"]}'
fire '{"hook_event_name":"stop","conversation_id":"cu2","workspace_roots":["/tmp/proj"],"status":"aborted"}'
check "aborted stop records end, not done" "end" "$(jq -r 'select(.kind!="start") | .kind' "${HUD_LOG}" | head -1)"
check "aborted stop pushes nothing" "0" "$(curl_count)"
teardown

# --- the push debounce must not hide a transition from the HUD -------------
setup
export VIBEZ_BLOCK_DEBOUNCE_SECONDS=300
fire '{"hook_event_name":"stop","conversation_id":"cu4","workspace_roots":["/tmp/proj"],"status":"completed"}'
fire '{"hook_event_name":"stop","conversation_id":"cu4","workspace_roots":["/tmp/proj"],"status":"completed"}'
check "debounced pushes still produce HUD records" "2" "$(jq -r 'select(.kind=="done")' "${HUD_LOG}" | jq -s 'length')"
# ...and the suppression it escaped was real: only ONE push actually went out.
check "the second push really was suppressed" "1" "$(curl_count)"
teardown

# --- the stop classifier picks the kind ------------------------------------
setup
fire '{"hook_event_name":"afterAgentResponse","conversation_id":"cu5","workspace_roots":["/tmp/proj"],"text":"Should I rebase before merging?"}'
fire '{"hook_event_name":"stop","conversation_id":"cu5","workspace_roots":["/tmp/proj"],"status":"completed"}'
check "a stop that asks records needs-input" "tool,needs-input," "$(kinds)"
teardown

# --- an errored stop is a needs-you, not a done ----------------------------
setup
fire '{"hook_event_name":"stop","conversation_id":"cu6","workspace_roots":["/tmp/proj"],"status":"error"}'
check "an errored stop records needs-input" "needs-input," "$(kinds)"
teardown

# --- background agents stay invisible --------------------------------------
setup
fire '{"hook_event_name":"sessionStart","conversation_id":"bg1","workspace_roots":["/tmp/proj"],"is_background_agent":true}'
fire '{"hook_event_name":"beforeSubmitPrompt","conversation_id":"bg1","workspace_roots":["/tmp/proj"],"prompt":"go"}'
fire '{"hook_event_name":"afterAgentResponse","conversation_id":"bg1","workspace_roots":["/tmp/proj"],"text":"x"}'
fire '{"hook_event_name":"stop","conversation_id":"bg1","workspace_roots":["/tmp/proj"],"status":"completed"}'
fire '{"hook_event_name":"sessionEnd","conversation_id":"bg1","workspace_roots":["/tmp/proj"]}'
check "background agents write nothing" "0" \
  "$( [ -f "${HUD_LOG}" ] && jq -r 'select(.sid=="bg1")' "${HUD_LOG}" | jq -s 'length' || echo 0)"
check "background agents push nothing either" "0" "$(curl_count)"
teardown

# --- unusable session ids are dropped --------------------------------------
setup
fire '{"hook_event_name":"afterAgentResponse","conversation_id":"nosid","workspace_roots":["/tmp/proj"],"text":"x"}'
fire '{"hook_event_name":"afterAgentResponse","workspace_roots":["/tmp/proj"],"text":"x"}'
check "nosid and empty sid write nothing" "0" "$( [ -f "${HUD_LOG}" ] && wc -l < "${HUD_LOG}" | tr -d ' ' || echo 0)"
teardown

# --- rotation ---------------------------------------------------------------
setup
export VIBEZ_HUD_LOG_MAX_BYTES=400
for i in 1 2 3 4 5 6 7 8; do
    fire "{\"hook_event_name\":\"afterAgentResponse\",\"conversation_id\":\"cu7\",\"workspace_roots\":[\"/tmp/proj\"],\"text\":\"step ${i}\"}"
done
check "rotates at the byte cap" "yes" "$( [ -f "${HUD_LOG}.1" ] && echo yes || echo no)"
# The cap is checked BEFORE the append, so the live log may exceed it by one
# record. What must hold is that rotation moved records aside rather than
# dropping them — the reader stitches events.jsonl.1 and events.jsonl together.
check "rotation moves records aside, loses none" "8" "$(cat "${HUD_LOG}.1" "${HUD_LOG}" 2>/dev/null | grep -c .)"
check "the live log is the shorter half" "yes" "$( [ "$(grep -c . "${HUD_LOG}")" -lt 8 ] && echo yes || echo no)"
teardown

printf '\n%s\n' "$([ "${FAILURES}" -eq 0 ] && echo 'ALL PASS' || echo "${FAILURES} FAILURE(S)")"
exit "$([ "${FAILURES}" -eq 0 ] && echo 0 || echo 1)"
