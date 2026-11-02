# AIB overview

This file is the summary of where the framework stands, what it measured and which decisions sit outside the ADRs.
It replaces the plans, findings and research notes that used to live in `docs/`.

| Read                                   | For                                                                                                                                             |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| [`specification.md`](specification.md) | the original specification (German), frozen. Code comments cite it as "spec §x". Where the build departed from it, this file or an ADR says so. |
| [`adr/`](adr/)                         | the architecture decisions, one per file, 0001 to 0019                                                                                          |
| [`architecture.md`](architecture.md)   | diagrams of layers, ports, the episode, the run pipeline, deployment                                                                            |
| this file                              | status, results, decisions beyond the ADRs, open threads                                                                                        |
| `packages/*/README.md`                 | how to use each package, and its envelope conventions                                                                                           |

## Results

Every number here comes from a run under `results/` (not in git). n is the
number of repetitions per task. At n=1 a score ranks conditions and tests
nothing.

### The ten arm sweep (2026-09-18, sysco_v1, n=1)

The first suite measured after the code review. Judge `gpt-oss:20b` at k=1.

| Arm                                       | weighted | success |  tokens | $ per episode |
| ----------------------------------------- | -------: | ------: | ------: | ------------: |
| semantics only, qwen3:8b                  |     0.14 |    0.07 |  59 760 |               |
| intents only, qwen3:8b                    |     0.61 |    0.48 |  43 428 |               |
| intents with preparation, qwen3:8b        |     0.56 |    0.44 |  44 109 |               |
| union hybrid, qwen3:8b                    |     0.52 |    0.41 |  52 952 |               |
| hybrid with lexical preparation, qwen3:8b |     0.60 |    0.44 |  40 568 |               |
| hybrid with RRF preparation, qwen3:8b     |     0.30 |    0.22 |  39 588 |               |
| union hybrid, claude-sonnet-5             |     0.90 |    0.81 |  60 986 |         0.063 |
| hybrid with lexical preparation, sonnet   |     0.90 |    0.85 |  57 421 |         0.068 |
| hybrid with RRF preparation, sonnet       |     0.92 |    0.81 |  53 207 |         0.069 |
| ARTEMIS, sonnet, six task slice           |     0.00 |    0.00 | 130 371 |         0.288 |

Findings from the sweep:

1. A blind agent is a different order of capability. Semantics only solved
   2 of 25 tasks where the same model solved 11 through intents,
   Δ −0.35 [−0.53, −0.18] against the hybrid.
2. Preparation saves tokens and does not change accuracy. On qwen3:8b it
   removes 11 547 tokens per episode [1 550, 20 382] at +0.10 [−0.10, 0.29]
   in score.
3. Retrieval quality and task success come apart. The RRF preparer finds the
   gold tools far better (`tool_recall_at_k` 0.37 against 0.04) and scores
   worse on the small model (0.30 against 0.60). `tool_recall_at_k` is not a
   proxy for success.
4. The small model fails by stopping. `premature_termination` is 0.37 on
   every qwen3 arm and 0.04 to 0.11 on Sonnet.

`tool_gold_out_of_scope` is 0.42 on every prepared arm: two of five gold
tools sit behind a scope the preparer cannot see. todo_v2 exists to study
that.

### The judge (ADR 0008)

146 criteria from 50 episodes of the sweep, labelled by hand.

| Slice             |    n | agreement |           κ [95% CI] |    F1 |
| ----------------- | ---: | --------: | -------------------: | ----: |
| all criteria      |  146 |     0.795 | 0.506 [0.340, 0.647] | 0.854 |
| task rubrics      |   46 |     0.913 | 0.809 [0.604, 0.956] | 0.933 |
| `faithfulness_v1` |  100 |     0.740 | 0.343 [0.144, 0.542] | 0.822 |

The task rubrics are a validated oracle. The faithfulness rubric is not yet:
it holds 26 of the 30 disagreements. Faithfulness is a fifth of every
weighted score on sysco_v1, so report the score with and without it until
the rubric is fixed. A fixed rubric is a new version and a re-judge, never
an edit.

### Foreign agents (M6)

| Agent            | Modality                            | Attached over       | Commits | Touches `aib_core` |
| ---------------- | ----------------------------------- | ------------------- | ------: | ------------------ |
| ARTEMIS (Google) | Python, screenshot and element list | TCP, JSON-RPC 2.0   |      14 | no                 |
| `vision_python`  | Python, screenshot and pointer      | stdio, JSON-RPC 2.0 |       3 | no                 |

A real app changed the core four times. Two foreign agents changed it zero
times. The vision agent, re-run after three harness defects, scored 0.13
(qwen2.5vl:7b) and 0.15 (qwen3-vl:8b) on the 11 deterministic todo_v1
tasks. Neither solved a task by acting: both name the right control and tap
beside it. ARTEMIS passed one of two episodes on `nav.open.list` with
Sonnet. Transfer across models: qwen3:8b to Sonnet with the same agent,
+0.39 [0.19, 0.58].

### todo_v2

