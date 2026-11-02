#!/usr/bin/env bash
# CI guard (P1, hexagonal architecture): the Layer-1/2 packages must never
# depend on Flutter. Enforced by scanning their pubspec.yaml files.
set -euo pipefail

fail=0
for pkg in packages/aib_core packages/aib_protocol packages/aib_agents \
           packages/aib_cli packages/aib_otel packages/aib_jev packages/aib_jev_llama; do
  pubspec="$pkg/pubspec.yaml"
  if grep -E '^\s*(flutter|flutter_test|flutter_driver|integration_test)\s*:' "$pubspec" >/dev/null; then
    echo "FAIL: $pubspec declares a Flutter dependency (violates P1 / M0)."
    fail=1
  else
    echo "OK:   $pubspec is Flutter-free."
  fi
done

# Also guard against source-level imports.
if grep -rn "package:flutter" packages/aib_core/lib packages/aib_protocol/lib \
    packages/aib_agents/lib packages/aib_cli/lib packages/aib_otel/lib \
    packages/aib_jev/lib packages/aib_jev_llama/lib \
    2>/dev/null; then
  echo "FAIL: Flutter import found in a core package."
  fail=1
fi

# The app-safe entry points are guarded separately (dart:io, not Flutter).
if ! fvm dart tool/check_app_safe_entrypoints.dart; then
  fail=1
fi

exit $fail
