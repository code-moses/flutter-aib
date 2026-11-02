# ADR 0010 — The engine stops an episode that stopped going anywhere

Date: 2026-09-05 · Status: accepted

## Context

The first `sysco_v1` run (`results/sysco-hybrid-union-v2`) ended two of four
episodes on `budgetTokens`, and in both cases the trace shows the same shape:
the agent sends an envelope, gets an answer, and sends the identical envelope
again. In `form.open.requirement` it asked one `user.ask` four times, each
refused with `no_scripted_answer`. In `guardrail.refuse.permission` it dumped
`semantics.tree` repeatedly, twice byte-for-byte identical.

Nothing in the engine noticed. The budgets are the only thing that ends a
non-terminating episode, and every one of them is the wrong instrument here:

- The **step budget** does not bite, because observing is deliberately free
  (ADR 0002 and the `IntentKind` split) — an agent can re-observe forever.
- The **token budget** does bite, eventually, but it reports a stall as if the
  agent had run out of room while working. `budget_exhaustion_rate` then mixes
  two different failures, and `overdue_termination` cannot tell them apart.
- Worse, the budget is spent *on the loop*: every repeated payload stays in the
  agent's context for the rest of the episode. The 15 exchanges of
  `guardrail.refuse.permission` include 15.6 KB of `semantics.tree` the agent
  had already been given verbatim.

An agent that sends an identical envelope and receives a byte-identical result
has learnt nothing and changed nothing. Repeating it cannot start to work.

## Decision

The engine keeps, per episode, a `(key, payload)` signature for each envelope
and the fingerprint of the last result that signature produced.

- **Repeat**: the same signature produces a result whose `(status, payload,
  error)` fingerprint equals the previous one for that signature. Timing is not
  part of the fingerprint. Repeats are counted per signature, not
  consecutively — interleaving two stuck calls is still stuck.
- **On a repeat**, the agent is handed a short `no_progress` failure instead of
  the result. It loses nothing: it already has that answer verbatim. What it
  gains is the one fact it did not have, that it is going in a circle.
- **After `Budget.maxIdenticalRepeats` repeats** of one signature the episode
  ends with `TerminationReason.noProgress`. Default 2; `null` switches the
  guard off entirely — including the substitution — for a task that
  deliberately polls for an external change.
- The **trace records what the environment actually said**, with
  `repeatIndex` and `suppressed` alongside. The trace is the record of the run,
  not of the agent's view of it, and evaluation reads the trace (ADR 0003).

Two metrics make it visible: `no_progress` (bool) and `suppressed_repeats`
(count). `overdue_termination` now asks whether the *harness* stopped the
episode — a budget or this guard — rather than only whether a budget did.

## Consequences

- A stall is reported as a stall. `budget_exhaustion_rate` goes back to meaning
  what it says.
- **Results must not carry per-call nonces.** Identity is the whole mechanism,
  and one changing character defeats it. This was not hypothetical: the
  `user.ask` refusals differed only by an `ask-0` … `ask-3` counter echoed back
  in `details.question.id`, which is why nothing could see that the same
  question had been asked four times. `UserQuestion.asked()` now returns the
  question without its id, and the id stays in the transcript where it belongs.
- The rule is part of the measured protocol, so it is declared per task like
  the other budgets and recorded in the run manifest with them. Runs made
  before this ADR are not comparable on `budget_exhaustion_rate` with runs
  made after it.
- Replaying the four archived episodes under the rule: the two clean ones are
  untouched, `form.open.requirement` ends at exchange 14 with `noProgress`
  instead of 15 with `budgetTokens`, and `guardrail.refuse.permission` keeps
  15.6 KB of context it was spending on answers it already had. The replay
  assumes the agent behaves identically, which it will not — the notice arrives
  at the first repeat, long before the episode ends.

## Amendment 2026-09-17 — identity includes the state, for acts

The guard compared the *result* only. An act's result is usually a bare
acknowledgement — `semantics.tap` and `semantics.scroll` answer
`{nodeId, action}` however far the list moved — so four scrolls down a long
list were "the same answer four times": the third was replaced by a
`no_progress` notice for an action that had happened, and the fourth ended
the episode with `noProgress` while the viewport had moved four times.

- For an envelope the agent declared `act`, the state fingerprint is part of
  the identity. Same result *and* same state is a repeat; a moved state is
  not.
- An environment that cannot fingerprint never has its acts suppressed. The
  guard then applies to observations only, where a result is the whole answer.
- `SemanticsBridge` reports the scroll position and whether the node is on
  screen on `semantics.scroll` and `semantics.showOnScreen`, so a scroll that
  moved differs from one that hit the end of the list even where the app's
  fingerprint covers stored data only.
- The "same answer, different question" notice counts **distinct signatures**,
  not occurrences; it used to describe two repeats of one call as two
  different parameter sets.

Runs before this amendment overstate `no_progress` and `suppressed_repeats`
for any episode that legitimately repeated an action.
