## 1.1.0

- Held-out tasks can be kept out of a published suite: the suite keeps a stub
  (`withheld: true`), the full task lives in a git-ignored `<suite>.private.yaml`
  next to it. `SuiteLoader.loadFile` merges it back with unchanged hashes; without
  the file the task is left out with a warning.
- `SuiteLoader.loadReferences` reads reference trajectories together with their
  private sibling.
- `OracleSelfTest` runs four trivial agents per task (`null.done`, `null.abort`,
  `null.claim`, `null.refuse`). A refusal that passes an `abortIsAnAnswer` task is
  a warning, anywhere else an error.
- `BaselineComparison`: per-run Wilson and task-clustered intervals, pass^k and
  endings, paired differences against a baseline with Bonferroni intervals, and the
  tasks worth checking before their numbers are trusted.
- `Stats.pairedClusterBootstrap` takes `alpha`.
- Rubric verdicts record judge answers that could not be read as
  `judgeFormatFailures` instead of silent "no" votes (`JudgeAnswer.formatFailure`).
- `llamacpp` targets count as local in preflight checks.

## 1.0.0

- First published release.
