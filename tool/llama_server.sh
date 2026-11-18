#!/usr/bin/env bash
# One llama.cpp `llama-server` for the benchmark, in place of the Ollama
# service. Arms use `provider: llamacpp` (LlamaCppClient) against it.
#
#   tool/llama_server.sh start gemma4:26b      load the model, wait until /health is ok
#   tool/llama_server.sh start qwen3.5:9b 8081
#   tool/llama_server.sh status | stop | log
#
# MODEL is an Ollama tag or a path to a .gguf. A tag that Ollama stores as one
# GGUF blob (gemma4:*) is loaded from that blob, so the weights are
# byte-identical to the Ollama arm of the same name and nothing is downloaded.
# Ollama keeps the chat template in a layer of its own, not in the GGUF: a blob
# whose GGUF has none falls back to plain ChatML with no tools, and the model
# answers a prompt that never mentions them (gpt-oss did; LlamaCppClient.warmUp
# now refuses such a server). Those models come from the vendor's GGUF instead.
# qwen3.8:27b is not in Ollama: its unsloth UD-Q4_K_M GGUF is downloaded once
# into build/llama/models/.
#
# One GPU: starting a server stops the one that is running. The arm's
# `contextTokens` must equal CTX (one slot, so the whole window is a request's).
#
# Knobs (environment):
#   CTX      context per request          (default 32768)
#   PARALLEL slots; CTX is split by them  (default 1)
#   EXTRA    more llama-server flags
set -euo pipefail

cd "$(dirname "$0")/.."
STATE="build/llama"
PIDFILE="$STATE/server.pid"
LOGFILE="$STATE/server.log"
INFOFILE="$STATE/server.info"
CTX="${CTX:-32768}"
PARALLEL="${PARALLEL:-1}"
mkdir -p "$STATE"

ollama_blob() { # tag -> path of its single GGUF blob, or nothing
  python3 - "$1" <<'PY'
import json, os, sys
name, _, tag = sys.argv[1].partition(":")
root = os.path.expanduser("~/.ollama/models")
path = f"{root}/manifests/registry.ollama.ai/library/{name}/{tag or 'latest'}"
try:
    layers = json.load(open(path))["layers"]
except OSError:
    sys.exit(0)
models = [l for l in layers if l["mediaType"].endswith("image.model")]
if len(models) == 1:
    print(f"{root}/blobs/{models[0]['digest'].replace(':', '-')}")
PY
}

model_args() {
  local m="$1"
  if [ -f "$m" ]; then echo "-m $m"; return; fi
  case "$m" in
  gpt-oss:20b) echo "-hf ggml-org/gpt-oss-20b-GGUF"; return ;;
  qwen3.8:27b)
    local f="$STATE/models/Qwen3.8-27B-UD-Q4_K_M.gguf"
    if [ ! -f "$f" ]; then
      mkdir -p "$STATE/models"
      curl -fL -C - -o "$f.part" "https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-UD-Q4_K_M.gguf" >&2 && mv "$f.part" "$f"
    fi
    echo "-m $f"
    return ;;
  esac
  local blob
  blob="$(ollama_blob "$m")"
  [ -n "$blob" ] || { echo "no GGUF for '$m': pass a .gguf path or add it to model_args" >&2; exit 2; }
  echo "-m $blob"
}

stop() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill "$(cat "$PIDFILE")"
    while kill -0 "$(cat "$PIDFILE")" 2>/dev/null; do sleep 0.5; done
  fi
  rm -f "$PIDFILE" "$INFOFILE"
}

case "${1:-status}" in
start)
  MODEL="${2:?usage: $0 start MODEL [PORT]}"
  PORT="${3:-8080}"
  stop
  # Resolved first: a failure inside $(...) on the command line below would not
  # abort, and a server without a model answers /health all the same.
  ARGS="$(model_args "$MODEL")" || exit 2
  [ -n "$ARGS" ] || exit 2
  # shellcheck disable=SC2086
  nohup llama-server $ARGS --alias "$MODEL" \
    --host 127.0.0.1 --port "$PORT" \
    -c $((CTX * PARALLEL)) --parallel "$PARALLEL" \
    --n-gpu-layers 99 --flash-attn on --jinja --no-webui ${EXTRA:-} \
    >"$LOGFILE" 2>&1 &
  echo $! >"$PIDFILE"
  echo "$MODEL port=$PORT ctx=$CTX parallel=$PARALLEL" >"$INFOFILE"
  for _ in $(seq 1 600); do # a first -hf start downloads the weights
    if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
      echo "ready: $(cat "$INFOFILE")"
      exit 0
    fi
    kill -0 "$(cat "$PIDFILE")" 2>/dev/null || { echo "llama-server exited:" >&2; tail -20 "$LOGFILE" >&2; exit 1; }
    sleep 2
  done
  echo "not ready after 20 minutes; see $LOGFILE" >&2
  exit 1
  ;;
stop) stop ;;
status)
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "running pid $(cat "$PIDFILE"): $(cat "$INFOFILE")"
  else
    echo "not running"
  fi
  ;;
log) tail -f "$LOGFILE" ;;
*)
  echo "usage: $0 start MODEL [PORT] | stop | status | log" >&2
  exit 2
  ;;
esac
