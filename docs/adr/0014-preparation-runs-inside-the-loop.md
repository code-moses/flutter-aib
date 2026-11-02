# ADR 0014 — preparation runs inside the loop

Date: 2026-09-17 · Status: accepted

## Context

`docs/overview.md` (Preparation) designs a second agent
architecture: a preparation pass that reads the task, fetches what the agent is
likely to need, and hands it one digested briefing. Three of the first four
turns of every hybrid episode are discovery, and all of them are re-sent on
every later turn, so removing them is not a tuning gain but a different budget.

A preparer has to reach the app to prepare anything. The agent, by contract,
never holds the environment: `BenchmarkAgent.next()` returns one envelope and
the engine does the calling.

## Decision

Preparation is a **deterministic plan of envelopes emitted before the first LLM
call**, through the same `next()` contract as everything else.
`ToolLoopAgent.bootstrapPlan()` is the seam, `enqueuePlan()` extends the plan
from an earlier plan result, and every prefetch is marked `prefetch` on its
`AgentDecision`.

The preparer gets no second channel to the app.

## Consequences

- The engine's accounting tells the truth for free: each prefetch is one turn
  and one `handleMs`, observations are not `stepsUsed`, and a plan that makes no
  LLM call costs zero prompt tokens until its digest enters the conversation.
  That is the whole mechanism — turns are cheap in the currency that binds,
  round trips are not.
- Everything preparation did is in the trace, so `prefetch_precision` and its
  family are trace derivations like every other metric (ADR 0003). An agent
  states what it fetched; the framework decides what that was worth.
- The repeat guard and the turn budget both ignore prefetch envelopes: the
  model never saw the full payload the preparer did, and an agent's attempts
  should not be spent on the runner's own bookkeeping.
- Preparation is additive only. `describe_intents` stays offered and the
  briefing lists every in-scope intent name, so a retrieval miss costs tokens
  and never reachability.
- A side channel would have been invisible to the trace, outside the budget,
  and would have broken the property the SYSco integration rests on: the
  shipped assistant and the benchmarked agent go through the same door.
