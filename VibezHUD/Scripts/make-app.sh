#!/usr/bin/env bash
#
# VibezHUD/Scripts/make-app.sh — assemble a launchable VibezHUD.app
#
# The HUD has to be a bundle, not a bare SwiftPM binary: LSUIElement (no Dock
# icon, no menu-bar item) is an Info.plist key, and there is no Info.plist
# without a bundle. Same reason it needs a bundle identifier — NSPanel at the
# status-bar level behaves, but LaunchServices wants an identity.
#
# Usage: ./Scripts/make-app.sh [output/path/VibezHUD.app]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-${HERE}/build/VibezHUD.app}"

cd "${HERE}"
swift build -c release --product VibezHUDApp

rm -rf "${OUT}"
mkdir -p "${OUT}/Contents/MacOS" "${OUT}/Contents/Resources"
cp "${HERE}/.build/release/VibezHUDApp" "${OUT}/Contents/MacOS/VibezHUD"
# SwiftPM resources (the agent-chip artwork): Bundle.module resolves against
# Contents/Resources inside an .app, so the bundle must ship there.
cp -R "${HERE}/.build/release/VibezHUD_VibezHUDApp.bundle" "${OUT}/Contents/Resources/"

cat > "${OUT}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>VibezHUD</string>
  <key>CFBundleDisplayName</key><string>Vibez HUD</string>
  <key>CFBundleIdentifier</key><string>vibezlol.VibezHUD</string>
  <key>CFBundleExecutable</key><string>VibezHUD</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <!-- Agent app: no Dock icon, no menu bar presence. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature is enough for a locally built personal tool.
codesign --force --deep --sign - "${OUT}" >/dev/null 2>&1 || true

printf 'built %s\n' "${OUT}"
printf 'run:   open "%s"\n' "${OUT}"
printf 'login: System Settings > General > Login Items > add it\n'
