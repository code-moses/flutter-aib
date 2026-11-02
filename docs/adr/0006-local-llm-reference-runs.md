# ADR 0006 — Local LLM reference runs (Ollama)

Date: 2026-08-19 · Status: accepted

## Context

Spec §12 names a local Ollama model as the mitigation for two risks: API
deprecation during the thesis, and the cost of development runs. §11 Phase 6
additionally needs a *second* model for `cross_model_variance`. The first
live runs against `qwen3:8b` on the todo_v1 suite exposed three problems that
were invisible with `FakeLlmClient`, all of which distort measurements rather
than merely degrading them:

1. **Silent context truncation.** Ollama defaults to a 4k context window and
   drops the oldest messages beyond it. Once a serialized semantics tree
   enters the conversation, that silently deletes the task instruction —
   the run still produces numbers, but they no longer describe the task.
2. **Silently dropped tool calls.** Ollama discards tool calls whose name is
   not in the request's tool list. `qwen3:8b` called `todo.create` (the name
   from the intent catalog it had just observed) instead of the exposed tool
   `intent_todo_create`, so the client received a turn with neither text nor
   tool calls. The agent loop read that as "model considers itself finished"
   and terminated with `meta.done` — a *fabricated* premature termination,
   scored as agent failure in `termination quality`.
3. **Thinking models.** `qwen3` reasons before answering by default, which
   multiplies completion tokens and latency per step. Left implicit, that
   quietly becomes part of every efficiency metric.

## Decision

- `OllamaClient` states its sampling window explicitly: `num_ctx`
  (`contextTokens`, default 32768), `num_predict` (from `LlmRequest.maxTokens`)
  and an optional `think` toggle. All three are configurable in the
  declarative agent config (`suites/agents/ollama.yaml`) and therefore part of
  the pinned run configuration rather than of the provider's defaults.
- `ToolLoopAgent` no longer treats an **empty** LLM turn (no text, no tool
  calls) as a termination. It nudges the model, and after the retry budget
  aborts with `model returned an empty response` — a visible, structured
  outcome instead of an invented `done`. This is provider-independent: any
  API that filters or fails to parse a tool call produces the same shape.
- The intent strategy makes the intent → tool-name mapping explicit: the
  catalog observation is rendered with the tool name each intent is exposed
  under, and `Prompts.intentV2` states the rule. `intentV1` stays frozen
  (§11 Phase 3); the agent's `promptVersion` moves to `intent_v2`, so every
  run stays attributable to the exact prompt it used.
- The live runner drops tasks whose `artifactRubric` pins a judge model other
  than the configured one, instead of executing episodes that no judge is
  allowed to grade (§5.1). They are executed in a separate run with the
  pinned judge — evaluation is a separate pass anyway (P6).

## Consequences

- Local runs are usable as development and cross-model runs; `qwen3:8b`
  solves the easy CRUD tasks of `todo_v1` through both the semantics and the
  intent strategy.
- Comparability: runs before and after this ADR are distinguishable by the
  agent version in the run manifest (`intent_v1` vs. `intent_v2`). Numbers
  from `intent_v1` runs must not be pooled with newer ones.
- The empty-turn fix changes what `abort` means for every provider: an
  unusable model turn is now an abort with a reason, not a `done`. Reports of
  older runs keep their old classification — re-evaluation cannot repair it,
  because the distinction is made at execution time.
- `think: false` is a documented run parameter, not a hidden default. A
  thinking-vs-not comparison is one config flip plus one run.
