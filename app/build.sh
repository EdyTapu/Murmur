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

# Ad-hoc sign with a stable identifier so TCC grants survive as well as they can.
codesign --force --sign - --identifier com.alessio.murmur "$APP"

echo "Built: $APP"
