# ADR 0017 — The catalog groups itself and states its scope once

Date: 2026-09-28 · Status: accepted, unmeasured

## Context

tool-improvement.md (2026-09-27, §6) named two gaps left after the summary
rewrite (A1) and per-parameter descriptions (A2): the listing is in
registration order, so nineteen intents read as one run rather than the five
or six workflows they actually form; and there is no delete or edit intent
for a record, which is nowhere stated, so a request such as "delete every
article" has one right answer (refuse, with a reason) that a model has to
infer instead of read. Both are catalog-presentation gaps, not schema gaps,
and both were estimated small on the framework side.

## Decision

**Grouping (A6).** `AibIntent.metadata` already carries a free-form,
app-owned `group` key if the app sets one — nothing new to publish. What was
missing was using it: `intents.catalog`'s listing now renders with every
intent sharing a `metadata['group']` value made contiguous, groups ordered by
where their first member was registered, and intents keeping their relative
order within a group. An intent with no `group` joins one shared "ungrouped"
group of its own. An app that sets no `group` at all — the todo app, every
existing test — gets back exactly its registration order: this is a stable
reordering of an already-published field, not a new one, so it changes
nothing for a caller that does not opt in.

**Scope (A7).** `IntentBridge` gains an optional `scope`: one sentence from
the app on what its intents can and cannot do, published once as a top-level
`scope` key on `intents.catalog`'s result, never per intent. `IntentStrategy`
needed no change — its catalog rendering already spreads the result's
payload alongside the summarised `intents` list, so a new top-level key rides
along for free, the same way the reordering above needed no change to how
the rendering iterates the list it is given.

## Consequences

- Free for an app that does not use either: no `scope` argument is a missing
  key, not a null one, and no `group` metadata is the one-group case of the
  new ordering — both are exactly today's behaviour.
- `metadata['group']` was always visible per intent in the full catalog
  entry; grouping only changes where an intent *sits* in the summary listing,
  not what is said about it.
- `scope` costs a sentence on every `intents.catalog` observation, the same
  as any other per-catalog cost (compare `catalog_bytes`) — worth watching if
  it grows past one sentence.
- Whether either changes a model's first wrong-tool rate is unmeasured — no
  app in this repository sets `group` or `scope` yet.
