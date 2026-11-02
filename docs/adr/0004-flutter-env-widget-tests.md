# ADR 0004 — FlutterEnvironment runs in-process; M2 verified via widget tests

Date: 2026-07-02 · Status: accepted

## Context

Phase 2 needs `aib_flutter` (semantics snapshot, intent bridge, fixture reset,
final-state queries) and the M2 proof: a ScriptedAgent drives the real Todo
app through the framework, reproducibly.

## Decision

- `FlutterEnvironment` is a plain in-process implementation of the
  `BenchmarkEnvironment` port with a registry of envelope handlers. It is
  host-agnostic: it takes a `settle` callback (frame pumping) so it works
  identically under `flutter_test`, `integration_test`, or a live app.
- M2 verification runs as **widget tests** (`apps/todo_app/test/benchmark/`),
  executed inside `tester.runAsync` so the engine can use real async/timers.
  This keeps M2 runnable headless in CI (no emulator needed).
- Semantics access goes through `SemanticsBridge` (keys `semantics.tree`,
  `semantics.tap`, `semantics.setText`, `semantics.scroll` — adapter
  convention, versioned in the aib_flutter README, not a core contract).
  Nodes can be addressed by stable node id or by label; snapshot reproducibility
  is compared on the *structural* serialization (ids stripped), since semantics
  node ids are allocation-order dependent.

## Consequences

- Later phases can reuse the same environment object under
  `integration_test` on real devices (WebSocket transport, Phase 5+).
