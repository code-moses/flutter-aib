# ADR 0019 — The UI is a local web app over run files and the MCP workspace

Date: 2026-10-08 · Status: accepted

## Context

Results were readable only through the CLI, the Markdown/HTML reports and,
for traces, `jq`. What a study needs is to open a folder of runs, filter
them by what they were configured with, read one episode like a transcript
(what the model said, what the app answered, what changed), and put several
runs side by side. The same person also configures arms and starts runs,
which already works over MCP: `AibWorkspace`, `RunLauncher` and `JobManager`
hold the rules (sandbox, one change per derived arm, budget, host queues,
pinned judge, holdout).

The front end has to be easy to install and host. The benchmark is a Dart
workspace with a pinned SDK; a second toolchain (Node, a Flutter web build)
would be one more thing to reproduce.

## Decision

`packages/aib_ui` (Layer 4, a fifth front end) is one Dart process that

- reads **any folder of runs as plain files** (`run_manifest.json`,
  `metrics.csv`, `verdicts.json`, `traces/*.jsonl`) without the framework,
  so a folder copied from another machine or an older checkout opens too,
  and never writes into a run;
- when an `aib_mcp.yaml` is found, exposes the **same workspace, launcher and
  job manager** as REST routes under `/api/fw/…` — it adds no rule of its
  own. Writes go through `AibWorkspace.deriveAgentConfig` and
  `RunLauncher.startRun`, so the sandbox, the budget and the holdout apply
  to a person at the keyboard exactly as to an agent;
- serves a **static front end with no build step**: Preact and htm vendored
  as ES modules, hand-written SVG charts, fonts vendored. It needs the Dart
  SDK that the repository already pins and nothing else.

- **receives the OpenTelemetry export** (`aib_otel`): `POST /v1/traces` is an
  OTLP/HTTP receiver (protobuf decoded by hand, JSON, gzip) on the UI port and,
  when free, on 4318. Spans are matched to episodes by `aib.run_id` and
  `aib.episode_id` and kept in `~/.aib_ui/otel/`. Export stays opt-in per run
  (`RunLauncher.startRun(otel:)`, `{otel}` in a runner recipe), because it
  adds work the timing metrics would see.

What a person adds on top of a run (tags, alias, note, star) is kept in
`~/.aib_ui/state.json`, not in the run directory.

Safety on a developer machine: the server binds to the loopback interface,
refuses a Host header that is not loopback (DNS rebinding) and requires
`X-AIB-UI: 1` on every write, which a cross-site form cannot send. The
holdout split's task text is hidden in run views unless `--show-holdout` is
passed. A multi-change arm is possible from the UI only after an explicit
tick, and the derived file records its hypothesis and changes like any other.

## Consequences

- The UI is a view over the formats, so it breaks if a trace event is renamed.
  `test/ui_test.dart` pins the formats it reads; unknown trace events show as
  such instead of failing.
- Statistics shown for a comparison (paired task deltas with bootstrap
  intervals, Wilson intervals) are computed in the browser from episode
  values; the framework's own `aib compare` is available beside them and
  stays the figure to cite.
- Another front end (a Flutter desktop shell, say) can reuse `/api/…`
  unchanged.
