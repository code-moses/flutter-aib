#!/usr/bin/env bash
# A local Jev-compatible decision server on MediaPipe's Decision Maker task
# (tool/mediapipe_jev_server.py), with EmbeddingGemma 2 text 270M. Serves the
# System One shape at http://127.0.0.1:8092/v1/systemone.
#
#   ./tool/mediapipe_jev_server.sh        install on first use, then serve
#
# Knobs (environment): MP_PORT (default 8092). mediapipe and the model are
# pinned, because the model is the decider.
set -euo pipefail

cd "$(dirname "$0")/.."
HOME_DIR="$PWD/build/mediapipe_jev"
VENV="$HOME_DIR/.venv"
MODEL="$HOME_DIR/embeddinggemma-2-text-270m.litertlm"
MODEL_URL=https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm/resolve/main/embeddinggemma-2-text-270m.litertlm
PORT="${MP_PORT:-8092}"

mkdir -p "$HOME_DIR"
if [ ! -x "$VENV/bin/python" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q mediapipe==1.1.1
fi
[ -f "$MODEL" ] || curl -sL -o "$MODEL" "$MODEL_URL"
exec "$VENV/bin/python" -I tool/mediapipe_jev_server.py --model "$MODEL" --port "$PORT"
