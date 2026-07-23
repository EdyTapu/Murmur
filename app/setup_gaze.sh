#!/bin/zsh
# One-time setup for Murmur eye control: installs the MediaPipe gaze helper
# (Python venv + face landmark model) into Application Support. Idempotent.
# Usage: zsh app/setup_gaze.sh
set -euo pipefail

SUPPORT="$HOME/Library/Application Support/Murmur"
VENV="$SUPPORT/gaze-env"
MODEL="$SUPPORT/face_landmarker.task"
MODEL_URL="https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/latest/face_landmarker.task"

mkdir -p "$SUPPORT"

# MediaPipe ships wheels for CPython 3.9-3.12; find a usable python3.
PY=""
for cand in python3.12 python3.11 python3.10 python3; do
    if command -v "$cand" >/dev/null 2>&1; then
        minor=$("$cand" -c 'import sys; print(sys.version_info[1])')
        major=$("$cand" -c 'import sys; print(sys.version_info[0])')
        if [[ "$major" == 3 && "$minor" -ge 9 && "$minor" -le 12 ]]; then
            PY="$cand"
            break
        fi
    fi
done
[[ -n "$PY" ]] || { echo "No suitable python3 (3.9-3.12) found on PATH"; exit 1; }
echo "Using $PY ($($PY --version 2>&1))"

if [[ ! -x "$VENV/bin/python" ]]; then
    echo "Creating venv at $VENV"
    "$PY" -m venv "$VENV"
fi

echo "Installing mediapipe + numpy (first run downloads ~600 MB)"
"$VENV/bin/python" -m pip install --quiet --upgrade pip
"$VENV/bin/python" -m pip install --quiet mediapipe numpy

if [[ ! -f "$MODEL" ]]; then
    echo "Downloading face landmark model"
    curl -fsSL -o "$MODEL" "$MODEL_URL"
fi

"$VENV/bin/python" -c "import mediapipe; print('mediapipe', mediapipe.__version__, 'ready')"
echo "Eye-control setup complete. Relaunch Murmur and press ⌃⌥E."
