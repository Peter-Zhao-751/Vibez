#!/usr/bin/env bash
# Renders the App Store carousel: four Remotion stills, then splits the
# double-wide agents spread into its two screenshot halves (the 66px band
# between them is deliberately dropped — it's the slice the App Store
# gallery gutter visually swallows, matching the approved preview).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=export
mkdir -p "$OUT"

npx remotion still Slide1Pitch "$OUT/slide-1-pitch.png"
npx remotion still Slide2Ping "$OUT/slide-2-ping.png"
npx remotion still Slide3Spread "$OUT/spread-full.png"
npx remotion still Slide4Setup "$OUT/slide-5-setup.png"

ffmpeg -y -i "$OUT/spread-full.png" -vf "crop=1320:2868:0:0" "$OUT/slide-3-agents-left.png" 2>/dev/null
ffmpeg -y -i "$OUT/spread-full.png" -vf "crop=1320:2868:1386:0" "$OUT/slide-4-agents-right.png" 2>/dev/null

echo "---"
ls -la "$OUT"
echo "Upload order: 1-pitch, 2-ping, 3-agents-left, 4-agents-right, 5-setup"
