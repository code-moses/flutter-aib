# ADR 0016 — An intent can name what it needs, and `intents.describe` brings it along

Date: 2026-09-27 · Status: accepted, unmeasured

## Context

tool-improvement.md (2026-09-26) traced a recorded chain on SYSco: to count
articles of one kind, `qwen3:8b` described `data.count`, called it, was told
the filter id it guessed does not exist, described `endpoint.describe`, called
that, then described `data.search` to resolve the filter's value — three
`describe_intents` round trips for one task, each a turn spent on discovery
rather than the task. The information was always reachable — every dead end
already named the next intent (`_describeFirst` in `assistant_global_actions
.dart`) — but reaching it cost a turn each time.

## Decision

`AibIntent` (and, in an app, the app's own intent declaration) gains
`requires: List<String>` — names of intents this one's parameters typically
depend on. `intents.describe` computes, from what was asked for, every
`requires` name that is in scope and not already among them, describes those
too, and reports which ones under `autoIncluded`. `intents.catalog`'s summary
listing carries the same names under `needs`, so the dependency is visible
before an agent describes anything.

Only one level, not transitively — a request expands once, not into a chain
the agent did not ask for. Only in-scope names count; a `requires` name gated
behind a scope not yet open is silently skipped; describing it is what its
own capability announcement is for (ADR 0013).

## Consequences

- Free for an intent that declares no `requires`: an empty list changes
  nothing about `toCatalogJson`/`toSummaryJson`'s output.
- A described-but-unasked-for intent still costs its schema in every later
  request, same as one named directly — `requires` trades a round trip for
  tokens, and an app that names too much pays for it every turn.
- `IntentStrategy`'s ingestion needed no change: it already folds every entry
  of `intents.describe`'s `intents` list into callable tools, whichever
  intent asked for them.
- Whether the round trip actually disappears, and at what token cost, is
  unmeasured — no app in this repository declares `requires` yet.
