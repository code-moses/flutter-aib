#!/usr/bin/env python3
"""AIB VisionAgent — an *external* benchmark agent in Python (spec §7, M6).

It speaks the AIB wire protocol v1 over stdio (newline-delimited JSON, see
`packages/aib_protocol`) and perceives the app exclusively through
screenshots: `screen.capture` to observe, `pointer.tap` / `pointer.text` to
act. Nothing in `aib_core` knows it exists — that is the point of the
exercise: a new agent, in another language, with another modality, attaches
without a single change to the framework core.

The model runs locally in Ollama; only the standard library is used, so the
agent runs with a plain `python3 vision_agent.py`.

Environment:
  AIB_VISION_MODEL   Ollama model (default: qwen2.5vl:7b)
  AIB_OLLAMA_URL     Ollama base URL (default: http://localhost:11434)
  AIB_VISION_DEBUG   set to 1 to log every decision to stderr
"""

import json
import os
import sys
import time
import urllib.request

PROTOCOL_VERSION = "2.0"  # AIB protocol; framing is JSON-RPC 2.0
MODEL = os.environ.get("AIB_VISION_MODEL", "qwen2.5vl:7b")
OLLAMA = os.environ.get("AIB_OLLAMA_URL", "http://localhost:11434")
DEBUG = os.environ.get("AIB_VISION_DEBUG") == "1"
# Reasoning models (qwen3-vl) think before answering unless told not to; with
# no cap on the answer either, qwen3-vl ran ~6 000 tokens into the context
# limit and the JSON was cut off. AIB_VISION_THINK=false sends think: false
# (the Dart agents' `think: false` for qwen3); it is left unsent by default
# because a model without thinking support may reject the field.
THINK = os.environ.get("AIB_VISION_THINK")
MAX_ANSWER_TOKENS = int(os.environ.get("AIB_VISION_MAX_TOKENS", "1024"))

SYSTEM_PROMPT = """\
You operate a mobile app by looking at screenshots. You cannot read the
app's code or accessibility tree — only what is visible in the image.

Every turn you see the current screen and answer with exactly one action:
  tap    — press a control at (x, y), in the coordinate space stated with
           the screenshot (origin top-left, logical pixels)
  type   — type text into the field that is currently focused (tap it first)
  done   — the task's goal state is visible on screen
  abort  — the task cannot be done with tap/type alone

Always give x and y (for type, done and abort they are ignored — use 0).
Be precise with coordinates: aim at the centre of the control you mean.
Work strictly towards the task; change nothing else."""

# Ollama structured output: the model must answer with exactly this shape.
ACTION_SCHEMA = {
    "type": "object",
    "properties": {
        "reasoning": {"type": "string"},
        "action": {"type": "string", "enum": ["tap", "type", "done", "abort"]},
        "x": {"type": "number"},
        "y": {"type": "number"},
        "text": {"type": "string"},
        "summary": {"type": "string"},
    },
    # x and y are required for every action: with them optional, qwen2.5vl
    # answered "tap" without coordinates on most turns. done/abort/type send
    # them too and they are ignored.
    "required": ["reasoning", "action", "x", "y"],
}


def log(message):
    if DEBUG:
        print(message, file=sys.stderr, flush=True)


