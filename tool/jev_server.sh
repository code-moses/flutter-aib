#!/usr/bin/env bash
# A local Jev-compatible decision server: featherless-ai/simple-jev on this
# Mac (MPS), speaking the System One shape at http://127.0.0.1:8000/v1/systemone.
# The `jev:` block of a `modelRouter:` config points here by default.
#
#   ./tool/jev_server.sh              install on first use, then serve
#   ./tool/jev_server.sh check        one routing question against a running server
#
# Knobs (environment):
#   JEV_MODEL   HF model id           (default Qwen/Qwen3.5-4B)
#   JEV_DEVICE  auto | mps | cpu      (default auto)
#   JEV_DTYPE   bfloat16 | float16 | float32 (default bfloat16)
#   JEV_PORT    (default 8000)
#
# The model id is also what every request must name: a config's `jev.model`
# has to match JEV_MODEL, or the server answers 422.
#
# simple-jev is pinned to one commit, because its prompt template decides what
# the probabilities mean — a template change is a different decider.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
HOME_DIR="$ROOT/build/jev"
SRC="$HOME_DIR/simple-jev"
VENV="$HOME_DIR/.venv"
COMMIT=b02aa81c915a8193759b3cd33fef74721d6e005b
MODEL="${JEV_MODEL:-Qwen/Qwen3.5-4B}"
PORT="${JEV_PORT:-8000}"

install() {
  mkdir -p "$HOME_DIR"
  if [ ! -d "$SRC/.git" ]; then
    git clone -q https://github.com/featherless-ai/simple-jev.git "$SRC"
  fi
  git -C "$SRC" fetch -q origin "$COMMIT" 2>/dev/null || true
  git -C "$SRC" checkout -q "$COMMIT"
  if [ ! -x "$VENV/bin/python" ]; then
    # simple-jev needs >= 3.12; torch wheels lag the newest Python.
    PY="$(command -v python3.12 || command -v python3.13 || command -v python3)"
    "$PY" -m venv "$VENV"
  fi
  "$VENV/bin/python" -m pip install -q --upgrade pip
  "$VENV/bin/python" -m pip install -q -e "$SRC/hf-server"
  touch "$HOME_DIR/.installed-$COMMIT"
}

case "${1:-serve}" in
serve)
  [ -f "$HOME_DIR/.installed-$COMMIT" ] || install
  echo "simple-jev $COMMIT · $MODEL · http://127.0.0.1:$PORT"
  # The first start downloads the weights into the HF cache (~9 GB for 4B).
  #
  # Serial weight loading: transformers 5 materialises tensors on a thread
  # pool, and two threads casting onto MPS at once race on torch's Metal
  # kernel cache (an unguarded unordered_map) — SIGSEGV in
  # MetalShaderLibrary::exec_unary_kernel during "Loading weights".
  export HF_DEACTIVATE_ASYNC_LOAD="${HF_DEACTIVATE_ASYNC_LOAD:-1}"
  exec "$VENV/bin/simple-jev" \
    --model "$MODEL" \
    --device "${JEV_DEVICE:-auto}" \
    --dtype "${JEV_DTYPE:-bfloat16}" \
    --max-model-len 8192 \
    --port "$PORT"
  ;;
check)
  curl -sf "http://127.0.0.1:$PORT/health" >/dev/null ||
    { echo "no server on :$PORT (./tool/jev_server.sh)"; exit 1; }
  curl -s "http://127.0.0.1:$PORT/v1/systemone" \
    -H 'content-type: application/json' \
    --data-binary @- <<JSON
{"model": "$MODEL",
 "state": "Create a customer named Ada Lovelace with the email ada@example.com.",
 "questions": {
   "route": {"type": "choice",
     "instructions": "Which model should handle this app task?",
     "criteria": {"local": "A small local model is enough.",
                  "cloud": "A frontier model is needed."}},
   "harm": {"type": "noul",
     "instructions": "The task asks to delete or overwrite existing data."}}}
JSON
  echo
  ;;
*)
  echo "usage: $0 [serve|check]" >&2
  exit 2
  ;;
esac
