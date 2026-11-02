"""Golden fixtures for aib_jev's port of the simple-jev v1 template.

Runs the *reference* code — simple-jev's `common` package and its HF prompt
compiler, at the commit `tool/jev_server.sh` pins — over a fixed set of
requests and writes what it produced: the prompt plan, the per-branch chat
messages, the rendered prompt text under a real tokenizer's chat template,
and the scored answers for fixed logits. The Dart tests assert equality
against this file, so a drift in either implementation is a test failure,
not a quiet change of what the probabilities mean.

    ./tool/jev_server.sh           # once, installs the pinned simple-jev
    build/jev/.venv/bin/python tool/jev_golden.py

Needs the Qwen3.5-0.8B tokenizer in the HF cache (the weights are not used).
"""

import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SIMPLE_JEV = ROOT / "build/jev/simple-jev"
sys.path.insert(0, str(SIMPLE_JEV))
sys.path.insert(0, str(SIMPLE_JEV / "hf-server"))

from common import ClassifierRequest, build_response, prepare_prompt  # noqa: E402
from hf_server import PromptCompiler  # noqa: E402

OUT = ROOT / "packages/aib_jev/test/fixtures/golden_v1.json"
TOKENIZER = "Qwen/Qwen3.5-0.8B"

CASES = {
    # The payload of simple-jev's own common/tests/test_pipeline.py.
    "pipeline": {
        "model": "test",
        "state": {"color": "red"},
        "questions": {
            "color": {"type": "choice", "instructions": "Color?", "criteria": {"red": None, "blue": "Blue"}},
            "support": {
                "type": "score",
                "instructions": {"ask": "Support?"},
                "criteria": ["no", "maybe", "yes", "certain"],
            },
            "truth": {"type": "noul", "instructions": "Red?"},
        },
        "options": {"raw_logits": True},
    },
    "route_en": {
        "model": "test",
        "state": "Create a customer named Ada Lovelace with the email ada@example.com.",
        "questions": {
            "route": {
                "type": "choice",
                "instructions": "Which model should handle this app task?",
                "criteria": {"local": "A small local model is enough.", "cloud": "A frontier model is needed."},
            },
            "harm": {"type": "noul", "instructions": "The task asks to delete or overwrite existing data."},
        },
    },
    # German state, German criteria: umlauts, ß, typographic quotes and an
    # emoji go through canonical JSON unescaped (ensure_ascii=False).
    "route_de": {
        "model": "test",
        "state": "Lege einen Kunden „Jürgen Groß“ an und schick ihm die Rechnung für März 🚀",
        "questions": {
            "route": {
                "type": "choice",
                "instructions": "Welches Modell soll diese Aufgabe übernehmen?",
                "criteria": {
                    "local": "Ein kleines lokales Modell genügt: wenige Schritte, wenig Urteilsvermögen.",
                    "cloud": "Ein deutlich stärkeres Modell ist nötig: mehrere abhängige Schritte.",
                },
            },
            "done": {
                "type": "noul",
                "instructions": "Die Aufgabe ist vollständig erledigt.",
                "criteria": {"true": "Alles erledigt", "false": "Es fehlt noch etwas"},
            },
        },
    },
    "chat_system": {
        "model": "test",
        "messages": [
            {"role": "system", "content": "You are a support bot."},
            {"role": "user", "content": "Cancel my order #4411, please."},
            {"role": "assistant", "content": "Are you sure? It ships tomorrow."},
            {"role": "user", "content": "Ja, bitte stornieren."},
        ],
        "questions": {"agreed": {"type": "noul", "instructions": "The user confirmed the cancellation."}},
    },
    "chat_plain": {
        "model": "test",
        "messages": [{"role": "user", "content": "Red bicycle"}],
        "questions": {
            "color": {"type": "choice", "instructions": "Color?", "criteria": {"red": None, "blue": None, "green": "Grün, wie „Gras“"}}
        },
    },
    "score_levels": {
        "model": "test",
        "state": ["a", 1, 2.5, True, None, {"z": 1, "a": [2, 1]}],
        "questions": {
            "two": {"type": "score", "instructions": "Two levels?", "criteria": ["low", "high"]},
            "ten": {"type": "score", "instructions": "Ten levels?", "criteria": [f"level {i}" for i in range(10)]},
            "eleven": {"type": "score", "instructions": "Eleven levels?", "criteria": [f"level {i}" for i in range(11)]},
        },
    },
    "choice_wide": {
        "model": "test",
        "state": "",
        "questions": {
            "tool": {
                "type": "choice",
                "instructions": "Which tool?",
                "criteria": {f"tool_{i}": f"Tool number {i}" for i in range(30)},
            }
        },
    },
    "escapes": {
        "model": "test",
        "state": 'Line one\nline "two"\ttab \\ backslash \u0001 control',
        "questions": {"q": {"type": "noul", "instructions": {"b": [3, 1], "a": "x\ny"}}},
    },
}


def logit_sets(plan, rng):
    """Three fixed logit sets per plan: ascending, random, and a tie."""
    ascending = {q.branch_id: {label: float(i) for i, label in enumerate(q.output_labels)} for q in plan.questions}
    randomised = {
        q.branch_id: {label: round(rng.uniform(-8, 8), 4) for label in q.output_labels} for q in plan.questions
    }
    tie = {q.branch_id: {label: (2.0 if i < 2 else -1.0) for i, label in enumerate(q.output_labels)} for q in plan.questions}
    return {"ascending": ascending, "random": randomised, "tie": tie}


def main():
    from transformers import AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(TOKENIZER)
    compiler = PromptCompiler(tokenizer)
    rng = random.Random(20260923)
    cases = {}
    for name, body in CASES.items():
        plan = prepare_prompt(body)
        request = ClassifierRequest.model_validate(body)
        compiled = compiler.compile(request, render_only=True)
        branches = []
        for question, branch in zip(plan.questions, compiled.branches):
            rendered = (
                tokenizer.apply_chat_template(
                    branch.messages, tokenize=False, add_generation_prompt=True, enable_thinking=False
                )
                + question.answer_prefix
            )
            branches.append(
                {
                    "branch_id": question.branch_id,
                    "question_id": question.question_id,
                    "instruction": question.instruction,
                    "answer_prefix": question.answer_prefix,
                    "output_labels": list(question.output_labels),
                    "answer_labels": list(question.answer_labels),
                    "messages": branch.messages,
                    "rendered_qwen35": rendered,
                }
            )
        scored = {}
        for set_name, logits in logit_sets(plan, rng).items():
            scored[set_name] = {
                "logits": logits,
                "response": build_response(plan, logits, input_tokens=7, advanced=True),
            }
        cases[name] = {
            "request": body,
            "system_prompt_prefix": plan.system_prompt_prefix,
            "prefix_instruction": plan.prefix_instruction,
            "suffix_instruction": plan.suffix_instruction,
            "branches": branches,
            "scored": scored,
        }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        json.dumps(
            {"generator": "tool/jev_golden.py", "simple_jev_commit": "b02aa81c915a8193759b3cd33fef74721d6e005b", "tokenizer": TOKENIZER, "cases": cases},
            ensure_ascii=False,
            indent=1,
        )
        + "\n"
    )
    print(f"wrote {OUT.relative_to(ROOT)} ({len(cases)} cases)")


if __name__ == "__main__":
    main()
