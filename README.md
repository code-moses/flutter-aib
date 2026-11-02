# AI Interaction Benchmark (AIB) Framework

Benchmark framework for AI-based interaction with Flutter applications —
implementation artifact of the master's thesis *Design and Evaluation of a
Benchmark Framework for AI-based Interaction with Flutter Applications*.
Start with [`docs/overview.md`](docs/overview.md): status, results, the
decisions outside the ADRs, and open threads. The original specification is
[`docs/specification.md`](docs/specification.md) (frozen; code comments cite it
as "spec §x"), the decisions are in [`docs/adr/`](docs/adr/), the diagrams in
[`docs/architecture.md`](docs/architecture.md).

## Repository layout

```
packages/
  aib_core/      Layer 1 — pure Dart core: task model, engine, traces,
                 metrics, evaluation, aggregation, reporting.
                 + lib/testing.dart: MockEnvironment, ScriptedAgent (§10)
  aib_protocol/  Layer 2 — wire protocol 2.0 (JSON-RPC 2.0 over stdio,
                 TCP and in-memory transports, remote agent/environment
                 adapters). test/conformance/ = the formal protocol spec
  aib_flutter/   Layer 3 — FlutterEnvironment and the Semantics, Intent,
                 GenUi, User and Vision bridges (conventions: its README)
  aib_agents/    Layer 3 — LLM reference agents: LlmClient port, ToolLoopAgent,
                 Semantics/Intent/GenUi/Hybrid/Preparing agents, ModelRouter,
                 LlmJudge, frozen versioned prompts (see its README)
  aib_jev/       Layer 3 — decision models (Jev): typed questions, the v1
                 template and scoring, HTTP/Ollama/completions backends
  aib_jev_llama/ Layer 3 — llama.cpp in process, model pinned by SHA-256
  aib_otel/      Layer 3 — OpenTelemetry span export of episodes
  aib_cli/       Layer 4 — `aib` (validate, run, evaluate, report, compare,
                 route, calibrate, labelsheet, selftest, doctor, …) over
                 AibService, the typed service both front ends share
  aib_mcp/       Layer 4 — the CLI over MCP: discover, score, configure,
                 run as jobs, tune on the tuning split; stdio or HTTP
  aib_ui/        Layer 4 — a local web UI: open any folder of runs, read
                 traces, compare, edit configs, start runs (no build step)
apps/
  todo_app/      Test app: todo_v1 (CRUD, search, semantics variants) and
                 the todo_v2 workspace (scope-gated intents)
agents/
  vision_python/ foreign agent: Python, screenshots + pointer, over stdio
  artemis/       Google ARTEMIS attached over a socket
suites/          Task suites (YAML), fixtures, rubrics, references, scripts
                 agents/*.yaml: pinned agent configs ("arms");
                 agents/experiments/: arms derived over MCP
                 splits/: the holdout of each suite
                 pricing_*.yaml: pinned price tables for cost_usd (§6.3)
experiments/     study journals written over MCP
results/         run artifacts (git-ignored)
docs/            overview, specification, architecture, ADRs
tool/            CI guards, local_runs.sh / route_runs.sh (the exact
                 benchmark commands), jev_server.sh, genui_label_sheet.py
```

## Quick start

### Flutter SDK (fvm)

