# ADR 0011 — A turn with prose and no tool call is not a completion

Date: 2026-09-05 · Status: accepted

## Context

`results/sysco-offline-qwen3-4b-smoke` reported `premature_termination` on
three of its four episodes: the agent appeared to declare `meta.done` after
zero or one action. The summaries told a different story. One of them, in full,
begins:

> Okay, let's tackle this task step by step. The user wants to "Gib bitte die
> Anforderung für den Auftrag 'Wartung Heizung' frei." … Let me start by
> understanding the app's structure. The first tool is intent_app_describe …

That is not a report of a finished task. It is a model thinking out loud, mid
plan, on its way to calling a tool. All three carried `note=text_termination`;
the one episode that succeeded carried a real `done` tool call instead.

`ToolLoopAgent` turned any turn with text and no tool call into
`Envelope.done(summary: text)`. For a reasoning model that narrates in
`content` — qwen3 does, and keeps doing it with `think: false`, which stops the
separate `thinking` field but not the habit — that ends the episode on its
first thought.

The metric layer then attributed the decision to the agent.
`premature_termination` is defined as "the agent declared meta.done but the
task was not solved — it believed it was finished and was wrong". The agent
believed nothing of the sort; the harness decided, and then measured its own
decision as a property of the model.

The loop already had the right instinct one branch higher. A turn with neither
text nor a tool call is nudged rather than counted, and the comment there says
why: *"Counting it as `done` would report a premature termination the agent
never expressed."* A turn with prose in it is the same event with words in it.

## Decision

A turn with text and no tool call is nudged like an empty one: the model is
told that nothing happened, and that if it is finished it should call `done`
with its answer as the summary. It costs a retry from the same
`maxUnknownToolRetries` budget the other unusable turns draw on.

Only when the retry budget is exhausted — the model was asked to use a tool and
answered in prose anyway, every time — is the text taken as the answer, with
`note=text_termination attempts=N`. Discarding it then would be worse: at that
point the prose is all there is, and a model that is genuinely answering will
say the same thing again.

## Consequences

- `premature_termination` measures what it claims to. A model narrating its
  plan gets another turn instead of a verdict.
- Runs before this ADR overstate `premature_termination` for any model that
  narrates, and understate `action_count` and every efficiency metric derived
  from it, because those episodes stopped early for a reason that was never the
  model's. `sysco-offline-qwen3-4b-smoke` is such a run.
- A model that never calls tools still terminates, and still terminates as
  `done` with its text — but it now costs the retries first, so the trace shows
  it was asked.
- Streaming tests no longer route through this branch; they script text *and* a
  tool call, since streaming is a property of the transport and should not
  depend on how a text-only turn is read.
