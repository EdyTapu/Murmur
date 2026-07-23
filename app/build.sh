#!/bin/zsh
# Build Murmur.app from the SwiftPM package.
# Usage: zsh app/build.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Murmur.app"

cd "$ROOT"
swift build -c "$CONFIG" --product Murmur

BIN="$ROOT/.build/$CONFIG/Murmur"
[[ -f "$BIN" ]] || { echo "Binary not found: $BIN"; exit 1; }

# This project lives under an iCloud-synced folder (~/Desktop/Claude), which
# leaves "* 2.app"/"* 3.app" duplicate bundles and re-stamps com.apple.FinderInfo
# xattrs that break `codesign --strict`. Sweep both before assembling.
setopt NULL_GLOB
rm -rf "$ROOT/build/"*" "[0-9]".app"
unsetopt NULL_GLOB

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/Murmur"
cp "$ROOT/app/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Strip any inherited extended attributes so the signature verifies strictly.
xattr -cr "$APP" 2>/dev/null || true

# Sign with the stable self-signed "Murmur Dev Signing" identity if present, so
# macOS treats every rebuild as the same app and TCC permission grants survive.
# Falls back to ad-hoc signing when the identity is missing.
ENTITLEMENTS="$ROOT/app/Murmur.entitlements"
SIGN_ID="Murmur Dev Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    # Hardened runtime (--options runtime) so TCC grants survive rebuilds, plus
    # the entitlements that let a hardened-runtime app reach the mic + AppleEvents.
    # Without the entitlements the mic prompt silently never appears.
    codesign --force --sign "$SIGN_ID" --identifier com.alessio.murmur \
        --options runtime --entitlements "$ENTITLEMENTS" "$APP"
    echo "Signed with '$SIGN_ID' + entitlements"
else
    codesign --force --sign - --identifier com.alessio.murmur \
        --entitlements "$ENTITLEMENTS" "$APP"
    echo "Ad-hoc signed with entitlements (stable identity not found)"
fi

echo "Built: $APP"
