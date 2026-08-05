#!/usr/bin/env bash
#
# End-to-end test for the HUD sidecar log the notch app tails.
#
# Feeds realistic hook payloads through the REAL notify.sh with curl shadowed,
# then asserts what landed in ~/.config/vibez/hud/events.jsonl. Sandboxing is
# by HOME (notify.sh derives CONFIG_DIR from it), same as hooks.e2e.sh — a
# real HOME would also make read_conversation_title grep the user's actual
# desktop-app session files.
#
# The load-bearing case is "debounced pushes still produce HUD records": the
# push path suppresses events on purpose to protect the phone, and the HUD
# must see every transition anyway. That only holds while hud_record is called
# at the EVENT SITE and never from inside post_vibez.
#
# Usage: bash test/hud.e2e.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="${HERE}/../scripts/notify.sh"
HOOKS_JSON="${HERE}/../hooks/hooks.json"
ORIG_PATH="${PATH}"
ORIG_HOME="${HOME}"
FAILURES=0

setup() {
    SANDBOX="$(mktemp -d)"
    export HOME="${SANDBOX}/home"
    mkdir -p "${HOME}"
    export VIBEZ_ID="moss-pine-fox-jazz"
    export VIBEZ_BACKEND_URL="http://127.0.0.1:1"   # never reached; curl is shadowed
    export VIBEZ_STOP_GRACE_SECONDS=0
    export VIBEZ_BLOCK_DEBOUNCE_SECONDS=0
    export VIBEZ_HUD_LOG_MAX_BYTES=2097152
    export VIBEZ_APPROVAL_ROOT_PID=$$   # test seam: this shell is the tree root
    export VIBEZ_APPROVAL_WATCH_SECONDS=1
    HUD_LOG="${HOME}/.config/vibez/hud/events.jsonl"
    # Shadow curl so nothing leaves the machine — and so every push attempt is
    # counted, which is how the debounce case proves the push was suppressed.
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

fire() { printf '%s' "$2" | bash "${NOTIFY}" "$1" >/dev/null 2>&1; }

check() {
    local label="$1" want="$2" got="$3"
    if [ "${want}" = "${got}" ]; then printf '  ok   %s\n' "${label}"
    else printf '  FAIL %s\n       want=%s\n       got =%s\n' "${label}" "${want}" "${got}"; FAILURES=$((FAILURES+1)); fi
}

kinds()      { jq -r '.kind' "${HUD_LOG}" 2>/dev/null | tr '\n' ',' ; }
curl_count() { [ -f "${CURL_LOG}" ] && grep -c . "${CURL_LOG}" || echo 0; }

printf 'ClaudePlugin HUD writer\n'

# --- every hook writes exactly one record, with the right kind -------------
setup
TRANSCRIPT="${SANDBOX}/t.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"I committed the change."}]}}' >"${TRANSCRIPT}"
fire session-start "{\"session_id\":\"s1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${TRANSCRIPT}\"}"
fire user-prompt-submit '{"session_id":"s1","cwd":"/tmp/proj","prompt":"do the thing"}'
# No pending marker: the push path deliberately stays silent for an autonomous
# tool call, but the HUD still needs the transition.
fire post-tool-use '{"session_id":"s1","cwd":"/tmp/proj","tool_name":"Edit"}'
fire permission-request '{"session_id":"s1","cwd":"/tmp/proj","tool_name":"Bash","tool_input":{"command":"vibez-hud-e2e-noexec-rm"}}'
fire stop "{\"session_id\":\"s1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${TRANSCRIPT}\"}"
check "one record per hook, in order" "start,prompt,tool,needs-input,done," "$(kinds)"
check "every line is valid json" "ok" "$(jq -e -s 'length > 0' "${HUD_LOG}" >/dev/null 2>&1 && echo ok || echo bad)"
check "records carry identity" "proj" "$(jq -r 'select(.kind=="tool") | .proj' "${HUD_LOG}" | head -1)"
check "records carry the cwd" "/tmp/proj" "$(jq -r 'select(.kind=="tool") | .cwd' "${HUD_LOG}" | head -1)"
check "records carry a tool name" "Edit" "$(jq -r 'select(.kind=="tool") | .tool' "${HUD_LOG}" | head -1)"
check "records carry the agent tag" "cc" "$(jq -r '.agent' "${HUD_LOG}" | sort -u | tr '\n' ' ' | sed 's/ $//')"
check "records carry the schema version" "1" "$(jq -r '.v' "${HUD_LOG}" | sort -u)"
check "start carries the liveness pair" "yes" "$(jq -r 'select(.kind=="start") | if (.agentPid != null and .agentStart != null) then "yes" else "no" end' "${HUD_LOG}" | head -1)"
check "ts is epoch MILLIseconds" "yes" "$(jq -r '.ts | if . > 1000000000000 then "yes" else "no" end' "${HUD_LOG}" | head -1)"
check "prompt record carries the prompt body" "do the thing" "$(jq -r 'select(.kind=="prompt") | .body' "${HUD_LOG}" | head -1)"
teardown

# --- THE REGRESSION THAT MATTERS -------------------------------------------
# The push path debounces same-conversation blocks. The HUD must still see them.
setup
export VIBEZ_BLOCK_DEBOUNCE_SECONDS=300
fire permission-request '{"session_id":"s2","cwd":"/tmp/proj","tool_name":"Bash","tool_input":{"command":"vibez-hud-e2e-first"}}'
fire permission-request '{"session_id":"s2","cwd":"/tmp/proj","tool_name":"Bash","tool_input":{"command":"vibez-hud-e2e-second"}}'
check "debounced pushes still produce HUD records" "2" "$(jq -r 'select(.kind=="needs-input")' "${HUD_LOG}" | jq -s 'length')"
# ...and the suppression it escaped was real: only ONE push actually went out.
check "the second push really was suppressed" "1" "$(curl_count)"
teardown

# --- slash-command sessions: invisible to the phone, whole in the panel -----
# THE other regression. The push path skips slash commands on purpose (a
# /vibez:setup invocation shouldn't banner the phone). Gating the RECORDS on the
# same check pinned every /ultracode, /loop and /codex:rescue session at WORKING
# for its entire life: `tool` records kept arriving from post-tool-use (which
# never had the gate above it), and done/needs-input never did.
setup
SLASH="${SANDBOX}/slash.jsonl"
printf '%s\n' '{"type":"last-prompt","lastPrompt":"/ultracode ship the notch hud"}' >"${SLASH}"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Shipped it."}]}}' >>"${SLASH}"
fire session-start "{\"session_id\":\"sl1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${SLASH}\"}"
fire user-prompt-submit "{\"session_id\":\"sl1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${SLASH}\",\"prompt\":\"/ultracode ship the notch hud\"}"
fire post-tool-use "{\"session_id\":\"sl1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${SLASH}\",\"tool_name\":\"Edit\"}"
fire stop "{\"session_id\":\"sl1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${SLASH}\"}"
check "a slash-command session records the full sequence" "start,prompt,tool,done," "$(kinds)"
check "...while pushing absolutely nothing" "0" "$(curl_count)"
check "the row leaves WORKING" "done" "$(jq -r '.kind' "${HUD_LOG}" | tail -1)"
# The three needs-input gates behave the same way.
fire permission-request "{\"session_id\":\"sl1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${SLASH}\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"vibez-hud-e2e-noexec\"}}"
fire notification "{\"session_id\":\"sl1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${SLASH}\",\"message\":\"Claude needs your permission to use Bash\"}"
fire pre-tool-use "{\"session_id\":\"sl1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${SLASH}\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"questions\":[{\"question\":\"Which approach?\"}]}}"
check "every needs-input gate records too" \
    "start,prompt,tool,done,needs-input,needs-input,needs-input," "$(kinds)"
check "...and still none of them push" "0" "$(curl_count)"
# (rtrim: read_conversation_title's last-prompt path newline-joins with `tr`,
# which leaves one trailing space on every title it returns — not this test's
# business, and identical for slash and non-slash sessions.)
check "the records carry the slash command as the title" "/ultracode ship the notch hud" \
    "$(jq -r 'select(.kind=="done") | .title' "${HUD_LOG}" | head -1 | sed -E 's/[[:space:]]+$//')"
teardown

# --- unusable session ids are dropped --------------------------------------
setup
fire post-tool-use '{"session_id":"nosid","cwd":"/tmp/proj","tool_name":"Read"}'
fire post-tool-use '{"cwd":"/tmp/proj","tool_name":"Read"}'
check "nosid and empty sid write nothing" "0" "$( [ -f "${HUD_LOG}" ] && wc -l < "${HUD_LOG}" | tr -d ' ' || echo 0)"
teardown

# --- the stop classifier picks the kind ------------------------------------
setup
TRANSCRIPT="${SANDBOX}/asking.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Should I rebase before merging?"}]}}' >"${TRANSCRIPT}"
fire stop "{\"session_id\":\"s4\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${TRANSCRIPT}\"}"
check "a stop that asks records needs-input" "needs-input," "$(kinds)"
teardown

