# ADR 0001 — Monorepo via Dart pub workspace (melos optional)

Date: 2026-07-02 · Status: accepted

## Context

The specification (§3.2) calls for a Dart monorepo managed with melos: shared
versioning, atomic cross-package refactorings, clean dependency direction.
Since Dart 3.6, `pub` supports native **workspaces**, which provide joint
resolution and path-linking of all packages without extra tooling. melos 7.x
itself builds on pub workspaces.

## Decision

- The repo root is a pub **workspace** (`pubspec.yaml` with `workspace:`);
  every package declares `resolution: workspace`.
- A `melos.yaml` is provided for melos-based task running (`melos bs`,
  `melos run analyze`, …), but nothing in the repo *requires* melos —
  plain `dart pub get` + `dart test` / `flutter test` per package always works
  (this is also what CI does).

## Consequences

- Atomic refactorings across package boundaries work out of the box.
- The dependency direction rule (aib_core must not depend on Flutter, M0) is
  enforced by `tool/check_core_deps.sh` in CI, independent of melos.
