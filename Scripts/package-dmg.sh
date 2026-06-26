#!/bin/bash
# Build MacUtil and package a signed DMG for GitHub Releases.
# Usage: Scripts/package-dmg.sh [release|debug]   (default: release)
#
# Optional notarization:
#   MACUTIL_NOTARY_PROFILE="<xcrun notarytool keychain profile>" Scripts/package-dmg.sh
set -euo pipefail

APP_NAME="MacUtil"
CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/$APP_NAME.app"
DIST="$ROOT/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
SHA="$DMG.sha256"

find_signing_identity() {
    if [ -n "${MACUTIL_SIGN_ID:-}" ]; then
        echo "$MACUTIL_SIGN_ID"
        return
    fi

    local sign_id
    sign_id="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application/{print $2; exit}')"
    [ -z "$sign_id" ] && sign_id="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/{print $2; exit}')"
    [ -z "$sign_id" ] && sign_id="-"
    echo "$sign_id"
}

"$ROOT/Scripts/build-app.sh" "$CONFIG"

mkdir -p "$DIST"
STAGE="$(mktemp -d "$ROOT/build/dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

echo "▶ Staging DMG contents…"
cp -R "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG" "$SHA"
echo "▶ Creating $DMG …"
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG"

SIGN_ID="$(find_signing_identity)"
if [ "$SIGN_ID" = "-" ]; then
    echo "▶ Skipping DMG signing (no Developer ID or Apple Development identity found)…"
else
    echo "▶ Signing DMG with $SIGN_ID …"
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
    codesign --verify --verbose "$DMG"
fi

if [ -n "${MACUTIL_NOTARY_PROFILE:-}" ]; then
    echo "▶ Submitting DMG for notarization using keychain profile $MACUTIL_NOTARY_PROFILE …"
    xcrun notarytool submit "$DMG" \
        --keychain-profile "$MACUTIL_NOTARY_PROFILE" \
        --wait

    echo "▶ Stapling notarization ticket…"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
else
    echo "ⓘ Not notarized. Set MACUTIL_NOTARY_PROFILE to notarize and staple the DMG."
fi

shasum -a 256 "$DMG" | tee "$SHA"

echo "✓ Packaged $DMG"
echo "✓ Checksum $SHA"
