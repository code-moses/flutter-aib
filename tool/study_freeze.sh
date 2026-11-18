#!/usr/bin/env bash
# Writes a study freeze: everything a reported batch of runs
# must agree on, in one file, before the batch starts.
#
#   tool/study_freeze.sh experiments/<study>/FREEZE.md [ollama-tag ...]
#
# Records: framework and app commits with their dirty state, suite and fixture
# hashes as the loader computes them (with the private held-out files when this
# checkout has them), the judge and arm configs, Ollama model digests for the
# tags named, the GGUF files llama-server would load, runtime versions, OS and
# hardware. Runs whose manifests disagree with the freeze are not part of the
# batch. A dirty framework tree is written down, not refused; a reported batch
# should start from a clean, committed tree.
set -uo pipefail
FW="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP:-}"  # the app checkout under test, if any
OUT="${1:?usage: tool/study_freeze.sh <out.md> [ollama-tag ...]}"
shift
cd "$FW"

rev() { # dir -> "commit (branch), clean|dirty: N files"
  local d=$1
  [ -d "$d/.git" ] || [ -f "$d/.git" ] || { echo "not a git checkout"; return; }
  local head branch dirty
  head=$(git -C "$d" rev-parse --short=12 HEAD)
  branch=$(git -C "$d" rev-parse --abbrev-ref HEAD)
  dirty=$(git -C "$d" status --porcelain --untracked-files=no | wc -l | tr -d ' ')
  if [ "$dirty" = 0 ]; then echo "$head ($branch), clean"; else echo "$head ($branch), dirty: $dirty tracked file(s) changed"; fi
}

{
  echo "# Study freeze, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "## Code"
  echo "- framework: $(rev "$FW")"
  if [ -n "$APP" ]; then
    echo "- app: $(rev "$APP")"
    if [ -f "$APP/pubspec_overrides.yaml" ]; then echo "- app uses the local framework (pubspec_overrides.yaml present)"; else echo "- app uses the pinned framework packages"; fi
  fi
  echo
  echo "## Suites (as SuiteLoader.loadFile computes them)"
  for s in suites/sysco_v1.yaml suites/todo_v1.yaml suites/todo_v2.yaml; do
    private=no; [ -f "${s%.yaml}.private.yaml" ] && private=yes
    line=$(fvm dart run aib_cli:aib validate --suite "$s" 2>/dev/null | grep -i -E "hash|task" | head -2 | tr '\n' ' ')
    echo "- $s (private file: $private): $line"
  done
  echo
  echo "## Inputs (sha256, first 16)"
  for f in suites/fixtures/*.json suites/rubrics/*.yaml suites/agents/ollama_judge_k1_llamacpp.yaml suites/agents/ollama_user_llama.yaml suites/pricing_2026_09.yaml; do
    echo "- $f $(shasum -a 256 "$f" | cut -c1-16)"
  done
  echo
  echo "## Models"
  for tag in "$@"; do
    echo "- ollama $tag: $(ollama show --modelfile "$tag" 2>/dev/null | grep -m1 '^FROM' | sed 's/^FROM //')"
  done
  for f in build/llama/models/*.gguf; do
    [ -f "$f" ] && echo "- gguf $f $(stat -f %z "$f") bytes"
  done
  echo
  echo "## Runtimes"
  echo "- $(llama-server --version 2>&1 | head -1)"
  echo "- $(ollama --version 2>&1 | head -1)"
  echo "- $(fvm flutter --version 2>/dev/null | head -1)"
  echo "- $(fvm dart --version 2>&1 | head -1)"
  echo
  echo "## Machine"
  echo "- $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "- $(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
} > "$OUT"
echo "wrote $OUT"