class VisionAgent:
    """Episode state machine: bootstrap observation, then one action per step."""

    def __init__(self):
        self.task = None
        self.history = []          # [(action_dict, result_summary)]
        self.pending_screen = None  # screenshot not yet decided on
        self.last_screen = None     # the most recent screenshot received
        self.last_key = None        # key of the envelope sent last
        self.failed_captures = 0

    # ---- protocol handlers -------------------------------------------------

    def start_episode(self, payload):
        self.task = payload.get("task", {})
        self.history = []
        self.pending_screen = None
        self.last_screen = None
        self.last_key = None
        self.failed_captures = 0
        keys = [e.get("key") for e in payload.get("environment", {}).get("envelopes", [])]
        if "screen.capture" not in keys:
            log("environment publishes no screen.capture: " + ", ".join(map(str, keys)))
        return {}

    def next(self, payload):
        reply = self._next(payload)
        self.last_key = reply["envelope"]["key"]
        return reply

    def _next(self, payload):
        last = payload.get("lastResult")
        budget = payload.get("budget", {})

        # 1. Deterministic bootstrap: observe before any model call, so every
        #    episode starts identically (same convention as the Dart agents).
        if last is None:
            return {"envelope": envelope("screen.capture", "observe")}

        if last.get("status") == "ok" and "image" in last.get("payload", {}):
            self.pending_screen = last["payload"]
            self.last_screen = last["payload"]
            self.failed_captures = 0
        elif last.get("status") == "ok":
            # An action succeeded — the screen has changed, so look again
            # before deciding. Observing is what this modality *is*.
            self.note_result("ok")
        elif (self.last_key == "screen.capture"
              and (last.get("error") or {}).get("code") == "no_progress"
              and self.last_screen is not None):
            # The engine answers a screenshot identical to the previous one
            # with a notice instead of the image (ADR 0010). Identical means
            # the screen is the one already held: the last action changed
            # nothing visible. That is information, not a missing screen —
            # reading it as one aborted every episode whose first tap missed.
            self.pending_screen = self.last_screen
            self.failed_captures = 0
            self.note_result("no visible change: the screen is exactly as "
                             "before this action")
        else:
            self.note_result(
                f"failed: {json.dumps(last.get('error') or last)[:160]}")

        if self.pending_screen is None:
            self.failed_captures += 1
            if self.failed_captures > 2:
                # Nothing to look at and no way to get one: guessing
                # coordinates blindly would fake decisions the agent
                # cannot make.
                return {"envelope": envelope(
                    "meta.abort", "act",
                    {"reason": "no screen capture available"})}
            return {"envelope": envelope("screen.capture", "observe")}

        decision, telemetry = self.decide(budget)
        action = decision.get("action")
        log(f"decision: {decision}")

        if action == "tap" and (decision.get("x") is None
                                or decision.get("y") is None):
            # A tap without coordinates used to become a tap at (0, 0):
            # a real action the model never chose.
            self.history.append(("tap(<no coordinates given>)",
                                 "rejected: the tap action needs x and y"))
            self.pending_screen = None
            return {"envelope": envelope("screen.capture", "observe",
                                         None, telemetry)}
        if action == "tap":
            self.history.append((f"tap({decision.get('x')},{decision.get('y')})", ""))
            self.pending_screen = None
            return {"envelope": envelope(
                "pointer.tap", "act",
                {"x": decision["x"], "y": decision["y"]},
                telemetry)}
        if action == "type":
            text = decision.get("text")
            if not text:
                # "type" without text is not an action — sending it anyway
                # would burn a step on a no-op and hide the model's mistake
                # behind a successful envelope. Observe again and say why.
                self.history.append(("type(<no text given>)",
                                     "rejected: the type action needs a "
                                     "\"text\" field"))
                self.pending_screen = None
                return {"envelope": envelope("screen.capture", "observe",
                                             None, telemetry)}
            self.history.append((f"type({text!r})", ""))
            self.pending_screen = None
            return {"envelope": envelope(
                "pointer.text", "act", {"text": text}, telemetry)}
        if action == "abort":
            return {"envelope": envelope(
                "meta.abort", "act",
                {"reason": decision.get("summary") or decision.get("reasoning", "aborted")},
                telemetry)}
        return {"envelope": envelope(
            "meta.done", "act",
            {"summary": decision.get("summary") or decision.get("reasoning", "")},
            telemetry)}

    def note_result(self, text):
        """Attaches the outcome to the action it belongs to."""
        if self.history:
            self.history[-1] = (self.history[-1][0], text)
        else:
            self.history.append(("(observation)", text))

    def end_episode(self, payload):
        self.task = None
        return {}

    # ---- model call --------------------------------------------------------

    def decide(self, budget):
        screen = self.pending_screen
        instruction = (self.task or {}).get("instruction", "")
        steps = f"{budget.get('stepsUsed', 0)}/{budget.get('maxSteps', '?')}"
        recent = "\n".join(f"- {a} {r}".rstrip() for a, r in self.history[-5:])
        prompt = [
            f"Task: {instruction}",
            "",
            f"Screenshot coordinate space: {screen.get('width')} x "
            f"{screen.get('height')} logical pixels (origin top-left).",
            f"Budget: {steps} actions used.",
        ]
        if recent:
            prompt += ["", "What you already did:", recent]
        prompt += ["", "Decide the single next action."]

        body = {
            "model": MODEL,
            "stream": False,
            "format": ACTION_SCHEMA,
            "options": {"temperature": 0, "num_ctx": 8192,
                        "num_predict": MAX_ANSWER_TOKENS},
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": "\n".join(prompt),
                 "images": [screen["image"]]},
            ],
        }
        if THINK is not None:
            body["think"] = THINK.lower() == "true"
        started = time.monotonic()
        request = urllib.request.Request(
            OLLAMA + "/api/chat",
            data=json.dumps(body).encode(),
            headers={"content-type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                answer = json.loads(response.read().decode())
        except Exception as error:  # transport failure -> abort, not a crash
            log(f"llm error: {error}")
            return ({"action": "abort", "summary": f"llm_error: {error}"},
                    telemetry_of(started, 0, 0))
        latency = telemetry_of(
            started,
            answer.get("prompt_eval_count", 0),
            answer.get("eval_count", 0),
        )
        message = answer.get("message", {})
        content = message.get("content", "")
        if not content.strip() and THINK is not None:
            # Ollama 0.33.2 with qwen3-vl and think: false returns the
            # structured answer in `thinking` and leaves `content` empty.
            content = message.get("thinking", "")
        try:
            return json.loads(content), latency
        except json.JSONDecodeError:
            log(f"unparseable answer: {content[:200]}")
            return ({"action": "abort", "summary": "model answer was not JSON"},
                    latency)


def telemetry_of(started, prompt_tokens, completion_tokens):
    """AgentDecision telemetry (spec §4.3) — self-reported, as everywhere."""
    return {
        "model": MODEL,
        "tokensPrompt": prompt_tokens,
        "tokensCompletion": completion_tokens,
        "llmLatencyMs": int((time.monotonic() - started) * 1000),
        "llmCalls": 1,
    }


def envelope(key, kind, payload=None, decision=None):
    result = {"key": key, "kind": kind, "payload": payload or {}}
    if decision:
        result["decision"] = decision
    return result


def main():
    agent = VisionAgent()
    manifest = {
        "agentId": "vision",
        "version": "vision_py_v3",
        "description": "External Python vision agent (screenshots + pointer)",
        "metadata": {"model": MODEL, "language": "python", "transport": "stdio",
                     "think": THINK, "maxAnswerTokens": MAX_ANSWER_TOKENS},
    }
    handlers = {
        "aib.handshake": handshake,
        "agent.manifest": lambda p: {"manifest": manifest},
        "agent.startEpisode": agent.start_episode,
        "agent.next": agent.next,
        "agent.endEpisode": agent.end_episode,
    }

    for line in sys.stdin:
        if not line.strip():
            continue
        reply = rpc_reply(line, handlers)
        if reply is not None:
            sys.stdout.write(json.dumps(reply) + "\n")
            sys.stdout.flush()


# JSON-RPC 2.0 error codes the AIB protocol uses.
PARSE_ERROR, INVALID_REQUEST, METHOD_NOT_FOUND, INTERNAL_ERROR = (
    -32700, -32600, -32601, -32603)
VERSION_MISMATCH = -32001


def handshake(params):
    version = str(params.get("protocolVersion", ""))
    if version.split(".")[0] != PROTOCOL_VERSION.split(".")[0]:
        raise RpcError(VERSION_MISMATCH,
                       f"peer speaks AIB protocol {version}, "
                       f"this agent speaks {PROTOCOL_VERSION}")
    return {"protocolVersion": PROTOCOL_VERSION, "accepted": True,
            "role": "agent", "capabilities": []}


class RpcError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def rpc_reply(line, handlers):
    """The JSON-RPC 2.0 answer to one line, or None for a notification."""
    try:
        message = json.loads(line)
    except ValueError as error:
        return {"jsonrpc": "2.0", "id": None,
                "error": {"code": PARSE_ERROR, "message": str(error)}}
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        ident = message.get("id") if isinstance(message, dict) else None
        return {"jsonrpc": "2.0", "id": ident,
                "error": {"code": INVALID_REQUEST,
                          "message": "not a JSON-RPC 2.0 message"}}
    if "method" not in message:
        return None  # a response; this agent sends no requests
    if "id" not in message:
        return None  # a notification
    reply = {"jsonrpc": "2.0", "id": message["id"]}
    handler = handlers.get(message["method"])
    if handler is None:
        reply["error"] = {"code": METHOD_NOT_FOUND,
                          "message": f"unknown method {message['method']}"}
        return reply
    try:
        reply["result"] = handler(message.get("params") or {})
    except RpcError as error:
        reply["error"] = {"code": error.code, "message": error.message}
    except Exception as error:  # never die silently on the wire
        log(f"handler error: {error!r}")
        reply["error"] = {"code": INTERNAL_ERROR, "message": repr(error)}
    return reply

if __name__ == "__main__":
    main()