# --- a stop with no excerpt still ends the turn in the panel ----------------
# The push path skips this one (a contentless "Claude finished a turn." is
# noise on the phone), but skipping the RECORD would leave the session showing
# WORKING until staleness ended it — the panel lying about a finished turn.
setup
fire stop "{\"session_id\":\"s9\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${SANDBOX}/never-written.jsonl\"}"
check "an excerpt-less stop still records done" "done," "$(kinds)"
check "an excerpt-less stop records exactly one" "1" "$(grep -c . "${HUD_LOG}")"
check "an excerpt-less stop has an empty body" "null" "$(jq -r '.body // "null"' "${HUD_LOG}" | head -1)"
check "an excerpt-less stop pushes nothing" "0" "$(curl_count)"
teardown

# --- the AskUserQuestion picker ---------------------------------------------
setup
fire pre-tool-use '{"session_id":"s6","cwd":"/tmp/proj","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which approach?"}]}}'
check "an ask records needs-input" "needs-input," "$(kinds)"
check "the ask carries the question" "Which approach?" "$(jq -r '.body' "${HUD_LOG}" | head -1)"
check "the ask names the tool" "AskUserQuestion" "$(jq -r '.tool' "${HUD_LOG}" | head -1)"
teardown

# --- notification: records the real ask, inherits the idle-reminder skip ----
setup
fire notification '{"session_id":"s7","cwd":"/tmp/proj","message":"Claude needs your permission to use Bash"}'
check "a permission notification records needs-input" "needs-input," "$(kinds)"
# The 60s idle nag is not a new transition — the one suppression the HUD
# deliberately shares with the push path.
fire notification '{"session_id":"s8","cwd":"/tmp/proj","message":"Claude is waiting for your input"}'
check "the idle reminder writes nothing" "needs-input," "$(kinds)"
teardown

