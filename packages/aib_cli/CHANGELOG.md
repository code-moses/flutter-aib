## 1.1.1

- A missing mandatory option (`aib validate` without `--suite`) is a usage error
  with exit code 64, instead of an unhandled exception.

## 1.1.0

- `aib compare --baseline` (`AibService.compareBaseline`): every run against the first, with per-run intervals,
  pass^k and endings, paired differences with Bonferroni intervals, and tasks to
  check. Held-out tasks (`splits/<suite>.yaml` next to the suite) stay out of the
  per-task views. `--set-aside <criterion>` adds the score without it.
- `aib evaluate` exits 1 when the judge returned unreadable answers; the verdicts
  are still written.
- `aib selftest` prints the claim and refusal probes.
- `aib doctor` checks `llamacpp` targets.

## 1.0.0

- First published release.
