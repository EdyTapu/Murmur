#!/bin/zsh
# Build (if needed) and launch Murmur.app.
# Usage: zsh app/launch.sh [--rebuild]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Murmur.app"

if [[ "${1:-}" == "--rebuild" || ! -d "$APP" ]]; then
    zsh "$ROOT/app/build.sh" release
fi

# Relaunch cleanly.
pkill -x Murmur 2>/dev/null || true
sleep 0.3
open "$APP"
echo "Launched Murmur (menu bar: waveform icon)."