A workspace variant of the todo app: 8 intents always in scope, 13 only
while the page that mounts them is on top. 15 tasks, a headless oracle
self-test, a judged self-test that passes all 15. First arms on qwen3:8b at
n=1: hybrid 0.78, prepared lexical 0.74, 9 of 15 solved each. Both solve
every task one scope deep, so the capability announcement (ADR 0013) works
for a small model too.

### Model routing (todo_v2)

Arms differ in `modelRouter.decider` only. "Local" is qwen3:1.7b, "cloud" is
qwen3:8b, both on Ollama, so this measures the router, not a vendor.

| Arm (n=3)                     | score | local share | routing accuracy | decider latency |
| ----------------------------- | ----: | ----------: | ---------------: | --------------: |
| always local                  | 0.116 |       100 % |                  |                 |
| always cloud                  | 0.687 |         0 % |                  |                 |
| oracle                        | 0.717 |      26.7 % |            100 % |                 |
| rules                         | 0.285 |      66.7 % |           38.5 % |            0 ms |
| jev2 (simple-jev, Qwen3.5-4B) | 0.270 |      86.7 % |           30.8 % |        1 849 ms |
| jev3 (Ollama, qwen3:4b)       | 0.161 |       100 % |           15.4 % |           27 ms |

1. Both deciders lose to always cloud, and they lose the same way: they keep
   work local that the local model cannot do. The n=1 run showed the same.
2. Routes are stable across repetitions. The variance is in the episodes.
3. jev3 is fast and uninformative. It answers p(local) between 0.978 and
   0.999 on every task, which looks like a first label bias of a small
   generative model under a classifier template. Its recorded threshold of
   0.5 never routes anything to the cloud.
4. A threshold replay predicts re-runs. Arms derived from `routed_v2_jev3`
   at thresholds 0.9925 and 0.995, re-run over MCP on five tuning tasks,
   took exactly the routes the replay of the old run predicted (study
   `experiments/mcp-live-route-threshold`).

The oracle built from the sweep's best local and best frontier arm on
sysco_v1 scores 0.965 and keeps 11 of 25 tasks local, about 35 % less cloud
spend. That ceiling is why routing is worth measuring, with a competent
local model against a frontier one.

### Earlier results that still stand

| Result                             | Number                                                                                     |
| ---------------------------------- | ------------------------------------------------------------------------------------------ |
| degraded semantics on the todo app | `semantics_degradation_delta` −0.40 [−0.56, −0.23]                                         |
| transient faults, matched pair     | 0.57 to 0.54, Δ −0.03 [−0.15, 0.07]                                                        |
| catalogue order shuffled           | 0.53 to 0.52, Δ −0.01 [−0.15, 0.13]; turns to first act 3.9 to 3.4                         |
| app fixes on qwen3:8b              | score flat (0.43 to 0.44), `noProgress` endings 8 to 0, premature termination 0.39 to 0.60 |

The last row is why a single score is not enough: the app fixes removed
every loop and the model finished wrong instead.

## Decisions beyond the ADRs

### Preparation (ADR 0014)

A preparation pass reads the task, fetches what the agent will likely need,
and hands the model one briefing before its first call. It exists because
three of the first four turns of every hybrid episode are discovery, and
each turn re-sends everything before it, so an episode costs roughly the
square of its length. Every failing task in an early run hit the token
budget at 11 to 15 turns.

1. Preparation runs inside the loop as prefetch envelopes. A side channel
   would be invisible to the trace, outside the budget, and not the path the
   shipped assistant takes.
2. It only adds. `describe_intents` is always offered and the briefing names
   every in scope intent, so a retrieval miss costs tokens, never
   reachability.
3. Every prepared observation is digested under a byte ceiling, and the
   briefing says what it dropped.
4. Row data is not pre read by default. What an app holds may be what the
   task is about to change.
5. What would falsify it: `prefetch_precision` below about 0.4, success down
   while tokens are down, or rules and lexical matching dense retrieval
   (then the gain is turn removal, not retrieval).

`entities`, `data` and `model` strategies are refused by the config loader
by name. A config that names one experiment and runs another produces a
number nobody can attribute.

### Tool retrieval

The ranker is the standard recipe: BM25 with k1 1.2 and b 0.75, cosine over
a pinned embedding model, reciprocal rank fusion with k 60 (Cormack, Clarke
and Buettcher 2009). Thresholds apply to min max normalised scores, so
`minScore` means the same share of the spread under BM25 and cosine. The app
publishes aliases in every synced language inside the catalogue payload, and
the rendering drops them again, so retrieval can match German task words and
no agent pays for them. Retrieval is scored with Recall@k, nDCG@k and
Completeness@k against each task's `requiredTools`, the measures the tool
retrieval literature uses, and with `prefetch_precision` and
`prefetch_recall` against the trajectory. Still missing: a reranker, query
rewriting beyond the optional stemming analyzer, tool graph structure.

### Model routing and Jev

Jev is TypeSafe's decision model. It reads a state and answers typed
questions (`choice`, `score`, `noul`) with a distribution read from next
token logits. The vendor claims 70 to 500 ms per call. Nobody has reproduced
that independently, so the thesis treats "it improves routing" as the
hypothesis, not a premise. The integration ideas, as the code refers to them:

