# aib_agents — LLM reference agents (Layer 3)

Reference implementations that validate the framework (spec §7). All agents
share one skeleton (`ToolLoopAgent`): same prompt structure, same loop
logic, same telemetry capture — they differ **only** in envelope keys, tool
set and system prompt, which keeps the strategy comparison fair.

| Agent | observes | acts | tools presented to the model |
|---|---|---|---|
| `SemanticsAgent` | `semantics.tree` (bootstrap + on demand) | `semantics.tap/setText/scroll/showOnScreen` | `observe_tree`, `tap`, `set_text`, `scroll`, `show_on_screen`, `done`, `abort` |
| `IntentAgent` | `intents.catalog` (bootstrap) | `intents.invoke` | one tool per discovered intent + `done`, `abort` |
| `GenUiAgent` | `data.context` (bootstrap), `genui.catalog` | `genui.render` | `observe_data`, `observe_ui_catalog`, `render_ui`, `done`, `abort` |
| `HybridAgent` | configurable bootstrap | all of the above + `user.ask` | union (or cascade step) of the strategies it enables |

Every agent's tools come from a shared `ToolStrategy` object
(`SemanticsStrategy`, `IntentStrategy`, `GenUiStrategy`, `UserStrategy`), not
from a list declared inside the agent. That is deliberate: the hybrid is an
*ablation* of the other three, so it has to offer literally the same tools
with the same descriptions. Sharing the objects makes that true by
construction instead of something a reviewer has to verify by reading two
files side by side.

### HybridAgent

The agent the product ships. Same `ToolLoopAgent`, so loop,
telemetry, retry policy and prompt scaffold are held constant and the only
variable is the routing:

```yaml
router:
  router: union            # union | cascade
  strategies: [intents, genui, user, semantics]
  bootstrap: intents.catalog
  escalation:              # cascade only
    from: intents
    to: semantics
    on: [unsupported, failed]
```

`union` offers everything at once and lets the model choose — the
recommended default. `cascade` starts on one strategy and falls back when the
environment says it cannot deliver. Both write `route=<strategy>` (and, on a
fallback, `reason=escalation …`) into `AgentDecision.note`, which is where
`strategy_switch_count`, `escalation_count` and `escalation_recovered` come
from — no extra instrumentation, and it applies retroactively to any trace
whose agent wrote the annotations.

The `compact` profile (fewer tools, first-sentence descriptions) was removed
on 2026-09-11: it scored worse than `full` and broke genui. A config still
naming it fails to load; `profile: full` is accepted and means nothing.

It rebuilds its intent tools whenever an `intents.catalog` observation
arrives, so opening a form mid-episode changes what the agent can do without
a prompt change. It knows nothing about any particular app: everything
instance-specific reaches it as an observation, never as prompt text.

Design notes:

- **Deterministic bootstrap:** the first observation is emitted without an
  LLM call — episode openings are identical across models.
- **Telemetry** (`AgentDecision`) aggregates every LLM call of a `next()`
  step (tokens, latency, call count) and rides on the emitted envelope;
  it is self-reported by definition (spec §4.3) and marked as such.
- **Prompts are frozen and versioned** (`Prompts.semanticsV2`, …). Never
  edit in place: add a new version and bump `promptVersion`.
- **Failure semantics:** the client's `LlmRetryPolicy` retries what can
  succeed on a retry (rate limits, transport, 5xx) with bounded exponential
  backoff that honours `Retry-After`, and does not retry what cannot (a
  context overflow, a bad key). Then `meta.abort` with a *classified*
  reason, `llm_error:<kind>: …`, because "the context window overflowed" and
  "the agent gave up" are opposite findings that used to be one number.
  Unknown tool calls are answered with an error tool-result so the model can
  self-correct (bounded, then abort).
- **Cancellation:** `agent.cancel()` aborts the in-flight call. The
  production runtime needs it — a user who closes the assistant must not
  leave a request running that bills tokens and resolves into a turn nobody
  is watching.
- **Observation window:** with `agent.observationWindow: n`, tool results
  older than the last *n* are replaced by a stub before the request is built
  (the full history stays in the trace). Null keeps the old unbounded
  behaviour, which is fine for a todo app and not for an app whose
  observations are tens of KB.

## Configuration

An agent YAML has up to three blocks. The flat legacy shape (just the `llm:`
keys at top level) still works.

```yaml
llm:                          # -> LlmClientFactory: the connection
  provider: azure             # anthropic | openai | azure | ollama
  resourceUrl: https://sysco-eu.openai.azure.com
  deployment: sysco-prod      # Azure addresses deployments, not models
  modelId: gpt-4o-2024-11-20  # what it actually is — needed for pricing
  apiVersion: "2024-10-21"
  apiKeyEnv: AZURE_OPENAI_API_KEY
  retry: {maxAttempts: 3, timeoutSeconds: 120}
agent:                        # -> AgentConfig: what changes the measurement
  maxCompletionTokens: 2048
  supportsTemperature: false  # reasoning deployments reject the parameter
  parallelToolCalls: false
  observationWindow: 8
router: {...}                 # -> RouterConfig (hybrid only)
```

