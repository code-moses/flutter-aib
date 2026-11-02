# ADR 0002 — Core has no vocabulary: opaque Envelopes, `meta.*` reserved

Date: 2026-07-02 · Status: accepted

## Context

Spec §4.1: the core defines neither observation modalities nor action types.
Agent ↔ environment vocabulary is a convention between adapters, discovered at
runtime via `EnvironmentDescriptor`.

## Decision

- `Envelope { key, kind (observe|act), payload }` is the only content-bearing
  structure the core knows; payloads are opaque `Map<String, Object?>`.
- The **only** reserved namespace is `meta.*` (`meta.done`, `meta.abort`).
  The engine detects termination by *key prefix*, not by `kind`; `meta.*`
  envelopes are excluded from `action_count` regardless of declared kind.
- `EnvelopeKind` stays exactly `{observe, act}` as per spec — no third
  `meta` value is introduced.
- State-change verification ("declare, don't prescribe — but verify",
  §4.3) is realized through an *optional* capability interface
  `StateFingerprintProvider`. Environments that implement it enable the
  `kind_integrity_violations` and `redundant_action_ratio` metrics; the
  Environment port itself stays minimal (describe/reset/handle/captureFinalState).

## Consequences

- New modalities (vision, pointer, …) require zero core changes (goal M6).
- Metrics that depend on state diffs degrade gracefully (reported as absent)
  for environments without fingerprint support.

## Amendment 2026-09-17 — the core named keys it had promised not to

A review found the core naming an adapter's vocabulary in a dozen places:
`intents.invoke` in the harm metrics, the consistency trajectory and the
intent-health table, `intents.catalog` in `catalog_bytes` and the catalogue
shuffle, `user.*` in the app-action split and the clarification metrics, and
`genui.render` as the default `artifactKey`. Every one of them worked, and
every one of them made "the core defines no vocabulary" untrue for anyone
reading the code rather than the ADR.

- Those metrics, the `everIntent` / `neverIntent` / `confirmBefore` assertion
  kinds and the catalogue shuffle now live in `aib_agents` as the
  `intentConventions` **metric provider**. `aib_cli` enables it by default
  (`--no-conventions` switches it off); a harness that builds its own
  `MetricsRegistry` registers it explicitly, and without it those columns are
  absent rather than wrong.
- The core tells asking the user from operating the app by
  `EnvelopeSpec.blocksOnUser` — a fact the *environment* declares — and a
  provider may add its own test for traces recorded before that flag.
- `artifactRubric` criteria name their `artifactKey`; there is no default.
- `MetricProvider` gained `assertions`, `label` and `userInteraction` for
  exactly this, and `MetricDefinition.rateName` so a provider's 0/1 metric is
  reported as a rate like a built-in one.

Two conventions stay in the core because they are *its* vocabulary, not an
app's: the reserved `meta.*` keys, and the reserved result fields
`EnvelopeResult.suggestsKey`, `truncated` and `EnvelopeError.badParams`.
