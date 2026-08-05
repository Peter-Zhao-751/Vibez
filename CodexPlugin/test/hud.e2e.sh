#!/usr/bin/env bash
#
# End-to-end test for the HUD sidecar log the notch app tails (Codex side).
#
# Feeds realistic hook payloads through the REAL notify.sh with curl shadowed,
# then asserts what landed in ~/.config/vibez/hud/events.jsonl. Sandboxing is
# by HOME (notify.sh derives CONFIG_DIR from it) — VIBEZ_CONFIG_DIR is a no-op
# in this script.
#
# The load-bearing case is "debounced pushes still produce HUD records": the
# push path suppresses events on purpose to protect the phone, and the HUD
# must see every transition anyway. That only holds while hud_record is called
# at the EVENT SITE and never from inside post_vibez.
#
# Codex-specific: ephemeral Codex Desktop sub-threads (thread-title generation,
# summarization) fire the whole hook lifecycle and must stay invisible to the
# HUD, and there is NO SessionEnd hook — Codex sessions reach ENDED through PID
# liveness instead.
#
# Usage: bash test/hud.e2e.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="${HERE}/../scripts/notify.sh"
HOOKS_JSON="${HERE}/../hooks.json"
ORIG_PATH="${PATH}"
ORIG_HOME="${HOME}"
FAILURES=0

# notify.sh suppresses EVERY push-producing event when it thinks Codex is
# running as a Claude Code sub-agent, which it detects purely from inherited
# env. This suite is usually run FROM Claude Code, so without this the whole
# dispatch table would exit 0 before any handler ran.
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT

