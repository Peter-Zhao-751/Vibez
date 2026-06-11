#!/usr/bin/env bash
# Renders the App Store carousel in both accepted iPhone sizes:
#   export/6.9-display/  1320×2868
#   export/6.5-display/  1242×2688
# The agents spread renders double-wide, then ffmpeg splits it into its two
# screenshot halves. The band between the halves (66px @6.9 / 62px @6.5) is
# deliberately dropped — it's the slice the App Store gallery gutter visually
# swallows, matching the approved preview geometry.
set -euo pipefail
cd "$(dirname "$0")/.."

render_set() { # $1 suffix ("" or "65")  $2 outdir  $3 pane_w  $4 pane_h  $5 right_x
  local sfx="$1" out="$2" w="$3" h="$4" rx="$5"
  mkdir -p "$out"
  npx remotion still "Slide1Pitch$sfx" "$out/slide-1-pitch.png"
  npx remotion still "Slide2Ping$sfx" "$out/slide-2-ping.png"
  npx remotion still "Slide3Spread$sfx" "$out/spread-full.png"
  npx remotion still "Slide4Setup$sfx" "$out/slide-5-setup.png"
  ffmpeg -y -i "$out/spread-full.png" -vf "crop=$w:$h:0:0" "$out/slide-3-agents-left.png" 2>/dev/null
  ffmpeg -y -i "$out/spread-full.png" -vf "crop=$w:$h:$rx:0" "$out/slide-4-agents-right.png" 2>/dev/null
  rm "$out/spread-full.png"
}

render_set ""   export/6.9-display 1320 2868 1386
render_set "65" export/6.5-display 1242 2688 1304

echo "---"
file export/6.9-display/*.png export/6.5-display/*.png | sed 's/PNG image data, //'
echo "Upload order: 1-pitch, 2-ping, 3-agents-left, 4-agents-right, 5-setup"
