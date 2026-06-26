#!/bin/bash
# Build MacUtil and assemble a signed .app bundle.
# Usage: Scripts/build-app.sh [release|debug]   (default: release)
set -euo pipefail

APP_NAME="MacUtil"
CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/$APP_NAME.app"

echo "▶ Compiling ($CONFIG)…"
BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$BIN_DIR/$APP_NAME"

echo "▶ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Sign with a stable identity when available so macOS keeps Accessibility /
# Screen Recording grants across rebuilds. Prefer Developer ID, then Apple
# Development, else ad-hoc. Override with MACUTIL_SIGN_ID (name or SHA-1).
if [ -n "${MACUTIL_SIGN_ID:-}" ]; then
    SIGN_ID="$MACUTIL_SIGN_ID"
else
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application/{print $2; exit}')"
    [ -z "$SIGN_ID" ] && SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/{print $2; exit}')"
    [ -z "$SIGN_ID" ] && SIGN_ID="-"
fi

if [ "$SIGN_ID" = "-" ]; then
    echo "▶ Code-signing (ad-hoc — TCC grants may reset on rebuild)…"
    codesign --force --sign "$SIGN_ID" "$APP"
else
    echo "▶ Code-signing with stable hardened-runtime identity ($SIGN_ID)…"
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi

echo "✓ Built $APP"