Everything under `agent:` and `router:` is recorded in the run manifest,
together with `promptHash`, `agentConfigHash` and `routerConfigHash` — the
three fields the product's release gate compares between a shipped build and
the benchmark run that cleared it. Every other block
(`preparation:`, `modelRouter:`, `decisions:`) is hashed into
`configBlocks`.

`AgentProfile.build(agent, config, client:, decisions:)` turns such a config
into an agent. The harness registry and an app both call it, so a shipped
agent and a measured one are built the same way. Only the clients differ.

### A decision model in the loop (`decisions:`)

A `decisions:` block puts an `aib_jev` decision model into the loop
(docs/overview.md, Model routing and Jev, ideas 3–5). Each feature is its own sub-block, so an arm
can vary one at a time:

```yaml
decisions:
  client: {backend: ollama, model: qwen3:4b, format: qwen3}   # a jev: block
  language: auto              # questions in the task's language (en | de | auto)
  maxStateChars: 6000         # what a check or guard reads of the episode
  completionCheck:            # noul "the goal holds" before done may leave
    threshold: 0.5
    maxRejections: 1          # a done is sent back at most this often
  guard:                      # noul "wanted and safe" before an act runs
    mode: shadow              # enforce | shadow (record only)
    allowAbove: 0.7
    denyBelow: 0.3
    onConfirm: proceed        # the unsure middle: proceed | ask (user.ask) | deny
    intents: [form.submit, 'action.*']   # empty = every act
  selection: {threshold: 0.5} # for preparation.strategy: jev
```

- **Completion check.** A `done` whose noul is below the threshold goes
  back to the model as the call's tool result, at most `maxRejections`
  times per episode. The check reads the task, the latest results as the
  model saw them, and the model's claim.
- **Guard.** It reviews covered acts. `enforce` stops a denied act and
  tells the model why. `onConfirm: ask` holds the act behind a
  `user.ask {type: confirm}` and runs it only on a yes. `shadow` records
  and never interferes, which is how to measure a guard before trusting it.
- **Selection.** `preparation.strategy: jev` asks one noul per catalogue
  intent, per configured listing and per listing row, against an absolute
  threshold. Unlike BM25's relative cut, it can therefore decide that
  nothing is relevant. `discoveryQuery: none` fetches whole listings for
  it to select from. `escapeHatchScope: relevant` lists unrelated intents
  by name only. The `fetch` axis adds follow-up reads for the rows kept,
  such as a `data.search` in the data list the model judged relevant. The
  rules name the app's vocabulary, and a rule whose intent the catalogue
  marks `act` is refused.

A decision model that fails falls back to the harmless default: the `done`
leaves, the act runs (`onError: deny` to invert), and the preparer keeps
every candidate. Every decision rides on the next envelope as
`extra.decisions`, with its spend as a side call priced at the decision
model's own rate (`side_call_cost_usd`). `--metrics decisions` counts
checks, rejections, reviews, denials and decision latency. Arms:
`suites/agents/{hybrid_union_checked,hybrid_union_guarded,prepared_jev,prepared_jev_fetch,todo_v2_checked,todo_v2_prepared_jev}.yaml`.

## Two entry points

- `package:aib_agents/agents.dart` — what an **application** imports.
  `dart:io`-free and Flutter-free, so SYSco Mobile+ can ship the very agent
  the benchmark measured. Excludes `LlmClientFactory` (reads
  `Platform.environment` for API keys; an app brings its own `LlmClient`)
  and `LlmJudge` (evaluation machinery — judging happens in the harness,
  never in the product).
- `package:aib_agents/aib_agents.dart` — what the **harness** imports: the
  above plus those two. Same source, so the two cannot drift.

CI enforces the first one's `dart:io`-freeness
(`tool/check_app_safe_entrypoints.dart`).

## LlmClient providers

`AnthropicClient`, `OpenAiClient`, `AzureOpenAiClient`, `OllamaClient`
behind the `LlmClient` port; `LlmClientFactory.fromConfig` builds them from
CLI/YAML configs (see `suites/agents/*.yaml`). API keys are read from
`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `AZURE_OPENAI_API_KEY` by default.

`AzureOpenAiClient` is the provider the SYSco assistant ships against (EU
region). It is OpenAI's wire format with a different URL shape, an `api-key`
header and a pinned `api-version`; it keeps `modelId` alongside the
deployment name because a deployment called `sysco-prod` tells you nothing
about what it costs.

Optional capabilities are probed with `is`: `LlmStreamingClient` (text
deltas, usage still read from the final chunk so streamed and non-streamed
runs stay comparable) and `LlmWarmUp` (loads the model before the first
episode, so its cold start is not charged to the first task).

`LlmUsage` reports `cachedPromptTokens` and `reasoningTokens` as subsets of
the prompt and completion counts. The price table bills them at their own
tiers when it declares them — which matters here, because the intent
strategy re-sends its whole catalog every turn and that is exactly what
providers cache.
`package:aib_agents/testing.dart` ships `FakeLlmClient` for deterministic,
key-free runs of the complete agent stack.

## Running the M3 benchmark

Deterministic (CI, no keys): `apps/todo_app/test/benchmark/m3_llm_agents_test.dart`.

Live (produces a full run directory under `results/`). The model is
configured declaratively — the same file format the CLI uses:

```sh
cd apps/todo_app
# local & free (see the repo README for the Ollama setup):
AIB_LLM_CONFIG=../../suites/agents/ollama.yaml \
  flutter test test/benchmark/live/m3_live_benchmark_test.dart

