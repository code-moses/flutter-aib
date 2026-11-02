#!/usr/bin/env python3
"""Builds the manual-labelling sheet for judge calibration (spec §5.2).

`aib calibrate --run <dir> --labels labels.csv` compares the LLM judge's
verdicts against human labels and reports Cohen's κ / F1 — but somebody has
to produce those labels first, and that means reading every generated
surface. This script turns a run directory into

  * `<run>/genui_labels.md`  — one section per episode: the task, the
    rendered surface, the rubric questions, and an empty verdict line
  * `<run>/labels.csv`       — the file `aib calibrate` expects, prefilled
    with `?` so an unlabelled episode cannot silently count as a failure

Usage:  python3 tool/genui_label_sheet.py results/m4-run [rubric.yaml]
"""

import csv
import json
import pathlib
import sys


def artifacts_of(trace_path):
    """Yields the genui.render payloads of one episode trace."""
    for line in trace_path.read_text().splitlines():
        if not line.strip():
            continue
        event = json.loads(line)
        if event.get("type") == "agent.envelope" and \
                event["data"].get("key") == "genui.render":
            yield event["data"].get("payload", {}).get("surface")


def rubric_questions(rubric_path):
    if rubric_path is None or not rubric_path.exists():
        return []
    questions = []
    current = None
    for raw in rubric_path.read_text().splitlines():
        line = raw.strip()
        if line.startswith("- id:"):
            current = line.split(":", 1)[1].strip()
            questions.append([current, ""])
        elif questions and line and not line.startswith("#"):
            if line.startswith("question:"):
                continue
            if line.startswith("weight:"):
                continue
            questions[-1][1] += " " + line
    return [(qid, text.strip()) for qid, text in questions]


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    run_dir = pathlib.Path(sys.argv[1])
    rubric = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else \
        pathlib.Path("suites/rubrics/dashboard_v1.yaml")
    verdicts = json.loads((run_dir / "verdicts.json").read_text())["verdicts"]

    questions = rubric_questions(rubric)
    sheet = ["# Manual labels for judge calibration",
             "",
             f"Run: `{run_dir.name}`  ·  rubric: `{rubric.name}`",
             "",
             "Judge the surface yourself **before** looking at the judge's "
             "verdict, then write `success` or `failure` into the label line "
             "and copy it into `labels.csv`.",
             ""]
    if questions:
        sheet += ["Rubric criteria:", ""]
        sheet += [f"- **{qid}** — {text}" for qid, text in questions] + [""]

    rows = []
    for trace in sorted((run_dir / "traces").glob("*.jsonl")):
        episode = trace.stem
        verdict = verdicts.get(episode, {})
        # Only episodes the judge actually voted on are worth labelling.
        # An agent may render a surface on a task scored by finalStateMatch
        # (wrong oracle), or send an invalid surface that never reached the
        # judge at all ("no artifact found in trace") — in both cases there
        # is no judge answer for a human label to be compared against.
        rubric = (verdict.get("details") or {}).get("artifactRubric")
        if not isinstance(rubric, dict) or not rubric.get("votes"):
            continue
        surfaces = [s for s in artifacts_of(trace) if s is not None]
        if not surfaces:
            continue
        sheet += [
            f"## {episode}",
            "",
            "```json",
            json.dumps(surfaces[-1], indent=2, ensure_ascii=False),
            "```",
            "",
            f"- judge said: `{verdict.get('type', '?')}` "
            f"(score {verdict.get('score', '?')})",
            "- **your episode label:** `success` / `failure` -> ______",
        ]
        # Per-criterion labels are the ones that make κ meaningful: the
        # judge answers one question per criterion, and on a suite where
        # nearly every surface earns partial credit the episode verdict is
        # constant, which leaves Cohen's κ undefined.
        sheet += [f"- [{qid}] yes / no -> ______" for qid, _ in questions]
        sheet += [""]
        rows.append((episode, "?"))
        rows += [(episode, qid, "?") for qid, _ in questions]

    (run_dir / "genui_labels.md").write_text("\n".join(sheet))
    with (run_dir / "labels.csv").open("w", newline="") as handle:
        handle.write("# episode_id,label            <- the episode verdict\n")
        handle.write("# episode_id,criterion,label  <- one rubric question\n")
        csv.writer(handle).writerows(rows)

    episodes = len([r for r in rows if len(r) == 2])
    print(f"{episodes} episode(s) with a rendered surface, "
          f"{len(rows) - episodes} criterion label(s) to fill in")
    print(f"  {run_dir / 'genui_labels.md'}  <- read and label")
    print(f"  {run_dir / 'labels.csv'}       <- fill in, then: "
          f"aib calibrate --run {run_dir} --labels {run_dir / 'labels.csv'} "
          f"--judge suites/agents/ollama_judge.yaml")
    return 0


if __name__ == "__main__":
    sys.exit(main())
