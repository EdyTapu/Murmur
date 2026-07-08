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

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/Murmur"

# Sign with the stable self-signed "Murmur Dev Signing" identity if present, so
# macOS treats every rebuild as the same app and TCC permission grants survive.
# Falls back to ad-hoc signing when the identity is missing.
SIGN_ID="Murmur Dev Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    codesign --force --sign "$SIGN_ID" --identifier com.alessio.murmur --options runtime "$APP"
    echo "Signed with '$SIGN_ID'"
else
    codesign --force --sign - --identifier com.alessio.murmur "$APP"
    echo "Ad-hoc signed (stable identity not found)"
fi

echo "Built: $APP"
