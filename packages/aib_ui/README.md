# aib_ui — the benchmark ledger

A local web UI for the AI Interaction Benchmark. Open any folder of runs,
filter them by what they were configured with, read one episode step by step
(model output, tool calls, app answers, state changes, verdict), compare runs
with task-paired statistics — and, when started inside a checkout, read and
derive agent configs and start runs. See
[ADR 0019](https://github.com/code-moses/flutter-aib/blob/main/docs/adr/0019-the-ui-is-a-local-web-app-over-files-and-the-workspace.md).

```sh
fvm dart run aib_ui                      # from the checkout: opens http://localhost:8787
fvm dart run aib_ui --library ~/Desktop/some-runs     # start on another folder
fvm dart run aib_ui --root /path/to/checkout --port 9000 --no-open
fvm dart run aib_ui --otlp-port 0        # do not also listen on 4318
```

No build step and no Node: the front end is plain ES modules in `web/`,
served by the same process. Preact, htm and the fonts are vendored in
`web/vendor` and `web/fonts`, so it works offline.

## What is in it

| Page | |
|---|---|
| **I · Runs** | Every run under the folder (four levels deep). Facets for suite, model, provider, study, arm, prompt, router, … with live counts; your own tags; an arbitrary recorded-config filter (only paths that differ between runs are offered); search; sort; group; a *Landscape* view plotting runs on any two of success, score, tokens, wall clock, cost. Tick runs to compare. |
| **Run** | Headline numbers with a Wilson interval, a task × repetition matrix (click a cell to open the episode), tokens against score, how episodes ended, where time went, per-task distributions of any metric, tag slices, episodes table with chosen metric columns (CSV export), the recorded configuration, judge and launch history, files (RUN.md, reports). Tags, alias, note and star are yours and live in `~/.aib_ui/state.json`. A banner says whether the run is scored and judged; *Score / judge…* shows the pinned judge, where it runs and what it can cost before it starts a job. The framework reports no per-episode progress while judging, so the job shows elapsed time instead of a bar. |
| **Episode** | The task as given, the agent's closing words, token and time scrubbers (click to jump), then every step: action, the model's thinking and output when `captureModelOutput` was on, the envelope sent, what the app answered, the decision's tokens and latency, no-progress and user turns in between. State differences against the reset baseline, the verdict criteria with judge votes, budget use, all metrics. Keys: `j` `k` `e` `[` `]` `esc`. |
| **II · Compare** | Configuration differences first, then the numbers with Δ against the first run (paired by task, 95% bootstrap interval), a forest plot, distributions, success against tokens, a task heat matrix sorted by disagreement, and the framework's own `aib compare`. |
| **III · Configs** | Pinned arms and experiments with their hypothesis headers. Check that one builds, diff two, see the runs that used it, derive a new arm by editing the YAML (live preview of the changed paths and whether it builds; one change per arm unless you tick otherwise). |
| **IV · Suites** | Tasks, tags, budgets, criteria kinds — no ground truth, no held-out tasks. |
| **V · Launch** | Estimate, then start a run through a configured runner; priced models need a spend cap and your approval. Optional OpenTelemetry export of the run (to this UI or any OTLP/HTTP endpoint). A runner is checked before it starts (its working directory and the scripts its recipe names — an app repository on the wrong branch is reported with the branch that has them); a priced run asks for a spend cap and will not start without one. Jobs with progress, spend and live log; stop a job; preflight (`aib doctor`). The form is kept across tabs and reloads. |
| **VI · Telemetry** | The UI is an OTLP/HTTP receiver: `aib run … --otel http://localhost:4318/v1/traces` (or the Launch page's switch) and the spans of every episode arrive live — protobuf, JSON or gzip. A list of episode traces, a waterfall per episode (`aib.episode` → `invoke_agent` → `execute_tool`, model time drawn solid inside each decision), span attributes and captured payloads. The episode page shows the same waterfall under the transcript; clicking a decision or tool jumps to its step. Received spans are kept in `~/.aib_ui/otel/`. |
| **VII · Label** | Hand labels for judge calibration (ADR 0008). A set is the folder `aib labelsheet` writes (`sample.json`, `labels.csv`), made here from judged runs or opened as it is. One episode at a time: the task, what the user said after it, what the agent said last, the rubric's scope and questions, the record the judge was given (uncut), the artifact, and the full trace with the model's thinking and tool calls. `y` / `n` answer the focused question, `j` / `k` move between questions, `[` / `]` between episodes. Answers are written into `labels.csv` as you go; notes go to `labels.notes.json`. The judge's votes, answers and reasons stay hidden until every question of the episode is answered (or you reveal them); then disagreements are marked and can be filtered. **Calibrate** runs `aib calibrate` over the set and shows κ per rubric. Add `&trace=1` to a set's URL to open every trace. |

OpenTelemetry export is opt-in per run and defaults to off on the Launch page:
exporting adds a little work to the harness, which timing metrics would see.
A runner that starts a subprocess receives the endpoint as `{otel}` /
`{otelCaptureContent}` in its recipe (`aib_mcp.yaml` passes them as
`AIB_OTEL` / `AIB_OTEL_CAPTURE_CONTENT`, which the todo_v2 live test reads).

Without an `aib_mcp.yaml` (or with `--root` elsewhere) the UI is browse-only:
pages II and I work, III–V say what they need.

## Safety

Loopback only; a foreign `Host` is refused; writes need `X-AIB-UI: 1` (OTLP
exports to `/v1/traces` are accepted with a protobuf or JSON content type,
which a cross-site page cannot send without a preflight this server never answers). Run
directories are never written to. Task text of a suite's holdout split is
hidden in run views (`--show-holdout` to show it).

## Developing

```sh
(cd packages/aib_ui && fvm dart test)    # reader formats, routes, path safety
```

`web/js/lib.js` has the data helpers and statistics, `charts.js` the SVG
charts (colours are the validated `--s1…--s8` slots in `css/app.css`),
`views/` one file per page.
