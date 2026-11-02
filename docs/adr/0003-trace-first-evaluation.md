# ADR 0003 — Trace-first: execution and evaluation are separate passes

Date: 2026-07-02 · Status: accepted

## Context

Spec P6: a benchmark run first produces raw traces; verdicts, metrics and
aggregation are a separate, repeatable step over those traces, so new metrics
can be applied to old runs.

## Decision

- `BenchmarkEngine.runEpisode` produces an `EpisodeTrace` (JSONL: one event per
  line, first line is the episode meta record). The final state snapshot is
  itself a trace event (`final.state`), so evaluation needs nothing but the
  trace file and the task suite.
- `aib run` writes `run_manifest.json` + `traces/*.jsonl` and nothing else.
- `aib evaluate` reads traces, computes `verdicts.json` and `metrics.csv`.
- `aib report` renders reports from those artifacts.

## Verdict semantics per termination reason

- `meta.done`, budget exceeded, timeout -> success criteria are evaluated
  normally against the captured final state (an agent that reached the goal
  state but ran out of budget for its `meta.done` still gets state credit).
- `meta.abort` -> `failure(reason)` without state evaluation (the agent itself
  declared defeat), **unless the task sets `abortIsAnAnswer: true`** — see the
  amendment below.
- framework fault (transport/environment crash) -> `error(frameworkFault)`;
  never attributed to the agent (spec §5.2, `infrastructure_error_rate`).

## Amendment 2026-09-09 — a refusal is not a defeat

The abort rule assumed every task has something to accomplish, so an agent
that stops has failed. A guardrail task inverts that: `guardrail.refuse.
impossible` ("delete all articles") and `guardrail.refuse.permission` are
correct exactly when the agent declines, and the hybrid prompt instructs it to
"call abort and say plainly why". The rule therefore scored the prompt-obeying
episode zero before reading a single criterion, and the rubric that would have
judged the refusal — keyed on `meta.done` — reported `no artifact found in
trace` for every guardrail episode of every run to date.

`TaskSpec.abortIsAnAnswer` (default false, so the ADR's rule is unchanged
everywhere else) makes an abort score its criteria like any other
termination. It is declared per task rather than inferred from the criteria:
whether a refusal is the right answer is a property of the task, not something
an oracle should guess at. `artifactKey` now also accepts a list, so such a
task names both endings it accepts (`[meta.done, meta.abort]`).

Note that `abort_rate` is unaffected — it is derived from the trace, not from
the verdict, so an accepted refusal still counts as an abort in the metrics.
