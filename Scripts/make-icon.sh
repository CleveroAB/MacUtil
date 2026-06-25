#!/bin/bash
# Regenerate a *compressed* AppIcon.icns from Resources/AppIconSource.png.
#
# Two size levers:
#   1. Cap at 512px — the source is 500px, so a 1024px slice is pure upscale bloat.
#   2. Run every slice through zopflipng (lossless; invisible at icon sizes).
#      Falls back gracefully to plain sips output if zopflipng isn't installed.
#
# Run this only when the icon image changes — the build just copies the result.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Resources/AppIconSource.png"
OUT="$ROOT/Resources/AppIcon.icns"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"

gen() { sips -z "$1" "$1" "$SRC" --out "$SET/$2" >/dev/null 2>&1; }
# Standard slots, capped at 512px (no 1024 / 512@2x).
gen 16  icon_16x16.png
gen 32  icon_16x16@2x.png
gen 32  icon_32x32.png
gen 64  icon_32x32@2x.png
gen 128 icon_128x128.png
gen 256 icon_128x128@2x.png
gen 256 icon_256x256.png
gen 512 icon_256x256@2x.png
gen 512 icon_512x512.png

# pngquant = lossy palette quantization (the big win, invisible at icon sizes);
# zopflipng = lossless deflate pass on top. Both optional — skipped if absent.
echo "▶ Compressing slices (pngquant + zopflipng)…"
for f in "$SET"/*.png; do
    if command -v pngquant >/dev/null 2>&1; then
        pngquant --force --ext .png --quality=45-90 --skip-if-larger --speed 1 "$f" >/dev/null 2>&1 || true
    fi
    if command -v zopflipng >/dev/null 2>&1; then
        zopflipng -y --lossy_transparent "$f" "$f" >/dev/null 2>&1 || true
    fi
done

iconutil -c icns "$SET" -o "$OUT"
echo "✓ $OUT — $(ls -lh "$OUT" | awk '{print $5}')"
