#!/usr/bin/env python3
"""Google ARTEMIS as an AIB agent.

ARTEMIS (github.com/google/artemis) drives Android by looking at the screen:
a screenshot plus a list of elements, and taps by index or coordinate. It
owns its loop, so this adapter inverts the control flow — every device call
its driver makes becomes one AIB envelope, answered by the engine on the next
`agent.next` request. Nothing in aib_core or in ARTEMIS is modified.

The engine connects to us (a sandboxed Flutter test build may open a socket
but not spawn a process), so this process listens and serves the AIB agent
protocol: newline-delimited JSON, methods aib.handshake, agent.manifest,
agent.startEpisode, agent.next, agent.endEpisode.

    python aib_artemis_agent.py --port 8765

Environment:
  ARTEMIS_AIB_MODEL      vision model (default: qwen2.5vl:7b)
  ARTEMIS_AIB_PROVIDER   ollama | google | anthropic | openai (default: ollama)
  OPENAI_BASE_URL        Ollama's OpenAI-compatible endpoint
                         (default: http://localhost:11434/v1)
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import io
import json
import os
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any

PROTOCOL_VERSION = "2.0"  # AIB protocol; framing is JSON-RPC 2.0
MODEL = os.environ.get("ARTEMIS_AIB_MODEL", "qwen2.5vl:7b")
PROVIDER = os.environ.get("ARTEMIS_AIB_PROVIDER", "ollama")
os.environ.setdefault("OPENAI_BASE_URL", "http://localhost:11434/v1")
os.environ.setdefault("OPENAI_API_KEY", "ollama")
# ARTEMIS resolves `artemis.jsonc` through ARTEMIS_ARTEMIS_JSONC first; ours
# turns off the sub-agents that would build a Google client regardless of the
# LLM config below.
os.environ.setdefault(
    "ARTEMIS_ARTEMIS_JSONC", str(Path(__file__).resolve().parent / "artemis.jsonc")
)


def log(message: str) -> None:
    sys.stderr.write(f"[artemis-aib] {message}\n")
    sys.stderr.flush()


# --------------------------------------------------------------------------
# The exchange: one envelope out, one result back.
# --------------------------------------------------------------------------
class Exchange:
    """Couples ARTEMIS's loop to the engine's turn-taking.

    ARTEMIS calls the driver whenever it wants something; the driver parks the
    envelope here and waits. `agent.next` takes it, and the result of the
    previous one arrives with the call after it.
    """

    def __init__(self) -> None:
        self.pending: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self._result: asyncio.Future[dict[str, Any]] | None = None
        self.finished: asyncio.Future[dict[str, Any]] = asyncio.get_event_loop().create_future()

    async def send(
        self,
        key: str,
        kind: str,
        payload: dict[str, Any],
        prefetch: bool = False,
    ) -> dict[str, Any]:
        """Emits one envelope and waits for the engine's result.

        [prefetch] marks what the loop takes every turn rather than what the
        model asked for. ARTEMIS observes the screen before every decision, so on
        a screen that did not change those observations are byte-identical —
        and the engine's no-progress guard, which is right to stop an agent
        repeating itself, would otherwise end the episode for looking twice.
        """
        loop = asyncio.get_running_loop()
        self._result = loop.create_future()
        await self.pending.put(
            {"key": key, "kind": kind, "payload": payload, "prefetch": prefetch}
        )
        return await self._result

    def deliver(self, result: dict[str, Any]) -> None:
        if self._result is not None and not self._result.done():
            self._result.set_result(result)
            self._result = None

    def finish(self, report: dict[str, Any]) -> None:
        if not self.finished.done():
            self.finished.set_result(report)


# --------------------------------------------------------------------------
# The driver: ARTEMIS's device contract, answered by AIB envelopes.
# --------------------------------------------------------------------------
def build_driver_class():
    """Imported lazily so `--help` works without ARTEMIS installed."""
    from artemis.drivers.base import BaseDeviceDriver, ScreenData

    class AibDeviceDriver(BaseDeviceDriver):
        """The app under benchmark, seen as a device.

        Screen: `screen.capture` for the picture, `semantics.tree` for the
        elements — ARTEMIS indexes a flat list of `{text, bounds}` in the same
        units as the reported width/height, so logical pixels throughout.
        """

        def __init__(self, exchange: Exchange) -> None:
            self._exchange = exchange
            self._width = 1080
            self._height = 2400

        @property
        def device_id(self) -> str:
            return "aib"

        @property
        def screen_size(self) -> tuple[int, int]:
            return (self._width, self._height)

        async def connect(self) -> None:
            return None

        async def disconnect(self) -> None:
            return None

        async def get_screen_data(self, skip_settling: bool = False) -> ScreenData:
            shot = await self._exchange.send(
                "screen.capture", "observe", {}, prefetch=True
            )
            tree = await self._exchange.send(
                "semantics.tree", "observe", {}, prefetch=True
            )
            payload = shot.get("payload") or {}
            image = payload.get("image") or ""
            self._width = int(payload.get("width") or self._width)
            self._height = int(payload.get("height") or self._height)
            jpeg = as_jpeg(base64.b64decode(image)) if image else b""
            return ScreenData(
                screenshot_bytes=jpeg,
                screenshot_base64=base64.b64encode(jpeg).decode() if jpeg else "",
                ui_elements=flatten_semantics(
                    (tree.get("payload") or {}).get("tree"),
                    self._width,
                    self._height,
                ),
                width=self._width,
                height=self._height,
                platform="aib",
            )

        async def tap(self, x: int, y: int, *args: Any, **kwargs: Any) -> bool:
            result = await self._exchange.send(
                "pointer.tap", "act", {"x": float(x), "y": float(y)}
            )
            return result.get("status") == "ok"

        async def long_press(self, x: int, y: int, duration_ms: int = 1000) -> bool:
            return await self.tap(x, y)

        async def swipe(
            self,
            start_x: int,
            start_y: int,
            end_x: int,
            end_y: int,
            duration_ms: int = 300,
        ) -> bool:
            result = await self._exchange.send(
                "pointer.drag",
                "act",
                {
                    "fromX": float(start_x),
                    "fromY": float(start_y),
                    "toX": float(end_x),
                    "toY": float(end_y),
                },
            )
            return result.get("status") == "ok"

        async def swipe_direction(self, direction: Any, *args: Any, **kwargs: Any) -> bool:
            width, height = self._width, self._height
            moves = {
                "up": (width / 2, height * 0.7, width / 2, height * 0.3),
                "down": (width / 2, height * 0.3, width / 2, height * 0.7),
                "left": (width * 0.7, height / 2, width * 0.3, height / 2),
                "right": (width * 0.3, height / 2, width * 0.7, height / 2),
            }
            value = getattr(direction, "value", direction)
            move = moves.get(str(value), moves["up"])
            return await self.swipe(*(int(v) for v in move))

        async def input_text(self, text: str, clear_existing: bool = True) -> bool:
            result = await self._exchange.send("pointer.text", "act", {"text": text})
            return result.get("status") == "ok"

        async def press_key(self, key: Any) -> bool:
            return False

        async def launch_app(self, package_name: str) -> bool:
            return False

        async def stop_app(self, package_name: str) -> bool:
            return False

        async def get_current_package(self) -> str | None:
            return "aib"

        async def execute_shell(self, command: str, timeout_seconds: float = 15.0) -> str:
            return "unsupported: no shell behind an AIB environment"

        async def start_video_recording(self, output_dir: Any = None) -> None:
            return None

        async def stop_video_recording(self) -> str | None:
            return None

    return AibDeviceDriver


def build_actuator_class():
    """Narrows ARTEMIS's tool surface to what an AIB environment answers.

    Subclasses the ADB actuator rather than reimplementing it: the action
    methods already go through the controller, which goes through our driver.
    Only `capabilities()` moves — and with it the prompt, since a tool that
    is not declared leaves no trace in it. Without this the model is offered
    `manage_app` and spends a sub-agent call resolving an Android package
    name that does not exist here (180 s of a 300 s budget, once).
    """
    from artemis.mcp.action_manifest import INTERNAL_ACTIONS, REQUIRED_ACTIONS
    from artemis.mcp.actuators.adb import AdbActuator

    answerable = REQUIRED_ACTIONS | INTERNAL_ACTIONS | {
        "click",
        "long_press",
        "input_text",
        "swipe",
        "wait_for_delay",
    }

    class AibActuator(AdbActuator):
        def capabilities(self):
            return frozenset(answerable)

        def extensions(self):
            return []

    return AibActuator


def flatten_semantics(
    tree: Any, screen_width: float, screen_height: float
) -> list[dict[str, Any]]:
    """Semantics nodes -> ARTEMIS's flat element list.

    Bounds are `[left,top][right,bottom]` strings in ARTEMIS's **0-1000**
    normalized space, not logical pixels. Its actuator multiplies whatever the
    model emits by `screen / 1000` (`adb.py:_to_px`) and its prompt instructs
    the model to use that scale, so pixels here are scaled down a second time:
    claude-sonnet-5 named the Artikel tile's exact centre (699, 422) and the
    tap arrived at (559, 253).
    """
    elements: list[dict[str, Any]] = []
    scale_x = 1000.0 / screen_width if screen_width else 1.0
    scale_y = 1000.0 / screen_height if screen_height else 1.0

    def visit(node: Any) -> None:
        if not isinstance(node, dict):
            return
        rect = node.get("rect") or {}
        label = node.get("label") or node.get("value") or node.get("tooltip") or ""
        left, top = rect.get("left"), rect.get("top")
        node_width, node_height = rect.get("width"), rect.get("height")
        if label and None not in (left, top, node_width, node_height):
            elements.append(
                {
                    "text": str(label),
                    "bounds": f"[{int(left * scale_x)},{int(top * scale_y)}]"
                    f"[{int((left + node_width) * scale_x)},"
                    f"{int((top + node_height) * scale_y)}]",
                    "class": "android.widget.TextView",
                    "clickable": "true",
                }
            )
        for child in node.get("children") or []:
            visit(child)

    # `semantics.tree` answers with a *list* of roots. Passing it to a visitor
    # that only accepts dicts returned an empty list every time, so ARTEMIS's
    # "Visible UI Elements" section was empty in every run up to 2026-09-12
    # and the model had nothing but the screenshot to aim by.
    for root in tree if isinstance(tree, list) else [tree]:
        visit(root)
    return elements


# --------------------------------------------------------------------------
# Token usage, kept apart from the agent's own loop (backlog D6).
# --------------------------------------------------------------------------
class UsageCollector:
    """Sums provider usage per envelope, split by which node spent it."""

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.prompt = 0
        self.completion = 0
        self.calls = 0
        self.latency_ms = 0
        self.by_role: dict[str, int] = {}

    def record(self, role: str, prompt: int, completion: int, latency_ms: int) -> None:
        self.prompt += prompt
        self.completion += completion
        self.calls += 1
        self.latency_ms += latency_ms
        self.by_role[role] = self.by_role.get(role, 0) + prompt + completion

    def decision(self, prefetch: bool = False) -> dict[str, Any]:
        decision = {
            "model": MODEL,
            "tokensPrompt": self.prompt,
            "tokensCompletion": self.completion,
            "llmCalls": self.calls,
            "llmLatencyMs": self.latency_ms,
            "note": "route=vision",
        }
        extra: dict[str, Any] = {}
        if prefetch:
            extra["prefetch"] = True
        if self.by_role:
            extra["counters"] = {f"tokens_{k}": v for k, v in self.by_role.items()}
        if extra:
            decision["extra"] = extra
        self.reset()
        return decision


def as_jpeg(png_bytes: bytes) -> bytes:
    """The bridge sends PNG; ARTEMIS tells the model every screenshot is JPEG.

    `flash/runner.py:373` hardcodes `data:image/jpeg;base64,…`, an Android
    assumption. Anthropic checks the bytes against that media type and rejects
    the PNG ("the image appears to be a image/png image"); Ollama never looked.
    JPEG carries no alpha, hence the RGB conversion.
    """
    if not png_bytes:
        return b""
    try:
        from PIL import Image

        with Image.open(io.BytesIO(png_bytes)) as image:
            buffer = io.BytesIO()
            image.convert("RGB").save(buffer, format="JPEG", quality=85)
            return buffer.getvalue()
    except Exception as error:
        # A screenshot is not worth ending an episode over; send it as it came
        # and let the provider decide.
        log(f"jpeg conversion failed, sending the original bytes: {error!r}")
        return png_bytes


def patch_built_models() -> None:
    """Two corrections on every model ARTEMIS builds.

    `stream_usage`: ARTEMIS streams, and a streamed OpenAI-compatible call
    reports no token counts unless the request asks for them — without this a
    run reports an agent that cost nothing.

    `temperature`: claude-sonnet-5 rejects the parameter outright (400,
    "deprecated for this model"). langchain strips it from the payload and
    then re-adds it under `extra_body`, which reaches the API verbatim, so
    clearing the attribute is what drops it. ARTEMIS's own config layer cannot
    express this: `ModelEndpoint.temperature` is a non-nullable float whose
    builder maps both None and 0.0 to 0.0.
    """
    from artemis.llm.router import ModelFactory

    original = ModelFactory.get_model

    def patched(endpoint, *args, **kwargs):
        model = original(endpoint, *args, **kwargs)
        if hasattr(model, "stream_usage"):
            try:
                model.stream_usage = True
            except (AttributeError, TypeError, ValueError):
                pass
        if PROVIDER == "anthropic" and getattr(model, "temperature", None) is not None:
            try:
                model.temperature = None
            except (AttributeError, TypeError, ValueError):
                pass
        return model

    ModelFactory.get_model = staticmethod(patched)


def install_usage_callback(collector: UsageCollector) -> None:
    """Counts every LLM call ARTEMIS makes, whichever node makes it."""
    from langchain_core.callbacks.manager import BaseCallbackManager  # noqa: F401
    from langchain_core.callbacks import BaseCallbackHandler
    from langchain_core.globals import set_llm_cache  # noqa: F401
    from langchain_core.tracers.context import register_configure_hook

    class Usage(BaseCallbackHandler):
        def __init__(self) -> None:
            self._started: dict[str, float] = {}

        def on_llm_start(self, serialized, prompts, *, run_id=None, **kwargs):
            self._started[str(run_id)] = time.monotonic()

        def on_chat_model_start(self, serialized, messages, *, run_id=None, **kwargs):
            self._started[str(run_id)] = time.monotonic()

        def on_llm_end(self, response, *, run_id=None, **kwargs):
            started = self._started.pop(str(run_id), None)
            latency = int((time.monotonic() - started) * 1000) if started else 0
            usage = _usage_of(response)
            if not usage and not Usage._complained:
                Usage._complained = True
                log(f"no usage in {type(response).__name__}: {_usage_shape(response)}")
            collector.record(
                "operator",
                int(usage.get("input_tokens") or usage.get("prompt_tokens") or 0),
                int(usage.get("output_tokens") or usage.get("completion_tokens") or 0),
                latency,
            )

    Usage._complained = False
    handler = Usage()
    register_configure_hook(_usage_var(handler), True)


def _usage_of(response) -> dict[str, Any]:
    """Providers put usage in four different places; take the first."""
    output = getattr(response, "llm_output", None) or {}
    for candidate in (output.get("token_usage"), output.get("usage")):
        if candidate:
            return dict(candidate)
    for generations in getattr(response, "generations", []) or []:
        for generation in generations:
            message = getattr(generation, "message", None)
            for candidate in (
                getattr(message, "usage_metadata", None),
                (getattr(message, "response_metadata", None) or {}).get("token_usage"),
                (getattr(generation, "generation_info", None) or {}).get("token_usage"),
            ):
                if candidate:
                    return dict(candidate)
    return {}


def _usage_shape(response) -> str:
    """What the response carried, so a provider change is one log line away."""
    parts = [f"llm_output={sorted((getattr(response, 'llm_output', None) or {}).keys())}"]
    for generations in getattr(response, "generations", []) or []:
        for generation in generations:
            message = getattr(generation, "message", None)
            parts.append(
                f"message={type(message).__name__} "
                f"meta={sorted((getattr(message, 'response_metadata', None) or {}).keys())} "
                f"usage_metadata={getattr(message, 'usage_metadata', None)}"
            )
            break
        break
    return " | ".join(parts)


def _usage_var(handler):
    from contextvars import ContextVar

    var: ContextVar = ContextVar("aib_usage_handler", default=handler)
    var.set(handler)
    return var


# --------------------------------------------------------------------------
# The episode: ARTEMIS's Flash loop, driven by the engine's turns.
# --------------------------------------------------------------------------
#: What every agent here knows and ARTEMIS cannot see: there is one app, it
#: is already in front of it, and nothing else exists. Without this it hunts
#: for a launcher — it swiped for an app drawer and reported that Google News
#: was open (results/artemis-qwen3vl-v3). Our own agents get the same fact
#: from the environment descriptor, so stating it is levelling, not helping.
BRIEFING = (
    "You are operating one single application that is already open and in "
    "the foreground on a desktop screen. There is no home screen, no app "
    "drawer, no launcher and no other app: never try to open, launch or "
    "switch applications, and never look for a browser. Everything you need "
    "is inside the screen you are given. Work only towards the task below.\n\n"
    "Task: "
)


class ArtemisEpisode:
    def __init__(self, goal: str) -> None:
        self.goal = BRIEFING + goal
        self.exchange = Exchange()
        self.usage = UsageCollector()
        self._task: asyncio.Task | None = None
        self._done = False

    def start(self) -> None:
        patch_built_models()
        install_usage_callback(self.usage)
        self._task = asyncio.create_task(self._run())
        # Belt and braces: a task that dies without finishing the exchange
        # would hang the engine's next turn.
        self._task.add_done_callback(
            lambda task: self.exchange.finish(
                {"status": "failed", "explanation": f"artemis task ended: {task!r}"}
            )
        )

    async def _run(self) -> None:
        # Everything is inside the guard: a failure while importing ARTEMIS or
        # building its context must end the episode, not leave agent.next
        # waiting for an envelope that can no longer come.
        try:
            from artemis.agents.flash.runner import FlashRunner
            from artemis.context import ArtemisContext, DeviceContext
            from artemis.graph.state import State

            driver_class = build_driver_class()
            context = ArtemisContext(
                trace_id="aib",
                device=DeviceContext(device_id="aib", device_width=1080, device_height=2400),
                llm_config=build_llm_config(),
            )
            context._active_driver = driver_class(self.exchange)
            actuator = build_actuator_class()(context)
            context.actuator = actuator
            log(f"tools offered: {' '.join(sorted(actuator.capabilities()))}")
            report = await FlashRunner(context, self.goal).run(State(initial_goal=self.goal))
        except asyncio.CancelledError:
            raise
        except BaseException as error:
            import traceback

            log(f"artemis failed: {error!r}\n{traceback.format_exc()}")
            report = {"status": "failed", "explanation": f"artemis error: {error!r}"}
        self.exchange.finish(report or {"status": "failed", "explanation": "no report"})

    async def next_envelope(self, last_result: dict[str, Any] | None) -> dict[str, Any]:
        """One turn: hand back the previous result, take the next envelope."""
        if last_result is not None:
            self.exchange.deliver(last_result)
        pending = asyncio.ensure_future(self.exchange.pending.get())
        finished = self.exchange.finished
        await asyncio.wait({pending, finished}, return_when=asyncio.FIRST_COMPLETED)
        if pending.done():
            envelope = pending.result()
        else:
            pending.cancel()
            envelope = self._termination(finished.result())
        prefetch = envelope.pop("prefetch", False)
        envelope["decision"] = self.usage.decision(prefetch=prefetch)
        return envelope

    @staticmethod
    def _termination(report: dict[str, Any]) -> dict[str, Any]:
        status = (report or {}).get("status")
        text = (report or {}).get("explanation") or ""
        if status == "completed":
            return {"key": "meta.done", "kind": "act", "payload": {"summary": text}}
        return {"key": "meta.abort", "kind": "act", "payload": {"reason": text or "failed"}}

    async def stop(self) -> None:
        if self._task is not None and not self._task.done():
            self._task.cancel()
            try:
                await self._task
            except (asyncio.CancelledError, Exception):
                pass


def build_llm_config():
    """One model for every ARTEMIS node; the Flash loop only uses `operator`."""
    from artemis.config.llm import LLM, LLMConfig, LLMConfigUtils, LLMWithFallback

    # claude-sonnet-5 rejects the parameter outright ("`temperature` is
    # deprecated for this model", 400); None omits it, since the router drops
    # None kwargs. Local models keep 0.0 for determinism.
    temperature = None if PROVIDER == "anthropic" else 0.0

    def model() -> LLMWithFallback:
        return LLMWithFallback(
            provider=PROVIDER,
            model=MODEL,
            temperature=temperature,
            fallback=LLM(provider=PROVIDER, model=MODEL, temperature=temperature),
        )

    # Every optional node too: unset ones fall back to a Gemini default and
    # ARTEMIS builds that model even when the Flash loop never calls it.
    return LLMConfig(
        planner=model(),
        utils=LLMConfigUtils(
            outputter=model(),
            hopper=model(),
            video_analyzer=model(),
            object_detector=model(),
        ),
        summarizer=model(),
        operator=model(),
        operator_summarizer=model(),
        log_reader_sub_agent=model(),
        log_analyzer=model(),
        diagnoser=model(),
        checker=model(),
        planner_avatar=model(),
        history_analyzer_expert=model(),
        diagnoser_expert=model(),
        explorer=model(),
        history_analyzer=model(),
        validator_pixel_safety_net=model(),
        planner_validation=model(),
        output_analyzer=model(),
    )


# --------------------------------------------------------------------------
# The AIB agent protocol, over a socket the engine connects to.
# --------------------------------------------------------------------------
MANIFEST = {
    "agentId": "artemis",
    "version": "artemis_flash_v1",
    "description": "Google ARTEMIS (Flash profile) over the AIB protocol",
    "metadata": {
        "model": MODEL,
        "provider": PROVIDER,
        "language": "python",
        "transport": "socket",
        "profile": "flash",
    },
}


class RpcError(Exception):
    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class Session:
    def __init__(self) -> None:
        self.episode: ArtemisEpisode | None = None

    async def handle(self, method: str, payload: dict[str, Any]) -> dict[str, Any]:
        if method == "aib.handshake":
            version = str(payload.get("protocolVersion", ""))
            if version.split(".")[0] != PROTOCOL_VERSION.split(".")[0]:
                raise RpcError(
                    -32001,
                    f"peer speaks AIB protocol {version}, "
                    f"this agent speaks {PROTOCOL_VERSION}",
                )
            return {
                "protocolVersion": PROTOCOL_VERSION,
                "accepted": True,
                "role": "agent",
                "capabilities": [],
            }
        if method == "agent.manifest":
            return {"manifest": MANIFEST}
        if method == "agent.startEpisode":
            await self._end()
            goal = (payload.get("task") or {}).get("instruction") or ""
            log(f"episode: {goal[:80]}")
            self.episode = ArtemisEpisode(goal)
            self.episode.start()
            return {}
        if method == "agent.next":
            if self.episode is None:
                raise RuntimeError("agent.next before agent.startEpisode")
            return {"envelope": await self.episode.next_envelope(payload.get("lastResult"))}
        if method == "agent.endEpisode":
            await self._end()
            return {}
        raise RpcError(-32601, f"unknown method {method}")

    async def _end(self) -> None:
        if self.episode is not None:
            await self.episode.stop()
            self.episode = None


def warm_model() -> None:
    """Loads the model before the engine connects.

    ARTEMIS caps every LLM call at 180 s, hard-coded at the call site, and a
    cold load of a large-context model does not fit in it: run v4 aborted on
    its first call having spent 0 tokens. `keep_alive` holds it across episodes.
    """
    if PROVIDER != "ollama":
        return
    base = os.environ["OPENAI_BASE_URL"].removesuffix("/v1")
    body = json.dumps(
        {
            "model": MODEL,
            "stream": False,
            "keep_alive": "2h",
            "messages": [{"role": "user", "content": "ok"}],
            "options": {"num_predict": 1},
        }
    ).encode()
    started = time.monotonic()
    try:
        request = urllib.request.Request(
            f"{base}/api/chat", data=body, headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(request, timeout=900) as response:
            response.read()
        log(f"model warm after {time.monotonic() - started:.0f}s")
    except Exception as error:
        log(f"warm-up failed, the first call may time out: {error!r}")


async def serve(host: str, port: int) -> None:
    await asyncio.to_thread(warm_model)
    session = Session()

    async def client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        log(f"engine connected from {writer.get_extra_info('peername')}")
        while True:
            line = await reader.readline()
            if not line:
                break
            try:
                message = json.loads(line)
            except ValueError as error:
                reply: dict[str, Any] = {
                    "jsonrpc": "2.0",
                    "id": None,
                    "error": {"code": -32700, "message": str(error)},
                }
            else:
                if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
                    reply = {
                        "jsonrpc": "2.0",
                        "id": message.get("id") if isinstance(message, dict) else None,
                        "error": {"code": -32600, "message": "not a JSON-RPC 2.0 message"},
                    }
                elif "method" not in message or "id" not in message:
                    continue  # a response or a notification: nothing to answer
                else:
                    reply = {"jsonrpc": "2.0", "id": message["id"]}
                    try:
                        reply["result"] = await session.handle(
                            message["method"], message.get("params") or {}
                        )
                    except RpcError as error:
                        reply["error"] = {"code": error.code, "message": error.message}
                    except Exception as error:
                        log(f"handler error: {error!r}")
                        reply["error"] = {"code": -32603, "message": repr(error)}
            writer.write((json.dumps(reply) + "\n").encode())
            await writer.drain()
        await session._end()
        log("engine disconnected")

    # asyncio caps a line at 64 KiB. An `agent.next` carries the previous
    # screenshot back as base64 (~200 KB), which killed the connection with
    # "Separator is found, but chunk is longer than limit".
    server = await asyncio.start_server(
        client, host, port, limit=32 * 1024 * 1024
    )
    log(f"listening on {host}:{port} (model {PROVIDER}/{MODEL})")
    async with server:
        await server.serve_forever()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    arguments = parser.parse_args()
    try:
        asyncio.run(serve(arguments.host, arguments.port))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
