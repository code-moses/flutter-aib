# ARTEMIS as an AIB agent

[google/artemis](https://github.com/google/artemis) drives Android by looking
at the screen. This adapter lets it drive *our* environment instead, so the
same suite scores a foreign agent that knows nothing about the app's
capabilities — the comparison the thesis wants against the app-cooperative
hybrid.

Neither side is modified. ARTEMIS owns its loop, so the adapter inverts the
control flow: every call its device driver makes becomes one envelope, and
the engine answers it on the next `agent.next`.

```
engine (app, Flutter test)            adapter (this process)
  agent.next            ───────────▶  FlashRunner wants a screen
  screen.capture        ◀───────────  driver.get_screen_data()
  semantics.tree        ◀───────────
  pointer.tap {x, y}    ◀───────────  driver.tap()
  meta.done / meta.abort◀───────────  report_task_status
```

## Running one

The engine connects out (a sandboxed macOS test build may open a socket but
not spawn a process), so start the adapter first:

```sh
ARTEMIS_AIB_PROVIDER=anthropic ARTEMIS_AIB_MODEL=claude-sonnet-5 \
  python agents/artemis/aib_artemis_agent.py --port 8765

# in the app repo
fvm dart integration_test/aib/prepare_benchmark_inputs.dart
fvm dart integration_test/enable_in_memory_session_assets.dart
fvm flutter test integration_test/aib/m5_live_benchmark_test.dart -d macos \
  --dart-define=AIB_REMOTE_AGENT=127.0.0.1:8765 \
  --dart-define=AIB_TASKS=nav.open.list --dart-define=AIB_REPS=1 \
  --dart-define=AIB_OUT=artemis-smoke
```

`agents/artemis/fake_engine.py` next to it answers the protocol with a
synthetic screen — it needs no app and is the fastest way to see whether the
adapter still starts.

## The model needs vision *and* tools

The Flash loop is entirely tool-call driven and every turn carries a
screenshot. `qwen2.5vl:7b` has vision but Ollama refuses tool definitions for
it (`does not support tools`); `qwen3`, `gpt-oss` and `llama3.1` take tools
but see nothing. So a local run needs a model that reports both
(`ollama show` → capabilities), and `claude-sonnet-5` is the hosted option.

## What it costs to know

- ARTEMIS's own sub-agents (the background step summariser, the video tools)
  build a Google client from `artemis.jsonc`, not from the LLM config the
  adapter passes. Ours turns them off; without that a run needs a Gemini key
  it never uses.
- Its driver contract is larger than a benchmark environment can answer.
  `press_key`, `launch_app`, `execute_shell` and the video recorders answer
  "unsupported" rather than pretending.
- Token usage is summed per envelope and split by role (backlog D6), so a
  sub-agent's spend stays visible next to the loop's own. ARTEMIS streams,
  and a streamed OpenAI-compatible call reports usage only when the request
  asks for it — without `stream_usage` every turn comes back with no counts
  and the run reports an agent that cost nothing.
- Its tool surface is narrowed to what an AIB environment answers. Offered
  the full Android set, the model reached for `manage_app` and a sub-agent
  spent 180 s of a 300 s budget resolving a package name that does not
  exist here.
- Every LLM call is capped at 180 s, hard-coded at the call site, and a cold
  model load is charged to the first one: run v4 aborted there having spent
  0 tokens. The adapter loads the model before it starts listening and holds
  it with `keep_alive`.
- It is told, in the goal, that one app is already open and there is no
  launcher. Unbriefed it ended run v3 with `done` and a hallucinated "Google
  News is open" — a premature termination the suite scored 0.00.
- **The transport has a limit of its own.** Once the screenshot actually
  reached the agent, a single `agent.next` line carried ~200 KB of base64 and
  asyncio's 64 KiB `StreamReader` cap killed the connection ("Separator is
  found, but chunk is longer than limit") — while the process stayed bound to
  the port, so a liveness check on the pid passed and the engine saw only a
  reset. The server sets `limit=32 MiB`; check the port, not the pid.
- **`temperature` on a hosted model that refuses it.** claude-sonnet-5 answers
  400, "deprecated for this model", and two runs died on their first call
  having spent nothing. It is not fixable through ARTEMIS's config:
  `ModelEndpoint.temperature` is a non-nullable float whose builder maps both
  None and 0.0 to 0.0. Worse, langchain *does* strip the parameter from the
  payload for this model — and re-adds it under `extra_body`, which reaches
  the API verbatim. Only clearing the attribute on the built model removes it,
  so the adapter's `get_model` patch does that for Anthropic.
- **Every screenshot is declared `image/jpeg`** (`flash/runner.py:373`, another
  Android assumption). Our bridge sends PNG, Ollama never looked, and Anthropic
  answers 400: "specified using the image/jpeg media type, but the image
  appears to be a image/png image". The driver transcodes with Pillow before
  handing the bytes over, which is free in both directions: 121 KB of PNG
  becomes 44 KB of JPEG.
- **The element list is a contract, in two ways.** `semantics.tree` answers
  with a *list* of roots; a visitor that only accepts dicts returns nothing,
  and ARTEMIS's "Visible UI Elements" section was empty in every run while its
  prompt's first rule says to prefer the element index. And its bounds must be
  in the **0-1000** normalized space, because the actuator multiplies by
  `screen / 1000` (`adb.py:_to_px`) — hand it logical pixels and a model that
  aims perfectly still taps at 0.8×, 0.6× the intended point. Fixing both is
  what turned 0/2 into 1/2 (`results/artemis-sonnet5-v9`).
