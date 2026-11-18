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
# Murmur quits gracefully on SIGTERM (to undo a muted output), which takes a
# moment and never happens if the app is frozen. Wait for it, then force it:
# `open` on a still-running copy would only bring that old copy forward.
pkill -x Murmur 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x Murmur >/dev/null || break
    sleep 0.3
done
pkill -9 -x Murmur 2>/dev/null || true
sleep 0.3
open "$APP"
echo "Launched Murmur (menu bar: waveform icon)."
