#!/usr/bin/env bash
#
# VibezHUD/Scripts/install-launch-agent.sh — build the HUD and keep it
# running LIVE at login. No arguments on the ProgramArguments line is the
# point: --demo is a dev flag, and a login item that ever carried it would
# put fake sessions on the notch forever (exactly the 2026-08-05 bug).
#
# Usage: ./Scripts/install-launch-agent.sh [--uninstall]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="lol.vibez.hud"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
APP="${HERE}/build/VibezHUD.app"
BIN="${APP}/Contents/MacOS/VibezHUD"

if [ "${1:-}" = "--uninstall" ]; then
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    rm -f "${PLIST}"
    printf 'uninstalled %s\n' "${LABEL}"
    exit 0
fi

"${HERE}/Scripts/make-app.sh" "${APP}"

mkdir -p "${HOME}/Library/LaunchAgents"
cat > "${PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>${BIN}</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
PLIST

# Re-bootstrap so an already-installed agent picks up the fresh binary.
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${PLIST}"
printf 'installed %s -> %s\n' "${LABEL}" "${BIN}"