setup() {
    SANDBOX="$(mktemp -d)"
    export HOME="${SANDBOX}/home"
    mkdir -p "${HOME}"
    export VIBEZ_ID="moss-pine-fox-jazz"
    export VIBEZ_BACKEND_URL="http://127.0.0.1:1"   # never reached; curl is shadowed
    export VIBEZ_BLOCK_DEBOUNCE_SECONDS=0
    export VIBEZ_HUD_LOG_MAX_BYTES=2097152
    export VIBEZ_APPROVAL_WATCH_SECONDS=1
    HUD_LOG="${HOME}/.config/vibez/hud/events.jsonl"
    # A real Codex session always has a rollout file on disk by the time hooks
    # fire; a missing one is precisely the ephemeral-thread signal, so every
    # non-ephemeral case has to point at a real file.
    ROLLOUT="${SANDBOX}/rollout.jsonl"
    printf '%s\n' '{"payload":{"type":"thread_name_updated","thread_name":"add the notch hud"}}' >"${ROLLOUT}"
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

printf 'CodexPlugin HUD writer\n'

# --- every hook writes exactly one record, with the right kind -------------
setup
fire session-start "{\"session_id\":\"s1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${ROLLOUT}\"}"
fire user-prompt-submit "{\"session_id\":\"s1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${ROLLOUT}\",\"prompt\":\"do the thing\"}"
# No pending marker: the push path deliberately stays silent for an autonomous
# tool call, but the HUD still needs the transition.
fire post-tool-use "{\"session_id\":\"s1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${ROLLOUT}\",\"tool_name\":\"Edit\"}"
fire permission-request "{\"session_id\":\"s1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${ROLLOUT}\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"vibez-hud-e2e-noexec-rm\"}}"
fire stop "{\"session_id\":\"s1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${ROLLOUT}\",\"last_assistant_message\":\"I committed the change.\"}"
check "one record per hook, in order" "start,prompt,tool,needs-input,done," "$(kinds)"
check "every line is valid json" "ok" "$(jq -e -s 'length > 0' "${HUD_LOG}" >/dev/null 2>&1 && echo ok || echo bad)"
check "records carry identity" "proj" "$(jq -r 'select(.kind=="tool") | .proj' "${HUD_LOG}" | head -1)"
check "records carry the cwd" "/tmp/proj" "$(jq -r 'select(.kind=="tool") | .cwd' "${HUD_LOG}" | head -1)"
check "records carry a tool name" "Edit" "$(jq -r 'select(.kind=="tool") | .tool' "${HUD_LOG}" | head -1)"
check "records carry the agent tag" "cx" "$(jq -r '.agent' "${HUD_LOG}" | sort -u | tr '\n' ' ' | sed 's/ $//')"
check "records carry the schema version" "1" "$(jq -r '.v' "${HUD_LOG}" | sort -u)"
check "start carries the liveness pair" "yes" "$(jq -r 'select(.kind=="start") | if (.agentPid != null and .agentStart != null) then "yes" else "no" end' "${HUD_LOG}" | head -1)"
check "ts is epoch MILLIseconds" "yes" "$(jq -r '.ts | if . > 1000000000000 then "yes" else "no" end' "${HUD_LOG}" | head -1)"
check "prompt record carries the prompt body" "do the thing" "$(jq -r 'select(.kind=="prompt") | .body' "${HUD_LOG}" | head -1)"
check "records carry the thread name as title" "add the notch hud" "$(jq -r 'select(.kind=="prompt") | .title' "${HUD_LOG}" | head -1)"
teardown

# --- THE REGRESSION THAT MATTERS -------------------------------------------
# The push path debounces same-conversation blocks. The HUD must still see them.
setup
export VIBEZ_BLOCK_DEBOUNCE_SECONDS=300
fire permission-request "{\"session_id\":\"s2\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${ROLLOUT}\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"vibez-hud-e2e-first\"}}"
fire permission-request "{\"session_id\":\"s2\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${ROLLOUT}\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"vibez-hud-e2e-second\"}}"
check "debounced pushes still produce HUD records" "2" "$(jq -r 'select(.kind=="needs-input")' "${HUD_LOG}" | jq -s 'length')"
# ...and the suppression it escaped was real: only ONE push actually went out.
check "the second push really was suppressed" "1" "$(curl_count)"
teardown

# --- slash-command sessions: invisible to the phone, whole in the panel -----
# The push path skips slash commands on purpose (a /vibez:setup invocation
# shouldn't banner the phone). Gating the RECORDS on the same check pinned every
# /codex:rescue-style session at WORKING for its entire life: `tool` records kept
# arriving from post-tool-use (which never had the gate above it), and
# done/needs-input never did.
setup
SLASH_ROLLOUT="${SANDBOX}/slash-rollout.jsonl"
printf '%s\n' '{"payload":{"type":"thread_name_updated","thread_name":"/codex:rescue fix the build"}}' >"${SLASH_ROLLOUT}"
fire session-start "{\"session_id\":\"sl1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${SLASH_ROLLOUT}\"}"
fire user-prompt-submit "{\"session_id\":\"sl1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${SLASH_ROLLOUT}\",\"prompt\":\"/codex:rescue fix the build\"}"
fire post-tool-use "{\"session_id\":\"sl1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${SLASH_ROLLOUT}\",\"tool_name\":\"Edit\"}"
fire stop "{\"session_id\":\"sl1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${SLASH_ROLLOUT}\",\"last_assistant_message\":\"Fixed the build.\"}"
check "a slash-command session records the full sequence" "start,prompt,tool,done," "$(kinds)"
check "...while pushing absolutely nothing" "0" "$(curl_count)"
check "the row leaves WORKING" "done" "$(jq -r '.kind' "${HUD_LOG}" | tail -1)"
# The picker gate behaves the same way (permission-request never had a gate).
fire pre-tool-use "{\"session_id\":\"sl1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${SLASH_ROLLOUT}\",\"tool_name\":\"request_user_input\",\"tool_input\":{\"questions\":[{\"question\":\"Which approach?\"}]}}"
check "the ask gate records too" "start,prompt,tool,done,needs-input," "$(kinds)"
check "...and still does not push" "0" "$(curl_count)"
check "the records carry the slash command as the title" "/codex:rescue fix the build" \
    "$(jq -r 'select(.kind=="done") | .title' "${HUD_LOG}" | head -1)"
teardown

# --- unusable session ids are dropped --------------------------------------
setup
fire post-tool-use "{\"session_id\":\"nosid\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${ROLLOUT}\",\"tool_name\":\"Read\"}"
fire post-tool-use "{\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${ROLLOUT}\",\"tool_name\":\"Read\"}"
check "nosid and empty sid write nothing" "0" "$( [ -f "${HUD_LOG}" ] && wc -l < "${HUD_LOG}" | tr -d ' ' || echo 0)"
teardown

# --- ephemeral sessions never render a row ---------------------------------
# Codex Desktop runs an ephemeral sub-LLM thread per turn (thread titles,
# summarization). They fire the full hook lifecycle but never write a rollout
# file, and they are not conversations the user has any interest in seeing.
#
# The ephemeral gate therefore sits on every handler that produces a VISIBLE
# row — prompt / tool / needs-input / done — and deliberately NOT on
# session-start. A lone `start` seeds the reducer at .idle, and .idle renders
# in no column (SessionStore.snapshot skips it), so gating session-start too
# would buy no invisibility while costing every real session whose rollout
# file isn't on disk yet its agentPid/agentStart (liveness) and appPid/app
# (click-to-jump) — the only record that carries them.
setup
fire session-start '{"session_id":"eph1","cwd":"/tmp/proj","ephemeral":true}'
fire user-prompt-submit '{"session_id":"eph1","cwd":"/tmp/proj","prompt":"summarize this"}'
fire post-tool-use '{"session_id":"eph1","cwd":"/tmp/proj","tool_name":"Read"}'
fire pre-tool-use '{"session_id":"eph1","cwd":"/tmp/proj","tool_name":"request_user_input","tool_input":{"questions":[{"question":"Which?"}]}}'
fire stop '{"session_id":"eph1","cwd":"/tmp/proj","last_assistant_message":"{\"title\":\"x\"}"}'
check "an ephemeral session records only start" "start," \
  "$(jq -r 'select(.sid=="eph1") | .kind' "${HUD_LOG}" | tr '\n' ',')"
check "no row-producing kind ever lands for an ephemeral session" "0" \
  "$(jq -r 'select(.sid=="eph1" and .kind != "start")' "${HUD_LOG}" | jq -s 'length')"
check "ephemeral sessions push nothing either" "0" "$(curl_count)"
teardown

# --- a session-start with no rollout file still carries liveness -----------
# THE regression this pins: is_ephemeral_session means "rollout file missing",
# and nothing guarantees Codex has written the rollout by the time SessionStart
# fires. Gating the start record on it silently stripped agentPid/agentStart
# (so a killed terminal could only reach ENDED via the ~30min staleness path)
# and appPid/app (so click-to-jump had no target) from real sessions.
setup
fire session-start '{"session_id":"cold1","cwd":"/tmp/proj"}'
check "a rollout-less session-start still records" "start," "$(kinds)"
check "...and still carries the liveness pair" "yes" \
  "$(jq -r 'select(.kind=="start") | if (.agentPid != null and .agentStart != null) then "yes" else "no" end' "${HUD_LOG}" | head -1)"
teardown

# --- agent tag --------------------------------------------------------------
setup
fire post-tool-use "{\"session_id\":\"c1\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${ROLLOUT}\",\"tool_name\":\"Edit\"}"
check "agent tag is cx" "cx" "$(jq -r '.agent' "${HUD_LOG}" | head -1)"
teardown

# --- the stop classifier picks the kind ------------------------------------
setup
fire stop "{\"session_id\":\"s4\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${ROLLOUT}\",\"last_assistant_message\":\"Should I rebase before merging?\"}"
check "a stop that asks records needs-input" "needs-input," "$(kinds)"
teardown

# --- a stop with no excerpt still ends the turn in the panel ----------------
# The push path skips this one (a contentless done is noise on the phone), but
# skipping the RECORD would leave the session showing WORKING until staleness
# ended it — the panel lying about a finished turn.
setup
fire stop "{\"session_id\":\"s9\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${ROLLOUT}\"}"
check "an excerpt-less stop still records done" "done," "$(kinds)"
check "an excerpt-less stop records exactly one" "1" "$(grep -c . "${HUD_LOG}")"
check "an excerpt-less stop has an empty body" "null" "$(jq -r '.body // "null"' "${HUD_LOG}" | head -1)"
check "an excerpt-less stop pushes nothing" "0" "$(curl_count)"
teardown

# --- the request_user_input picker ------------------------------------------
setup
fire pre-tool-use "{\"session_id\":\"s6\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${ROLLOUT}\",\"tool_name\":\"request_user_input\",\"tool_input\":{\"questions\":[{\"question\":\"Which approach?\"}]}}"
check "an ask records needs-input" "needs-input," "$(kinds)"
check "the ask carries the question" "Which approach?" "$(jq -r '.body' "${HUD_LOG}" | head -1)"
check "the ask names the tool" "request_user_input" "$(jq -r '.tool' "${HUD_LOG}" | head -1)"
teardown

# --- rotation ---------------------------------------------------------------
setup
export VIBEZ_HUD_LOG_MAX_BYTES=400
for i in 1 2 3 4 5 6 7 8; do fire post-tool-use "{\"session_id\":\"s3\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"${ROLLOUT}\",\"tool_name\":\"T${i}\"}"; done
check "rotates at the byte cap" "yes" "$( [ -f "${HUD_LOG}.1" ] && echo yes || echo no)"
# The cap is checked BEFORE the append, so the live log may exceed it by one
# record. What must hold is that rotation moved records aside rather than
# dropping them — the reader stitches events.jsonl.1 and events.jsonl together.
check "rotation moves records aside, loses none" "8" "$(cat "${HUD_LOG}.1" "${HUD_LOG}" 2>/dev/null | grep -c .)"
check "the live log is the shorter half" "yes" "$( [ "$(grep -c . "${HUD_LOG}")" -lt 8 ] && echo yes || echo no)"
teardown

# --- Codex has no SessionEnd hook ------------------------------------------
# Pinned deliberately: Codex sessions reach ENDED through PID liveness, so
# nobody should "fix" the missing end record by inventing a hook Codex's
# registry does not fire.
if jq -e 'has("hooks") and (.hooks | has("SessionEnd") | not)' "${HOOKS_JSON}" >/dev/null 2>&1; then
    printf '  ok   hooks-json-registers-no-session-end\n'
else
    printf '  FAIL hooks-json-registers-no-session-end\n'; FAILURES=$((FAILURES+1))
fi

printf '\n%s\n' "$([ "${FAILURES}" -eq 0 ] && echo 'ALL PASS' || echo "${FAILURES} FAILURE(S)")"
exit "$([ "${FAILURES}" -eq 0 ] && echo 0 || echo 1)"
