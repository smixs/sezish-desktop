#!/bin/bash
# Builds the styled sezish DMG via dmgbuild: deterministic .DS_Store written in
# Python (no Finder/AppleScript — Finder saves .DS_Store asynchronously, so the
# old approach randomly shipped DMGs with no layout on other Macs). Headless-safe.
# Usage: scripts/make-dmg.sh <path/to/sezish.app> <output.dmg>
set -euo pipefail

APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUT="$2"
DIR="$(cd "$(dirname "$0")/.." && pwd)"

# HiDPI TIFF: 1x scaled down from the @2x render, so Finder picks the right one.
BG2X="$DIR/dist/dmg-bg@2x.png"
[[ -f "$BG2X" ]] || "$DIR/scripts/make-dmg-bg.py"
TMP="$(mktemp -d)"
sips -Z 560 "$BG2X" --out "$TMP/bg-1x.png" >/dev/null
tiffutil -cathidpicheck "$TMP/bg-1x.png" "$BG2X" -out "$TMP/bg.tiff" 2>/dev/null

rm -f "$OUT"
uvx --from 'dmgbuild[badge_icons]' dmgbuild \
    -s "$DIR/scripts/dmg-settings.py" \
    -D app="$APP" -D background="$TMP/bg.tiff" \
    sezish "$OUT"
rm -rf "$TMP"
echo "Built $OUT"
