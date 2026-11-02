# ADR 0008 — Judge calibration at criterion level

Date: 2026-08-19 · Status: accepted

## Context

§5.2 promises that the LLM judge is calibrated once against a small,
manually labelled sample and that Cohen's κ is reported. The first real
calibration sample (10 dashboard episodes, judge `gpt-oss:20b`, k=3) made two
problems visible that only appear with actual data:

1. **The episode verdict is nearly constant.** The rubric has four criteria;
   the generated surfaces reliably satisfy three of them and fail
   `no_completed_tasks`, so every episode ends as `partial (0.80)` — never
   `success`. Episode-level calibration compares the binary
   "verdict == success" against a binary human label, so both raters are
   constant, and κ is 0/0.
2. **The degenerate case was reported as κ = 1.** `Stats.cohensKappa`
   returned 1 when `pe == 1`. On this sample that would have printed a
   perfect judge — from a sample that cannot show agreement at all.

## Decision

- `Stats.cohensKappa` returns **NaN** when `pe == 1` (both raters used a
  single category). The calibration renders it as `—` and serializes `null`,
  next to raw agreement and n, which *do* carry information there.
- Calibration gains a second level: `CriterionCalibration` compares the
  judge's **per-criterion majority vote** against per-criterion human labels
  — the unit the judge actually decides. Same statistics (agreement, κ, F1,
  confusion matrix), n multiplied by the number of criteria, and
  disagreements attributable to the question that caused them.
- One labels file carries both levels; the row length decides:
  `episodeId,label` is an episode verdict, `episodeId,criterionId,label` a
  rubric answer (`yes`/`no` accepted next to `success`/`failure`).
  `tool/genui_label_sheet.py` writes both, prefilled with `?` so an
  unlabelled row fails loudly instead of counting as a "no".
- `aib calibrate` refuses to run **without** `--judge` on a run that has
  `artifactRubric` criteria: re-evaluating without a judge scores every
  rubric criterion 0, and κ against those verdicts would describe the
  missing judge rather than the judge under calibration.

## Consequences

- The κ reported in the thesis comes from the criterion level; the
  episode-level table stays in `calibration.md` and will often show `—` for
  κ with a note that the sample has no variance. Both are honest; only one
  is informative.
- Existing behaviour changed: a run whose verdicts and labels agree on a
  single category no longer reports κ = 1. That reversal is deliberate and
  is the reason this ADR exists — the earlier convention is easy to restore
  (one line in `Stats.cohensKappa`) if the thesis prefers it.
- The calibration sample should be built to *vary*: repetitions of one task
  at temperature 0 produce near-identical surfaces (10 of 10 identical
  verdicts in the first sample). A second agent model in the sample is the
  cheapest source of variance.

## Amendment 2026-09-17 — k, temperature, and what the refusal became

- `aib calibrate` no longer refuses without `--judge`: it reuses the run's
  `verdicts.json` and says whose judge produced them, which is the same
  protection without re-scoring (`--judge` still re-scores). It refuses only
  when there is nothing to reuse.
- The judge's `k` is `--judge-k` (default 3, as before) and the judge config
  may set a `temperature`; both are recorded in `JudgeProvenance`. At
  temperature 0 the k votes are near identical, so `aib evaluate` now warns
  that the majority costs k calls and buys nothing — the observation this ADR
  made, said where it is paid for.
- κ is reported with a percentile-bootstrap interval. On a twenty-episode
  sample a point estimate alone invites more confidence than it earns.
- A judge that answers without the tool is asked once more before its
  criteria count as failed (`judge_v3`): a format slip is not a verdict.

## Amendment 2026-09-22 — the sample moves to the sweep

The M4 sample was never labelled, and on inspection it could not carry a κ
for the judge the thesis reports:

- `m4-judge-calibration-llama31` holds no surface at all: llama3.1 sent
  `surface` as a JSON string, the app answered `bad_payload`, and all ten
  episodes timed out. Its `labels.csv` is empty.
- `m4-judge-calibration-qwen3` is 10 × 4 criteria with the constant verdicts
  this ADR describes.
- Both were scored by `judge_v1` on pre-A2UI surfaces (ADR 0012). Every
  number since 2026-09-18 comes from `gpt-oss:20b (judge_v3)`.

