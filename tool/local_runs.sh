#!/usr/bin/env bash
# The local (Ollama) benchmark runs, exactly as they were executed — the
# commands behind the numbers in results/. Everything here is free and
# reproducible on one machine; the API-model runs use the same commands with
# a different --config file.
#
#   ./tool/local_runs.sh m3        semantics vs intent, n=5   (~30 min)
#   ./tool/local_runs.sh m4        + genui and the LLM judge  (~60 min)
#   ./tool/local_runs.sh bad       degraded semantics variant (~30 min)
#   ./tool/local_runs.sh vision    external Python agent      (~5 min)
#   ./tool/local_runs.sh calibration  judge calibration sample (~30 min)
#   ./tool/local_runs.sh compare   good vs bad semantics report
#
# Runs resume: re-running the same target continues an interrupted run
# instead of repeating completed episodes.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
FLUTTER="${FLUTTER:-fvm flutter}"
DART="${DART:-fvm dart}"
LIVE=test/benchmark/live/m3_live_benchmark_test.dart
DETERMINISTIC_TASKS=todo.create.simple,todo.create.full,todo.complete.single,todo.rename,todo.update.duedate,todo.delete.single,todo.complete.overdue,todo.delete.completed,todo.create.duplicate_guard,todo.search.narrow,todo.filter.open

require_ollama() {
  curl -sf http://localhost:11434/api/version >/dev/null ||
    { echo "Ollama is not running (brew services start ollama)"; exit 1; }
}

case "${1:-}" in
  m3)
    require_ollama
    cd apps/todo_app
    AIB_LLM_CONFIG=../../suites/agents/ollama.yaml \
    AIB_AGENTS=semantics,intent AIB_REPS=5 \
    AIB_OUT=../../results/m3-ollama-qwen3-8b-n5 \
      $FLUTTER test "$LIVE"
    ;;
  m4)
    require_ollama
    cd apps/todo_app
    AIB_LLM_CONFIG=../../suites/agents/ollama.yaml \
    AIB_JUDGE_CONFIG=../../suites/agents/ollama_judge.yaml \
    AIB_AGENTS=semantics,intent,genui AIB_REPS=5 \
    AIB_OUT=../../results/m4-ollama-qwen3-8b-n5 \
      $FLUTTER test "$LIVE"
    ;;
  bad)
    require_ollama
    cd apps/todo_app
    AIB_LLM_CONFIG=../../suites/agents/ollama.yaml \
    AIB_AGENTS=semantics AIB_REPS=5 AIB_SEMANTICS_QUALITY=bad \
    AIB_TASKS="$DETERMINISTIC_TASKS" \
    AIB_OUT=../../results/m6-bad-semantics-qwen3-8b-n5 \
      $FLUTTER test "$LIVE"
    ;;
  vision)
    require_ollama
    cd apps/todo_app
    AIB_VISION=1 AIB_VISION_DEBUG=1 AIB_REPS=1 \
    AIB_OUT=../../results/m6-vision-qwen25vl \
      $FLUTTER test test/benchmark/live/m6_vision_agent_test.dart
    ;;
  calibration)
    # Judge calibration sample (§5.2): many repetitions of the one judged
    # task, twice with different agent models so the surfaces — and with
    # them the correct labels — actually vary. Label them with
    # tool/genui_label_sheet.py, then run `aib calibrate`.
    require_ollama
    cd apps/todo_app
    for model in qwen3:8b llama3.1:8b; do
      AIB_LLM_CONFIG=../../suites/agents/ollama.yaml AIB_LLM_MODEL="$model" \
      AIB_JUDGE_CONFIG=../../suites/agents/ollama_judge.yaml \
      AIB_AGENTS=genui AIB_TASKS=todo.dashboard.generate AIB_REPS=10 \
      AIB_OUT="../../results/m4-judge-calibration-${model%%:*}" \
        $FLUTTER test "$LIVE"
    done
    cd "$ROOT"
    for dir in results/m4-judge-calibration-*; do
      python3 tool/genui_label_sheet.py "$dir"
    done
    ;;
  compare)
    # semantics_degradation_delta (§6.4): identical suite, degraded build.
    $DART run aib_cli:aib compare \
      --runs "$ROOT/results/m3-ollama-qwen3-8b-n5" \
      --runs "$ROOT/results/m6-bad-semantics-qwen3-8b-n5" \
      --out "$ROOT/results"
    ;;
  *)
    sed -n '2,15p' "$0"
    exit 64
    ;;
esac