1. a model router with deciders `local`, `cloud`, `rules`, `self` and `jev`,
   one decision per episode on the instruction alone
2. a `JevClient` port that speaks to local and hosted backends alike
3. a completion check, a noul "the goal holds" before the agent may say done
4. tool preselection as a preparation strategy
5. an action guard and relevance filtering of large results

All five are built. The router is measured (above). The loop arms
(`hybrid_union_checked`, `hybrid_union_guarded`, `prepared_jev`,
`prepared_jev_fetch`, `todo_v2_checked`, `todo_v2_prepared_jev`) are defined
and not yet run. A smoke run showed the completion check accepted all 13
`done`s, so check it against the verdicts before an n=3 arm.

### The Jev package (`aib_jev`, `aib_jev_llama`)

1. Everything but the forward pass is Dart. The boundary is one function:
   the logits of the label tokens after a prompt. Backends are Ollama
   logprobs, `/v1/completions`, simple-jev over HTTP, and llama.cpp in
   process (`aib_jev_llama`, model downloaded and pinned by SHA-256).
2. The client is ours, not a pub package. The three Jev packages on pub were
   days old, from unverified publishers, and clients for the hosted API
   only. A client inside the measurement also has to share the framework's
   retry and cancellation, or `wall_clock_ms` compares clients.
3. The v1 noul question is broken in the reference itself: models write
   `0.x` where the template reads a digit. `template: v1-noul-decimal`
   prefills `0.` and fixes it. A noul number from before that fix is not
   evidence.
4. Budget: a warm decision under 150 ms on a desktop. Measured 53 to 82 ms
   through Ollama and 49 ms in process, against 6 s under Python.
5. Option ids stay ASCII so labels stay single tokens in a multilingual
   vocabulary. The question can be asked in German or English per config.

### Observability

A `TraceObserver` in `aib_core` receives every trace event as it is
recorded, and `aib_otel` exports episodes as OpenTelemetry spans under the
GenAI conventions: one trace per episode, `invoke_agent` wrapping
`execute_tool`, payloads only with `--otel-capture-content`. `aib_ui` receives the export on `/v1/traces` and shows it beside the episode ([ADR 0019](adr/0019-the-ui-is-a-local-web-app-over-files-and-the-workspace.md)). The JSONL trace
stays the canonical artifact. Mapped against the AgentOps taxonomy
(Dong et al. 2024), everything visible on the wire is covered. Reasoning,
plans and workflows are covered only as far as an agent reports them,
because the benchmark measures agents it did not write. Evaluation is
complete but offline.

### The MCP server (`aib_mcp`)

The CLI is exposed over MCP so an agent can configure arms, run benchmarks
and tune thresholds. Under both front ends sits `AibService`
(`packages/aib_cli/lib/src/service/`), so the CLI prints what MCP returns.

1. An agent that tunes a benchmark it also reports on is overfitting it.
   Every suite with a file in `suites/splits/` has a holdout. Tools see the
   tuning split only. `aib_holdout_score` needs a person's yes every time,
   through MCP elicitation, and returns the suite level score only.
2. Every derived arm, run, comparison, replay and holdout score is journaled
   to `experiments/<study>/journal.jsonl`, and a comparison reports how many
   arms its study tried.
3. A derived arm changes one config path (`maxChangedPaths` in
   `aib_mcp.yaml`, not a tool input). Suite descriptions carry no ground
   truth.
4. Runs are jobs. Runs against the same model host queue behind each other
   so latency metrics compare. Priced models need `maxUsd`, an estimate
   under it, and a person's yes above `autoApproveUsd`. A judge is pinned
   per suite.
5. Runner recipes live in `aib_mcp.yaml`. Machine local ones, like the SYSco
   app, live in the git ignored `aib_mcp.local.yaml`.
6. Streamable HTTP is served with a bearer token from the environment, for a
   benchmark machine others reach. dart_mcp has no such transport, so it is
   written in `aib_mcp`.

### SYSco integration rules

1. The shipped agent is the benchmarked agent. `AgentProfile.build` is the
   one builder the harness and the app share.
2. Everything the agent learns arrives as an envelope. The first direct call
   from the agent into an app service is the moment it stops being the
   measured agent.
3. An app imports only the app safe entry points (`aib_core/ports.dart`,
   `aib_agents/agents.dart`, `aib_flutter`), which CI checks for `dart:io`.
4. The app's benchmark inputs are copied in before a run and removed after
   it (`integration_test/aib/prepare_benchmark_inputs.dart` and
   `discard_benchmark_inputs.dart` in the app repository), so a release
   build never ships a task suite.

### What the instrument does not measure, on purpose

Reasoning quality (it would depend on a model's willingness to narrate),
cross episode memory (the engine resets every episode), message brokers
(ADR 0009), learned routers (a second thing under study), speech (the app
transcribes, the benchmark measures tool use), human usability studies. Two
validity threats to state in the thesis: tokens and LLM latency are self
reported (cross checked by `token_report_discrepancy`), and
`path_efficiency` rests on a hand written `optimalSteps`.