The calibration sample is now drawn from the nine judged arms of the
2026-09-18 sweep, which that judge scored: 187 episodes carry a vote,
qwen3:8b and claude-sonnet-5 both, faithfulness and task rubrics both.
No new run is needed.

- `aib labelsheet --run … --sample N --out dir` rebuilds the artifact and the
  evidence digest exactly as `ArtifactRubricEvaluator` handed them to the
  judge, and writes `labels.md` (without the judge's answers), `labels.csv`
  (`?` per criterion) and `sample.json`. The sample is seeded and stratified
  by task × "the judge said no somewhere", alternating between episodes that
  carry a task-specific rubric and episodes that carry only the suite-wide
  faithfulness rubric. Without the alternation, faithfulness filled 80 of 104
  rows and each task rubric's κ rested on a handful.
- `aib calibrate` takes `--run` more than once and pools. Labels then name
  `<run dir name>/<episode id>`. Runs scored by different judges are refused.
  Per-rubric rows are reported, plus the largest rubric set against the rest
  pooled: a claim checker and an answer checker are different instruments.
- Sample of record: `results/judge-calibration-2026-09-22`, 50 episodes,
  146 criteria (100 faithfulness, 46 task rubric), seed 42.

Still unmeasured: the sweep judged at k=1, so `splitRate` has nothing to
count. Re-judging the 50 sampled episodes at k=3 would add it.

## Addendum 2026-10-21: faithfulness_v2, judge_v4, labelling in the UI

The review of `faithfulness_v1`'s 26 disagreements (κ 0.34) found seven
label errors, four harness-written aborts judged as claims, and fifteen judge
errors. Two of the causes were in the evidence, not in the judge:

- The record held exchanges only. A follow-up after `meta.done`, a simulated
  turn and a delivered steering message are now record entries
  (`{"user": …, "when": …}`), in the order they were said, and never cut from
  the middle of a long episode. The evidence prompt (`judge_v4`) says the
  closing statement answers the last of them.
- An abort the agent's loop wrote because the model produced nothing usable
  carries `decision.extra.authoredBy: harness`
  (`AgentDecision.authoredByKey`). It is never an artifact, so a claim rubric
  with `skipWhenNoArtifact` reports it as not applicable. Traces from before
  the flag are recognised by the reference loop's note (`no_usable_response`,
  `llm_error`).

`faithfulness_v2` replaces the two overlapping v1 criteria with three closed
ones (`actions_happened`, `values_from_record`, `no_overstated_completion`,
weights 1/1/1) and a `scope:` line, a new optional rubric field shown to the
judge and to the person labelling: a true report of a wrong action is
faithful. `sysco_v1` and `todo_v2` reference v2; v1 stays as it was.
Acceptance: κ ≥ 0.61 on a fresh sample of the September runs re-judged with
v2. If it misses, the next step is a stronger judge model, not more wording.

Judge verdicts now keep each consultation's answers and reason
(`answers`, `rationales`), so a disagreement can be read afterwards. The label
sheet states the labelling convention, and `aib_ui` has a Label view that
replaces editing `labels.csv` by hand.

### 2026-10-28: first labels with the Label view

A sample of 50 episodes over the nine re-judged September runs
(`results/judge-calibration-2026-10-28`, labelled in `aib_ui`) gave, over 87
task-rubric criteria, raw agreement 0.954 and κ 0.885 [0.759, 0.973]
(precision 1.000, recall 0.938). The four disagreements are all judge "no"
against human "yes", three of them in `guardrail.refuse.permission`
(κ 0.640); without that rubric κ is 0.962. 30 of 660 criteria (0.045) were
decided by a split vote.

The sample held no `faithfulness_v2` row. The runs record their suite as the
copy inside the app's sandbox, a later run had replaced it with a version that
still named v1, and the label sheet read it and silently dropped the rubric
the judge had answered. `AibService.locateSuite` now prefers, among readable
candidates, the suite whose rubric hashes match the run's judge provenance,
and the sheet warns when the judge answered a rubric the suite lacks. The
faithfulness κ is still to be measured
(`results/judge-calibration-2026-10-28-faith`).
