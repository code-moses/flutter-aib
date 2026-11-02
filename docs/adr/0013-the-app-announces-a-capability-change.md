# ADR 0013 — the app announces a capability change; the agent does not poll for one

Date: 2026-09-07 · Status: accepted

## Context

`intents.catalog` was always meant to be *live*. `IntentCatalogProvider` is
consulted on every observation precisely so that the catalog tracks the app's
state: intents mounted by the page the user is on, permission-filtered, minus
anything whose host has unmounted. SYSco Mobile+ uses that as designed — the
form verbs (`form.describe`, `form.set`, `form.addRow`, `form.validate`,
`form.submit`) are announced only while a form is open, so an agent asked to
fill a form that was never opened is told there is nothing to fill rather than
being handed a null.

The mechanism worked. Nobody ever used it.

`sysco-sonnet5-a2ui-v1` ran 90 episodes of `claude-sonnet-5` against the full
suite. In every one of the ninety, `intents.catalog` was observed **exactly
once** — the bootstrap, before anything was open. The union of every intent
name the model saw across the whole run is 18, and no `form.*` verb but
`form.open` is among them. `form.set` was never offered and never called, in
any episode, by any repetition.

`IntentStrategy` rebuilds its tools from a catalog result, so a tool surface
that is never re-observed is frozen at turn zero. The `hybrid_v2` prompt did
ask the model to "re-observe it after anything that changes context", and the
model reasonably ignored it: it was holding what looked like a complete tool
list, it had just called `form.open` and received a draft id and a full field
schema, and nothing anywhere said the app had grown five capabilities in the
meantime.

The consequence is not a tuning loss. All six `form.*` tasks were attempted
through `semantics.setText` against the raw accessibility tree, so the suite's
form slice measured a fallback path rather than the app's form API — a third of
the suite, silently answering a different question than the one it asks.

The general shape is familiar from ADR 0012: *validate what fails silently*.
This is the same lesson one layer out. A capability that exists, is correctly
declared, and is never visible to the only reader that matters is
indistinguishable from a capability that was never built.

## Decision

**The environment reports a capability change on the first result after it
happens.** The agent is never required to suspect one.

`FlutterEnvironment` gains a general `EnvelopeResultDecorator` hook, applied to
every result after its handler has run and the frames have settled.
`IntentBridge` installs one: it remembers the intent names the agent has been
told about — by an `intents.catalog` observation, or by an earlier delta — and
when the in-scope set differs, the result carries

```json
"capabilities": { "added": [ <full catalog entries> ], "removed": [ "<name>" ] }
```

`IntentStrategy.onResult` folds that into its tool surface. Because the hybrid
agent hands every result to every strategy, a delta riding on a `semantics.tap`
that opened a form counts exactly as one on `form.open` does.

Four things this deliberately is and is not:

- **No turn is spent.** The tools are simply present in the next request. An
  agent that had to re-observe would pay a full turn, on the request shape that
  is already the binding constraint, to be told something the app knew.
- **`added` carries the whole catalog entry, `removed` only names.** The agent
  builds a tool definition from the former and cannot ask for a schema later;
  dropping a tool needs nothing but its name.
- **The model is told in words, but not twice.** `describeResult` renders the
  delta as the tool names it produced. The parameters travel as the tool
  definitions — repeating them in the message text is exactly the duplication
  the compact profile exists to remove.
- **Announced once.** The bridge marks the set published when it reports it, so
  a change is news on one envelope and not on the next twelve.

Decorators run *after* the result cap, so what a decorator adds cannot be
truncated away by a payload that was already too large. That puts the same
restraint on a decorator that the cap enforces: say what changed, not
everything that is now true.

`catalogSchemaVersion` moves to `2`. Under `1` an intent mounted by an open
form was unreachable for the whole episode, so no run against `1` compares with
one after it.

## Consequences

Both prompts drop "re-observe it after anything that changes context" and say
instead that a result reporting `newCapabilities` means those tools exist from
that point on. That changes `promptHash` for the intent and hybrid agents, and
combined with `catalogSchemaVersion` it re-baselines every run that has one —
`sysco-sonnet5-a2ui-v1` included.

The suite is unchanged, which is the point worth stating plainly: the six
`form.*` tasks were always asking the right question. This is the first build in
which the agent has the means to answer it.

What this does not do is make discovery free. The bootstrap catalog is still
7.6 KB re-sent every turn, and a delta adds to it rather than replacing it. The
lean-catalog work is a separate decision.
