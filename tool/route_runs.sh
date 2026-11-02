#!/usr/bin/env bash
# The model-routing runs: arms of todo_v2 that differ only in
# `modelRouter.decider` (suites/agents/routed_v2_*.yaml), then the oracle
# comparison they exist for.
#
#   ./tool/route_runs.sh arms       run the arms in $ARMS          (~1–2 h at n=1)
#   ./tool/route_runs.sh score      aib route over them
#
# Knobs: ARMS (default: local cloud rules jev jev2 jev3), AIB_REPS (1), TAG
# (run-directory prefix, default route-v2), RESULTS (default ./results).
# The n=3 sweep: AIB_REPS=3 TAG=route-v2-n3 ARMS="local cloud rules jev2 jev3".
#
# Needs Ollama (qwen3:1.7b and qwen3:8b; qwen3:4b for jev3) and, for the
# jev and jev2 arms, ./tool/jev_server.sh on :8000. Runs resume: re-running
# continues an interrupted arm instead of repeating finished episodes.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
FLUTTER="${FLUTTER:-fvm flutter}"
DART="${DART:-fvm dart}"
LIVE=test/benchmark/live/v2_live_benchmark_test.dart
REPS="${AIB_REPS:-1}"
ARMS="${ARMS:-local cloud rules jev jev2 jev3}"
TAG="${TAG:-route-v2}"
RESULTS="${RESULTS:-$ROOT/results}"

case "${1:-}" in
arms)
  curl -sf http://localhost:11434/api/version >/dev/null ||
    { echo "Ollama is not running (brew services start ollama)"; exit 1; }
  for arm in $ARMS; do
    if [ "$arm" = jev ] || [ "$arm" = jev2 ]; then
      curl -sf http://127.0.0.1:8000/health >/dev/null ||
        { echo "no jev server on :8000 (./tool/jev_server.sh)"; exit 1; }
    fi
    echo "=== $arm ==="
    (cd apps/todo_app &&
      AIB_AGENT=../../suites/agents/routed_v2_$arm.yaml \
      AIB_AGENTS=prepared AIB_REPS="$REPS" \
      AIB_OUT="$RESULTS/$TAG-$arm" \
        $FLUTTER test "$LIVE")
  done
  ;;
score)
  # Judge once per run (writes verdicts.json), then compare. `aib route`
  # would otherwise re-judge every arm on every invocation: slow, and two
  # invocations would not even produce the same numbers, because the judge
  # is a model. Re-scoring after this is instant and stable.
  for arm in $ARMS; do
    dir="$RESULTS/$TAG-$arm"
    [ -d "$dir" ] || continue
    [ -f "$dir/verdicts.json" ] && continue
    echo "=== judging $arm ==="
    $DART run aib_cli:aib evaluate \
      --run "$dir" \
      --suite "$ROOT/suites/todo_v2.yaml" \
      --judge "$ROOT/suites/agents/ollama_judge.yaml" \
      --metrics routing,prefetch
  done
  routed=""
  for arm in $ARMS; do
    case "$arm" in
      local | cloud) ;;
      *) routed="$routed --routed $RESULTS/$TAG-$arm" ;;
    esac
  done
  # shellcheck disable=SC2086
  $DART run aib_cli:aib route \
    --local "$RESULTS/$TAG-local" \
    --cloud "$RESULTS/$TAG-cloud" \
    $routed \
    --suite "$ROOT/suites/todo_v2.yaml" \
    --metrics routing,prefetch \
    --out "$RESULTS/$TAG-report"
  ;;
*)
  sed -n '2,16p' "$0"
  exit 64
  ;;
esac