# --- session-end records, and never pushes ---------------------------------
setup
fire session-end '{"session_id":"s5","cwd":"/tmp/proj","reason":"clear"}'
check "session-end records the end" "end," "$(kinds)"
check "session-end never touches the network" "0" "$(curl_count)"
teardown

# --- rotation ---------------------------------------------------------------
setup
export VIBEZ_HUD_LOG_MAX_BYTES=400
for i in 1 2 3 4 5 6 7 8; do fire post-tool-use "{\"session_id\":\"s3\",\"cwd\":\"/tmp/proj\",\"tool_name\":\"T${i}\"}"; done
check "rotates at the byte cap" "yes" "$( [ -f "${HUD_LOG}.1" ] && echo yes || echo no)"
# The cap is checked BEFORE the append, so the live log may exceed it by one
# record. What must hold is that rotation moved records aside rather than
# dropping them — the reader stitches events.jsonl.1 and events.jsonl together.
check "rotation moves records aside, loses none" "8" "$(cat "${HUD_LOG}.1" "${HUD_LOG}" 2>/dev/null | grep -c .)"
check "the live log is the shorter half" "yes" "$( [ "$(grep -c . "${HUD_LOG}")" -lt 8 ] && echo yes || echo no)"
teardown

# --- hooks.json wires SessionEnd -------------------------------------------
if jq -e '.hooks.SessionEnd[0].hooks[0].command | test("session-end")' "${HOOKS_JSON}" >/dev/null 2>&1; then
    printf '  ok   hooks-json-registers-session-end\n'
else
    printf '  FAIL hooks-json-registers-session-end\n'; FAILURES=$((FAILURES+1))
fi

printf '\n%s\n' "$([ "${FAILURES}" -eq 0 ] && echo 'ALL PASS' || echo "${FAILURES} FAILURE(S)")"
exit "$([ "${FAILURES}" -eq 0 ] && echo 0 || echo 1)"
