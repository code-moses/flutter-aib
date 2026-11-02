"""A Jev-compatible decision server on MediaPipe's Decision Maker task.

Speaks the System One shape (`POST /v1/systemone`) that aib_jev's `http`
backend already uses for simple-jev, so a decision block points here with

    decisions: {client: {backend: http, baseUrl: 'http://127.0.0.1:8092',
                         model: embeddinggemma-2-text-270m}}

A `noul` question is a `BooleanQuestion` (its instructions are the condition,
the state is the context); its noul is `probability_true`. A `choice` question
is a `ChoiceQuestion` over its options. The model is an EmbeddingGemma 2
`.litertlm` bundle (all three share the 270M text backbone, so text answers do
not depend on which). Started by tool/mediapipe_jev_server.sh.

One request at a time: the task is not thread-safe, and the latency a request
reports is the decision's own.
"""

import argparse
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

from mediapipe.tasks.python.core import base_options
from mediapipe.tasks.python.decision import decision_maker as dm


def _text(value):
    """A Jev text is a string or {language: string}; English when it is a map."""
    if isinstance(value, dict):
        return value.get("en") or next(iter(value.values()), "")
    return value or ""


def _state(body):
    if "state" in body and body["state"] is not None:
        state = body["state"]
        return state if isinstance(state, str) else json.dumps(state, ensure_ascii=False)
    return "\n".join(f"{m.get('role')}: {_text(m.get('content'))}" for m in body.get("messages") or [])


class Decider:
    def __init__(self, model_path, model_id, max_tokens):
        self.model_id = model_id
        options = dm.DecisionMakerOptions(base_options=base_options.BaseOptions(model_asset_path=model_path), max_num_tokens=max_tokens)
        self.maker = dm.DecisionMaker.create_from_options(options)

    def answer(self, context, question):
        kind = question.get("type", "noul")
        instructions = _text(question.get("instructions"))
        if kind == "noul":
            criteria = question.get("criteria") or {}
            condition = instructions if not criteria.get("true") else f"{instructions} {_text(criteria['true'])}"
            result = self.maker.evaluate_boolean(context, dm.BooleanQuestion(condition=condition, normalize_prior=True))
            return {"type": "noul", "noul": round(float(result.probability_true), 4), "confidence": round(float(result.confidence), 4)}
        if kind == "choice":
            options = question.get("options") or question.get("criteria") or {}
            if isinstance(options, list):
                options = {str(o): str(o) for o in options}
            result = self.maker.evaluate_choice(
                context, dm.ChoiceQuestion(criteria={k: _text(v) or k for k, v in options.items()}, instructions=instructions, normalize_prior=True)
            )
            return {"type": "choice", "choice": result.selected_key, "probabilities": {k: round(float(p), 4) for k, p in result.probabilities.items()}}
        raise ValueError(f"question type {kind!r} is not supported by this backend (noul, choice)")


def serve(decider, host, port):
    class Handler(BaseHTTPRequestHandler):
        def _send(self, status, payload):
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path in ("/health", "/v1/health"):
                self._send(200, {"status": "ok", "model": decider.model_id})
            elif self.path == "/v1/models":
                self._send(200, {"data": [{"id": decider.model_id}]})
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self):
            if self.path != "/v1/systemone":
                return self._send(404, {"error": "not found"})
            try:
                body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))))
                if body.get("model") not in (None, decider.model_id):
                    return self._send(422, {"error": f"this server serves {decider.model_id}, not {body.get('model')}"})
                context = _state(body)
                started = time.time()
                answers = {qid: decider.answer(context, q) for qid, q in (body.get("questions") or {}).items()}
                self._send(200, {"answers": answers, "model": decider.model_id, "metadata": {"latencyMs": round((time.time() - started) * 1000)}})
            except ValueError as e:
                self._send(422, {"error": str(e)})
            except Exception as e:  # a failed decision is a 500 the client classifies, not a dead server
                self._send(500, {"error": f"{type(e).__name__}: {e}"})

        def log_message(self, *_):
            pass

    print(f"serving {decider.model_id} on http://{host}:{port}/v1/systemone", flush=True)
    HTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, help="path to an EmbeddingGemma 2 .litertlm")
    parser.add_argument("--id", default="embeddinggemma-2-text-270m", help="the model id requests must name")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8092)
    parser.add_argument("--max-tokens", type=int, default=512)
    args = parser.parse_args()
    serve(Decider(args.model, args.id, args.max_tokens), args.host, args.port)
    sys.exit(0)
