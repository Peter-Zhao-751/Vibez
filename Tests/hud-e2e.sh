#!/usr/bin/env bash
#
# HUD end-to-end: REAL notify.sh -> the shared events.jsonl -> vibez-hud-probe.
#
# The per-plugin suites (ClaudePlugin/test/hud.e2e.sh and friends) assert what
# each writer puts ON DISK. This one closes the loop: it drives a realistic
# session through the real hook scripts and asserts what the notch app would
# actually RENDER, by running the same HUDEngine the app runs. Nothing here
# touches AppKit, so it is a couple of seconds of shell, not a UI test.
#
# Two things it covers that no per-plugin suite can:
#   - the whole arc (start -> working -> blocked -> replied -> finished) as the
#     reducer resolves it, including the stop grace window that exists to
#     swallow the false-DONE flash;
#   - all three agents writing the SAME log at once, which is how the log is
#     actually used — one file per machine, not one per agent.
#
# Sandboxing is by HOME. notify.sh derives CONFIG_DIR from ${HOME}/.config/vibez
# and VIBEZ_CONFIG_DIR is a no-op, so HOME is the only lever that keeps this off
# the user's real Vibez state; `guard_sandboxed` refuses to fire a hook if that
# ever stops being true.
#
# Usage: bash Tests/hud-e2e.sh [--update-golden]
#        --update-golden rewrites Tests/fixtures/golden-session.json from the
#        observed output. Review the diff — a blind re-record makes the golden
#        assert nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="${ROOT}/VibezHUD/.build/debug/vibez-hud-probe"
GOLDEN="${ROOT}/Tests/fixtures/golden-session.json"
CLAUDE_NOTIFY="${ROOT}/ClaudePlugin/scripts/notify.sh"
CODEX_NOTIFY="${ROOT}/CodexPlugin/scripts/notify.sh"
CURSOR_NOTIFY="${ROOT}/CursorPlugin/scripts/notify.sh"

UPDATE_GOLDEN=0
[ "${1:-}" = "--update-golden" ] && UPDATE_GOLDEN=1

FAILURES=0
ORIG_HOME="${HOME}"
ORIG_PATH="${PATH}"
RECORDED='{}'

# The Codex hook script suppresses every push-producing event when it detects
# it is running as a Claude Code sub-agent, purely from inherited env. This
# suite is usually run FROM Claude Code.
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT

# --- preflight --------------------------------------------------------------

command -v jq >/dev/null 2>&1 || {
    printf 'FATAL: jq is required (brew install jq)\n' >&2; exit 1; }

if [ ! -x "${PROBE}" ]; then
    printf 'FATAL: probe binary not found at\n         %s\n' "${PROBE}" >&2
    printf '       Build it first:\n         (cd %s/VibezHUD && swift build --product vibez-hud-probe)\n' \
        "${ROOT}" >&2
    printf '       (Tests/run-all.sh does this for you.)\n' >&2
    exit 1
fi

