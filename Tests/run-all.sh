#!/usr/bin/env bash
#
# One command, one verdict. Runs every automated check the HUD work has:
# the Swift reducer/reader unit tests, the probe build, each plugin's hook and
# HUD-writer suites, each plugin's in-script _selftest, and the cross-plugin
# end-to-end that drives the real hooks and asserts what the panel renders.
#
# Everything here is hermetic: the shell suites sandbox HOME, and every one of
# them shadows curl, so nothing leaves the machine and the user's real
# ~/.config/vibez is never touched.
#
# Usage: ./Tests/run-all.sh
# Exit:  0 only when every step passed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=()
PASSED=0

step() {
    local name="$1"; shift
    printf '\n================================================================\n'
    printf '=== %s\n' "${name}"
    printf '================================================================\n'
    if "$@"; then
        printf -- '--- pass: %s\n' "${name}"
        PASSED=$((PASSED+1))
    else
        printf -- '--- FAIL: %s\n' "${name}"
        FAILED+=("${name}")
    fi
}

# The Codex hook script suppresses every push-producing event when it detects
# Claude Code in its inherited env, which is exactly what happens when this
# runner is invoked from a Claude Code session. Each suite unsets these for
# itself; doing it here too keeps the _selftest invocations honest.
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT

# --- Swift package ----------------------------------------------------------
# Build the probe BEFORE the end-to-end step, which shells out to
# .build/debug/vibez-hud-probe.
step "swift unit tests (VibezSessionKit)" \
    bash -c "cd '${ROOT}/VibezHUD' && swift test"
step "build vibez-hud-probe" \
    bash -c "cd '${ROOT}/VibezHUD' && swift build --product vibez-hud-probe"

# --- Claude Code plugin -----------------------------------------------------
step "claude: hook selftest"   bash "${ROOT}/ClaudePlugin/scripts/notify.sh" _selftest
step "claude: push hooks e2e"  bash "${ROOT}/ClaudePlugin/test/hooks.e2e.sh"
step "claude: HUD writer e2e"  bash "${ROOT}/ClaudePlugin/test/hud.e2e.sh"

# --- Codex plugin -----------------------------------------------------------
step "codex: hook selftest"    bash "${ROOT}/CodexPlugin/scripts/notify.sh" _selftest
step "codex: HUD writer e2e"   bash "${ROOT}/CodexPlugin/test/hud.e2e.sh"

# --- Cursor plugin ----------------------------------------------------------
step "cursor: hook selftest"   bash "${ROOT}/CursorPlugin/scripts/notify.sh" _selftest
step "cursor: push hooks e2e"  bash "${ROOT}/CursorPlugin/test/hooks.e2e.sh"
step "cursor: HUD writer e2e"  bash "${ROOT}/CursorPlugin/test/hud.e2e.sh"

# --- the whole pipeline -----------------------------------------------------
step "HUD end-to-end (hooks -> log -> probe)" bash "${ROOT}/Tests/hud-e2e.sh"

# --- verdict ----------------------------------------------------------------
printf '\n================================================================\n'
if [ "${#FAILED[@]}" -eq 0 ]; then
    printf 'ALL GREEN  (%d/%d steps passed)\n' "${PASSED}" "${PASSED}"
    exit 0
fi
printf '%d of %d steps FAILED:\n' "${#FAILED[@]}" "$((PASSED + ${#FAILED[@]}))"
for f in "${FAILED[@]}"; do printf '  - %s\n' "${f}"; done
exit 1