The SDK is pinned to an exact version in [`.fvmrc`](.fvmrc) and managed with
[fvm](https://fvm.app), so every machine and CI build resolves the same way. The
run manifest records the Dart version each run used.

```sh
dart pub global activate fvm         # once, if you don't have fvm yet
fvm install                          # installs the version from .fvmrc
```

Prefix SDK calls with `fvm` (`fvm flutter …`, `fvm dart …`) so they resolve to
the SDK from `.fvmrc` rather than a global install. VS Code picks it up automatically
via `.vscode/settings.json` (`dart.flutterSdkPath`). CI reads the same `.fvmrc`.

```sh
fvm flutter pub get                  # resolves the whole pub workspace

# Tests
for p in aib_core aib_protocol aib_jev aib_jev_llama aib_agents aib_cli aib_mcp aib_otel aib_ui; do
  (cd packages/$p && fvm dart test)
done
(cd packages/aib_flutter && fvm flutter test)
(cd apps/todo_app && fvm flutter test)

# CLI pipeline against the synthetic demo suite (execution and evaluation
# are separate passes — ADR 0003):
fvm dart run aib_cli:aib validate --suite suites/todo_v1.yaml
fvm dart run aib_cli:aib run      --suite suites/mock_v1.yaml \
    --agents scripted=suites/scripts/mock_scripted.yaml --env mock \
    --pricing suites/pricing_2026_08.yaml --out results/demo
fvm dart run aib_cli:aib evaluate --run results/demo   # add --judge suites/agents/anthropic.yaml for genui tasks
fvm dart run aib_cli:aib report   --run results/demo --format md,csv,json,html,junit
fvm dart run aib_cli:aib compare  --runs results/A --runs results/B --out results/
fvm dart run aib_cli:aib gate     --baseline results/A --run results/B   # exit 1 on a regression (CI)
fvm dart run aib_cli:aib calibrate --run results/demo --labels labels.csv
fvm dart run aib_cli:aib selftest --suite suites/mock_v1.yaml \
    --reference suites/scripts/mock_scripted.yaml   # oracles, not agents

# `run` resumes an existing output directory: complete episodes are reused,
# missing/truncated ones and framework faults re-executed (--force re-runs
# everything). Resuming is refused if suite, agents, seed or repetitions
# changed. Repetitions run interleaved (rep 1 of every task, then rep 2, …);
# --repetition-order blocked runs a task's repetitions back to back.
# --cassette record|replay|replayThenLive records the LLM calls to
# <out>/llm/cassette.jsonl or answers them from one; --judge-cassette <file>
# does the same for the judge, so a re-score is free and reproducible.

# Todo app, manually:
(cd apps/todo_app && fvm flutter run --dart-define=SEMANTICS_QUALITY=bad)
```

### Local LLM runs (Ollama)

Development and cross-model runs use a local model, so they cost nothing and
survive API deprecations (spec §12). Setup on macOS:

```sh
brew install ollama
brew services start ollama            # or: ollama serve
ollama pull qwen3:8b                  # the pinned local reference model
ollama pull llama3.1:8b               # second model for cross_model_variance
```

`suites/agents/ollama.yaml` pins the model *and* its sampling window
(`contextTokens` -> `num_ctx`, `think`) — both change what is measured, not
only how well the agent does, so they belong to the run configuration
([ADR 0006](docs/adr/0006-local-llm-reference-runs.md)).

A live run drives the real Todo app through the widget-test harness
(ADR 0004) and writes a complete run directory under `results/`:

```sh
cd apps/todo_app
AIB_LLM_CONFIG=../../suites/agents/ollama.yaml \
  AIB_AGENTS=semantics,intent AIB_REPS=5 \
  AIB_OUT=../../results/m3-ollama \
  fvm flutter test test/benchmark/live/m3_live_benchmark_test.dart
```

All knobs (`AIB_TASKS`, `AIB_LLM_MODEL`, `AIB_JUDGE_CONFIG`, resuming, …):
[`packages/aib_agents/README.md`](packages/aib_agents/README.md).

### MCP

`.mcp.json` registers the MCP server for Claude Code; `aib_mcp.yaml` (plus a
git-ignored `aib_mcp.local.yaml`, see the `.example`) configures runners,
hosts, budget and pinned judges. `fvm dart run packages/aib_mcp/bin/server.dart
--http` serves Streamable HTTP with the bearer token in `$AIB_MCP_TOKEN`.

### UI

`fvm dart run aib_ui` serves the benchmark ledger on http://localhost:8787 —
the run library, an episode reader, comparisons, configs, suites, launching and
an OpenTelemetry receiver for `--otel` exports (see [`packages/aib_ui`](packages/aib_ui/README.md)). Any folder of runs opens,
checkout or not.

melos is optional: `dart pub global activate melos`, then `melos run analyze`
etc. (ADR 0001 — the repo works with plain pub workspaces). Its scripts call
the SDK through `fvm` as well.

## Architecture

Diagrams (mermaid): [docs/architecture.md](docs/architecture.md) — layer
model, core components, episode sequence, run pipeline, port classes, LLM
agent loop, deployment variants, Phase-5 instrumentation.

### In one paragraph

The core owns no vocabulary (ADR 0002): agents and environments exchange
opaque `Envelope`s (`key`, `kind: observe|act`, `payload`) mediated solely by
the `BenchmarkEngine`, which records every exchange as a JSONL trace event —
measurement happens on the wire, agents cannot influence it (P4). Only
`meta.done` / `meta.abort` are reserved. Environments publish their
vocabulary at runtime via `describe()` (discovery à la MCP); unknown keys get
a structured `unsupported`. Evaluation (`finalStateMatch`, `stateSequence`,
`traceAssertion`, partial-credit rules) and the metric catalog (§6.1–6.3) run
as a separate, repeatable pass over persisted traces. Tasks whose final state
does not differ from the initial one — search, filter, navigation — declare
`groundTruth.milestones`: essential states the engine probes after every
exchange and `stateSequence` scores off the recorded timeline.
The wire protocol (`aib_protocol`, JSON-RPC 2.0 since ADR 0009's amendment)
makes both ports language-independent — verified by conformance tests and an
end-to-end run in which a remote agent *and* a remote environment produce
identical verdicts and metrics to the in-process run. Optional capabilities
(state fingerprint, resource samples, warm-up, model identity) are negotiated
in the handshake, so a remote environment keeps its state-diff metrics.