SANDBOX_ROOT="$(mktemp -d)" || { printf 'FATAL: mktemp failed\n' >&2; exit 1; }
case "${SANDBOX_ROOT}" in
    /|/Users/*/|"") printf 'FATAL: refusing to use %s as a sandbox\n' "${SANDBOX_ROOT}" >&2; exit 1 ;;
esac
cleanup() {
    export HOME="${ORIG_HOME}"; export PATH="${ORIG_PATH}"
    [ -n "${SANDBOX_ROOT}" ] && rm -rf "${SANDBOX_ROOT}"
}
trap cleanup EXIT

# --- harness ----------------------------------------------------------------

# Every hook invocation goes through here, so the sandbox check cannot be
# skipped by accident. A bug that left HOME pointing at the real home would
# otherwise scribble on the user's live Vibez state and their push history.
guard_sandboxed() {
    case "${HOME}" in
        "${SANDBOX_ROOT}"/*) : ;;
        *) printf 'FATAL: HOME=%s escaped the sandbox; aborting\n' "${HOME}" >&2; exit 1 ;;
    esac
}

# new_sandbox <name> — a fresh fake home with curl shadowed by a COUNTING stub.
# Counting matters: with a bare `exit 0` stub every "nothing was pushed"
# assertion passes whether or not a push happened.
new_sandbox() {
    SANDBOX="${SANDBOX_ROOT}/$1"
    export HOME="${SANDBOX}/home"
    mkdir -p "${HOME}"
    export VIBEZ_ID="moss-pine-fox-jazz"
    export VIBEZ_BACKEND_URL="http://127.0.0.1:1"   # never reached; curl is shadowed
    export VIBEZ_STOP_GRACE_SECONDS=0               # plugin-side deferred stop, not the reducer's
    export VIBEZ_BLOCK_DEBOUNCE_SECONDS=0
    export VIBEZ_HUD_LOG_MAX_BYTES=2097152
    export VIBEZ_APPROVAL_ROOT_PID=$$
    export VIBEZ_APPROVAL_WATCH_SECONDS=1
    CURL_LOG="${SANDBOX}/curl.log"
    local bin="${SANDBOX}/bin"; mkdir -p "${bin}"
    printf '#!/bin/sh\nprintf "curl\\n" >> "%s"\nexit 0\n' "${CURL_LOG}" > "${bin}/curl"
    chmod +x "${bin}/curl"
    export PATH="${bin}:${ORIG_PATH}"
    HUD_LOG="${HOME}/.config/vibez/hud/events.jsonl"
}

curl_count() { [ -f "${CURL_LOG}" ] && grep -c . "${CURL_LOG}" || echo 0; }

check() {
    local label="$1" want="$2" got="$3"
    if [ "${want}" = "${got}" ]; then printf '  ok   %s\n' "${label}"
    else
        printf '  FAIL %s\n       want=%s\n       got =%s\n' "${label}" "${want}" "${got}"
        FAILURES=$((FAILURES+1))
    fi
}

probe() { "${PROBE}" "${HUD_LOG}" 2>/dev/null | jq -S . 2>/dev/null; }

# golden <phase> <label> — the whole rendered snapshot, diffed against the
# fixture. Every field the probe prints is derived, not timestamped, so the
# comparison is exact rather than "some field looks plausible".
golden() {
    local phase="$1" label="$2" got want
    got="$(probe)"
    if [ -z "${got}" ]; then
        printf '  FAIL %s/%s: probe produced nothing\n' "${phase}" "${label}"
        FAILURES=$((FAILURES+1)); return
    fi
    if [ "${UPDATE_GOLDEN}" = "1" ]; then
        RECORDED="$(printf '%s' "${RECORDED}" \
            | jq --arg p "${phase}" --arg l "${label}" --argjson v "${got}" \
                 'setpath([$p,$l]; $v)')"
        printf '  rec  %s/%s\n' "${phase}" "${label}"
        return
    fi
    want="$(jq -S --arg p "${phase}" --arg l "${label}" '.[$p][$l] // empty' "${GOLDEN}" 2>/dev/null)"
    if [ -z "${want}" ]; then
        printf '  FAIL %s/%s: no golden entry (run with --update-golden)\n' "${phase}" "${label}"
        FAILURES=$((FAILURES+1)); return
    fi
    if [ "${want}" = "${got}" ]; then
        printf '  ok   %s/%s renders exactly as recorded\n' "${phase}" "${label}"
    else
        printf '  FAIL %s/%s snapshot drifted\n' "${phase}" "${label}"
        diff <(printf '%s\n' "${want}") <(printf '%s\n' "${got}") | sed 's/^/       /'
        FAILURES=$((FAILURES+1))
    fi
}

# --- per-plugin hook drivers ------------------------------------------------
# Payload shapes differ per agent; the ARC below is identical for all three.

CC_SID="hud-e2e-cc"; CX_SID="hud-e2e-cx"; CU_SID="hud-e2e-cu"
PROJ_CWD="/tmp/vibez-hud-e2e/Vibez"

cc_fire() { guard_sandboxed; printf '%s' "$2" | bash "${CLAUDE_NOTIFY}" "$1" >/dev/null 2>&1; }
cx_fire() { guard_sandboxed; printf '%s' "$2" | bash "${CODEX_NOTIFY}"  "$1" >/dev/null 2>&1; }
cu_fire() { guard_sandboxed; printf '%s' "$1" | bash "${CURSOR_NOTIFY}"      >/dev/null 2>&1; }

# A Claude Code CLI transcript: `last-prompt` is what read_conversation_title
# reads for the session name, the assistant record is the stop excerpt.
write_cc_transcript() {
    CC_TRANSCRIPT="${SANDBOX}/transcript.jsonl"
    {
        printf '%s\n' '{"type":"last-prompt","lastPrompt":"ship the notch app"}'
        printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Pushed the branch."}]}}'
    } > "${CC_TRANSCRIPT}"
}
# A Codex rollout file. Its absence is the ephemeral-thread signal, so every
# non-ephemeral case has to point at a real one.
write_cx_rollout() {
    CX_ROLLOUT="${SANDBOX}/rollout.jsonl"
    printf '%s\n' '{"payload":{"type":"thread_name_updated","thread_name":"ship the notch app"}}' \
        > "${CX_ROLLOUT}"
}

cc_arc_to_blocked() {
    write_cc_transcript
    cc_fire session-start      "{\"session_id\":\"${CC_SID}\",\"cwd\":\"${PROJ_CWD}\",\"transcript_path\":\"${CC_TRANSCRIPT}\"}"
    cc_fire user-prompt-submit "{\"session_id\":\"${CC_SID}\",\"cwd\":\"${PROJ_CWD}\",\"transcript_path\":\"${CC_TRANSCRIPT}\",\"prompt\":\"ship the notch app\"}"
    local t
    for t in Read Grep Edit; do
        cc_fire post-tool-use  "{\"session_id\":\"${CC_SID}\",\"cwd\":\"${PROJ_CWD}\",\"tool_name\":\"${t}\"}"
    done
    cc_fire permission-request "{\"session_id\":\"${CC_SID}\",\"cwd\":\"${PROJ_CWD}\",\"transcript_path\":\"${CC_TRANSCRIPT}\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"vibez-hud-e2e-noexec\"}}"
}
cc_reply() {
    cc_fire user-prompt-submit "{\"session_id\":\"${CC_SID}\",\"cwd\":\"${PROJ_CWD}\",\"transcript_path\":\"${CC_TRANSCRIPT}\",\"prompt\":\"yes, go ahead\"}"
}
cc_stop() {
    cc_fire stop "{\"session_id\":\"${CC_SID}\",\"cwd\":\"${PROJ_CWD}\",\"transcript_path\":\"${CC_TRANSCRIPT}\"}"
}

cx_arc_to_blocked() {
    write_cx_rollout
    cx_fire session-start      "{\"session_id\":\"${CX_SID}\",\"cwd\":\"${PROJ_CWD}\",\"transcript_path\":\"${CX_ROLLOUT}\"}"
    cx_fire user-prompt-submit "{\"session_id\":\"${CX_SID}\",\"cwd\":\"${PROJ_CWD}\",\"transcript_path\":\"${CX_ROLLOUT}\",\"prompt\":\"ship the notch app\"}"
    local t
    for t in Read Grep Edit; do
        cx_fire post-tool-use  "{\"session_id\":\"${CX_SID}\",\"cwd\":\"${PROJ_CWD}\",\"transcript_path\":\"${CX_ROLLOUT}\",\"tool_name\":\"${t}\"}"
    done
    cx_fire permission-request "{\"session_id\":\"${CX_SID}\",\"cwd\":\"${PROJ_CWD}\",\"transcript_path\":\"${CX_ROLLOUT}\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"vibez-hud-e2e-noexec\"}}"
}
cx_reply() {
    cx_fire user-prompt-submit "{\"session_id\":\"${CX_SID}\",\"cwd\":\"${PROJ_CWD}\",\"transcript_path\":\"${CX_ROLLOUT}\",\"prompt\":\"yes, go ahead\"}"
}
cx_stop() {
    cx_fire stop "{\"session_id\":\"${CX_SID}\",\"cwd\":\"${PROJ_CWD}\",\"transcript_path\":\"${CX_ROLLOUT}\",\"last_assistant_message\":\"Pushed the branch.\"}"
}

# Cursor has no permission hook: it reaches "blocked on you" by ending a turn
# on a question, which the stop classifier turns into needs-input.
cu_arc_to_blocked() {
    cu_fire "{\"hook_event_name\":\"sessionStart\",\"conversation_id\":\"${CU_SID}\",\"workspace_roots\":[\"${PROJ_CWD}\"]}"
    cu_fire "{\"hook_event_name\":\"beforeSubmitPrompt\",\"conversation_id\":\"${CU_SID}\",\"workspace_roots\":[\"${PROJ_CWD}\"],\"prompt\":\"ship the notch app\"}"
    local t
    for t in "Reading the reducer." "Grepping the writers." "Editing the store."; do
        cu_fire "{\"hook_event_name\":\"afterAgentResponse\",\"conversation_id\":\"${CU_SID}\",\"workspace_roots\":[\"${PROJ_CWD}\"],\"text\":\"${t}\"}"
    done
    cu_fire "{\"hook_event_name\":\"afterAgentResponse\",\"conversation_id\":\"${CU_SID}\",\"workspace_roots\":[\"${PROJ_CWD}\"],\"text\":\"Should I rebase before merging?\"}"
    cu_fire "{\"hook_event_name\":\"stop\",\"conversation_id\":\"${CU_SID}\",\"workspace_roots\":[\"${PROJ_CWD}\"],\"status\":\"completed\"}"
}
cu_reply() {
    cu_fire "{\"hook_event_name\":\"beforeSubmitPrompt\",\"conversation_id\":\"${CU_SID}\",\"workspace_roots\":[\"${PROJ_CWD}\"],\"prompt\":\"yes, go ahead\"}"
}
cu_stop() {
    cu_fire "{\"hook_event_name\":\"afterAgentResponse\",\"conversation_id\":\"${CU_SID}\",\"workspace_roots\":[\"${PROJ_CWD}\"],\"text\":\"Pushed the branch.\"}"
    cu_fire "{\"hook_event_name\":\"stop\",\"conversation_id\":\"${CU_SID}\",\"workspace_roots\":[\"${PROJ_CWD}\"],\"status\":\"completed\"}"
}

printf 'HUD end-to-end (real notify.sh -> events.jsonl -> vibez-hud-probe)\n'

# === 1. the full arc, per agent =============================================
# Driven for all three FIRST, so the one wall-clock wait for the reducer's
# 3s stop grace is paid once instead of three times.

printf '\n-- the whole arc, as the panel resolves it\n'

new_sandbox claude
cc_arc_to_blocked;  golden blocked  claude
cc_reply;           golden resumed  claude
cc_stop
HOME_CC="${HOME}"; LOG_CC="${HUD_LOG}"

new_sandbox codex
cx_arc_to_blocked;  golden blocked  codex
cx_reply;           golden resumed  codex
cx_stop
HOME_CX="${HOME}"; LOG_CX="${HUD_LOG}"

new_sandbox cursor
cu_arc_to_blocked;  golden blocked  cursor
cu_reply;           golden resumed  cursor
cu_stop
HOME_CU="${HOME}"; LOG_CU="${HUD_LOG}"

# A `done` is provisional until StoreConfig.stopGraceMs (3s) passes in silence
# — that window is the false-DONE-flash fix, and until it closes the session
# keeps its previous state on purpose.
sleep 3.4
export HOME="${HOME_CC}"; HUD_LOG="${LOG_CC}"; golden settled claude
export HOME="${HOME_CX}"; HUD_LOG="${LOG_CX}"; golden settled codex
export HOME="${HOME_CU}"; HUD_LOG="${LOG_CU}"; golden settled cursor

# === 2. one log, three agents ===============================================
# The notch app reads ONE file per machine. Nothing in the per-plugin suites
# exercises three writers sharing it.

printf '\n-- all three agents in one events.jsonl\n'
new_sandbox mixed
write_cc_transcript
write_cx_rollout
cc_fire session-start      "{\"session_id\":\"${CC_SID}\",\"cwd\":\"${PROJ_CWD}\",\"transcript_path\":\"${CC_TRANSCRIPT}\"}"
cc_fire permission-request "{\"session_id\":\"${CC_SID}\",\"cwd\":\"${PROJ_CWD}\",\"transcript_path\":\"${CC_TRANSCRIPT}\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/x\"}}"
cx_fire session-start      "{\"session_id\":\"${CX_SID}\",\"cwd\":\"${PROJ_CWD}\",\"transcript_path\":\"${CX_ROLLOUT}\"}"
cx_fire user-prompt-submit "{\"session_id\":\"${CX_SID}\",\"cwd\":\"${PROJ_CWD}\",\"transcript_path\":\"${CX_ROLLOUT}\",\"prompt\":\"ship the notch app\"}"
cu_fire "{\"hook_event_name\":\"sessionStart\",\"conversation_id\":\"${CU_SID}\",\"workspace_roots\":[\"${PROJ_CWD}\"]}"
cu_fire "{\"hook_event_name\":\"beforeSubmitPrompt\",\"conversation_id\":\"${CU_SID}\",\"workspace_roots\":[\"${PROJ_CWD}\"],\"prompt\":\"ship the notch app\"}"
cu_fire "{\"hook_event_name\":\"sessionEnd\",\"conversation_id\":\"${CU_SID}\",\"workspace_roots\":[\"${PROJ_CWD}\"]}"

check "three agents wrote one log" "3" \
    "$(jq -r '.agent' "${HUD_LOG}" | sort -u | grep -c .)"
check "no session lands in two columns" "3" \
    "$(probe | jq -r '[.needsYou[],.working[],.done[]] | map(.sid) | unique | length')"
golden mixed all-three

# === 3. the auto-resume that must not flash DONE ============================
# Claude Code fires Stop at every turn boundary, including one the harness
# resumes by itself ~1s later. The resume lands inside the grace window and
# must discard the provisional done rather than blink the panel.

printf '\n-- a stop the harness immediately resumes\n'
new_sandbox resume
write_cc_transcript
cc_fire session-start      "{\"session_id\":\"${CC_SID}\",\"cwd\":\"${PROJ_CWD}\",\"transcript_path\":\"${CC_TRANSCRIPT}\"}"
cc_fire user-prompt-submit "{\"session_id\":\"${CC_SID}\",\"cwd\":\"${PROJ_CWD}\",\"transcript_path\":\"${CC_TRANSCRIPT}\",\"prompt\":\"ship the notch app\"}"
cc_stop
cc_fire post-tool-use      "{\"session_id\":\"${CC_SID}\",\"cwd\":\"${PROJ_CWD}\",\"tool_name\":\"Bash\"}"
sleep 3.4
check "the resumed session is working, not done" "working" \
    "$(probe | jq -r '.working[0].state // "none"')"
check "and nothing settled into done" "0" "$(probe | jq -r '.done | length')"

# === 4. the panel is a superset of the phone =================================
# The push path debounces same-conversation blocks to spare the phone a second
# banner. The panel is on the user's screen, so it must show every transition
# anyway — and still render the LATEST one, not the one that got pushed.

printf '\n-- suppressed pushes still reach the panel\n'
new_sandbox superset
export VIBEZ_BLOCK_DEBOUNCE_SECONDS=300
write_cc_transcript
cc_fire session-start "{\"session_id\":\"${CC_SID}\",\"cwd\":\"${PROJ_CWD}\",\"transcript_path\":\"${CC_TRANSCRIPT}\"}"
# tool_name Edit, not Bash: Bash additionally spawns the detached approval
# watcher, whose own push would race the curl count below.
for n in first second third; do
    cc_fire permission-request "{\"session_id\":\"${CC_SID}\",\"cwd\":\"${PROJ_CWD}\",\"transcript_path\":\"${CC_TRANSCRIPT}\",\"tool_name\":\"Edit\",\"tool_input\":{\"step\":\"${n}\"}}"
done
check "three asks reached the log" "3" "$(jq -r 'select(.kind=="needs-input")' "${HUD_LOG}" | jq -s 'length')"
check "the phone was pushed exactly once" "1" "$(curl_count)"
check "the panel shows the ask, blocked" "needsYou" "$(probe | jq -r '.needsYou[0].state // "none"')"
check "and it shows the LATEST ask" 'Edit: {"step":"third"}' "$(probe | jq -r '.needsYou[0].detail // "none"')"

# --- done -------------------------------------------------------------------

if [ "${UPDATE_GOLDEN}" = "1" ]; then
    mkdir -p "$(dirname "${GOLDEN}")"
    printf '%s\n' "${RECORDED}" | jq -S . > "${GOLDEN}"
    printf '\nrecorded golden -> %s\n' "${GOLDEN}"
    printf 'REVIEW THE DIFF before committing.\n'
    exit 0
fi

printf '\n%s\n' "$([ "${FAILURES}" -eq 0 ] && echo 'ALL PASS' || echo "${FAILURES} FAILURE(S)")"
exit "$([ "${FAILURES}" -eq 0 ] && echo 0 || echo 1)"