# API model:
AIB_LLM_CONFIG=../../suites/agents/anthropic.yaml \
  flutter test test/benchmark/live/m3_live_benchmark_test.dart
```

Every field can be overridden from the environment, which is what a
cross-model run needs (§6.4 `cross_model_variance`):

| Variable | Meaning |
|---|---|
| `AIB_LLM_CONFIG` | agent LLM config file (YAML) |
| `AIB_LLM_PROVIDER` / `AIB_LLM_MODEL` / `AIB_LLM_BASE_URL` | override single config fields |
| `AIB_JUDGE_CONFIG` (+ `AIB_JUDGE_MODEL`, …) | judge for `artifactRubric` tasks (default: the agent model) |
| `AIB_AGENTS` | `semantics,intent,genui` (default: all three) |
| `AIB_TASKS` | comma-separated task ids — cheap smoke runs |
| `AIB_REPS` | repetitions per task (default 5 = the M3 criterion) |
| `AIB_OUT` | run directory; an existing one is **resumed** |

```sh
# smoke run: one task, one repetition, one agent
AIB_LLM_CONFIG=../../suites/agents/ollama.yaml \
  AIB_AGENTS=intent AIB_TASKS=todo.create.simple AIB_REPS=1 \
  AIB_OUT=../../results/smoke flutter test test/benchmark/live/

# second model, same everything else (cross_model_variance)
AIB_LLM_CONFIG=../../suites/agents/ollama.yaml AIB_LLM_MODEL=llama3.1:8b \
  AIB_OUT=../../results/m3-llama flutter test test/benchmark/live/
```

Tasks whose `artifactRubric` pins a judge model other than the configured
one are skipped with a note instead of being executed ungradeable (§5.1);
run those with the pinned judge. The run directory is a normal one, so
`aib evaluate`, `aib report` and `aib compare` work on it — re-evaluating
with a different judge never requires re-running the episodes (P6).

## The judge (artifactRubric)

`LlmJudge` implements the core's `ArtifactJudge` port: pinned model,
temperature 0, one forced tool call per consultation, k=3 majority in
`ArtifactRubricEvaluator`. The suite pins *which* model may judge
(`judgeModel:` in `suites/todo_v1.yaml`); a mismatching judge is refused
rather than silently used.

`suites/agents/ollama_judge.yaml` pins the local judge (`gpt-oss:20b`) —
deliberately a different family than the reference agents, because a judge
sharing the agent's weights tends to prefer its own output (every report
prints `judgeAgentOverlap` for exactly this threat). Judge answers are read
leniently (`true` / `"yes"` / `1`) but conservatively: anything not
recognisably affirmative counts as "no".

Calibration is not optional — `tool/genui_label_sheet.py <run>` writes the
surfaces into a labelling sheet plus a `labels.csv` skeleton, then
`aib calibrate --run <run> --labels labels.csv --judge suites/agents/ollama_judge.yaml`
reports agreement, Cohen's κ, F1 and judge stability (share of non-unanimous
k-votes) — **per rubric criterion** as well as per episode, because a rubric
judge decides criteria, not episodes ([ADR 0008](https://github.com/code-moses/flutter-aib/blob/main/docs/adr/0008-criterion-level-judge-calibration.md)).

## Local models (Ollama)

`suites/agents/ollama.yaml` pins more than the model name: `contextTokens`
(`num_ctx`) and `think`. Both matter for measurement validity rather than
just quality — see [ADR 0006](https://github.com/code-moses/flutter-aib/blob/main/docs/adr/0006-local-llm-reference-runs.md).
Ollama silently drops tool calls whose name it does not know, which reaches
the client as an empty turn; the tool loop treats that as an unusable turn
(nudge, then `abort`), never as `done`. `extra.llm[]` on the decision says what
such a turn was: `stopReason` and whether it carried reasoning
(`thinkingChars`). Two things to know when running qwen3 through Ollama:

- With `think` unset the model reasons first, and a reasoning-only turn (text
  in `thinking`, nothing else) is what the loop sees as empty. Set `think`
  explicitly, as the pinned arms do.
- Ollama has no `parallel_tool_calls` option. The client sends the field and
  Ollama ignores it; the loop is what keeps a turn to one call.
- `toolCalling: constrained` is the alternative to hoping the parser reads the
  turn: the schema is sent as `format` while `tools` still go to the template.
