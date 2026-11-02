# ADR 0005 — Todo app uses an in-memory store seeded from JSON fixtures

Date: 2026-07-02 · Status: accepted

## Context

Spec §8.1 mentions SQLite (drift) with seed fixture; §5.3 explicitly allows
"In-Memory/SQLite-Seed" for the Todo app. drift adds codegen and a native
sqlite dependency without adding benchmark value for Phase 2.

## Decision

- `TodoStore` is an in-memory `ChangeNotifier` seeded from a JSON fixture
  (`suites/fixtures/todo_seed_baseline.json`). `env.reset()` = replace the
  full store contents with the fixture + reset UI state (navigation, search,
  filter) -> byte-identical state, trivially deterministic (M2: 10× reset ->
  identical fingerprints).
- The fingerprint is a SHA-256 over the canonically serialized store content.
- UI and intents both call the same `TodoUseCases` layer (intent parity per
  spec §8.1).

## Consequences

- Swapping in drift later only touches `TodoStore` internals; the fixture
  format, use cases, queries and fingerprint contract stay unchanged.
