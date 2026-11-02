# VisionAgent (Python, stdio) — the foreign agent

An agent that is deliberately *outside* everything the framework knows:
another language (Python), another modality (screenshots instead of
semantics or intents), another process (attached over the stdio wire
protocol, spec §4.5). It exists to answer research question "agent- and
model-independence" (M6): a new agent integrates without a single change to
`aib_core`.

```
BenchmarkEngine ──RemoteAgent──▶ stdio (line-delimited JSON) ──▶ vision_agent.py
                                                                      │
                                                          Ollama (vision model)
```

What it uses from the environment (keys published by `VisionBridge`):

| direction | key | payload |
|---|---|---|
| observe | `screen.capture` | `{}` → `{image (base64 PNG), width, height, scale}` |
| act | `pointer.tap` | `{x, y}` in logical pixels |
| act | `pointer.text` | `{text}` into the focused field |
| act | `meta.done` / `meta.abort` | as every agent |

Design mirrors the Dart reference agents so the comparison stays fair:
deterministic bootstrap observation (no model call), one envelope per
`next()`, self-reported telemetry (`model`, tokens, latency, calls) on every
envelope. The model answers in a fixed JSON shape (Ollama structured
output), which keeps a small local vision model usable — no tool-calling
support required.

## Running

```sh
ollama pull qwen2.5vl:7b            # any vision model Ollama serves

cd apps/todo_app
AIB_VISION=1 AIB_VISION_DEBUG=1 \
  fvm flutter test test/benchmark/live/m6_vision_agent_test.dart
```

Environment: `AIB_VISION_MODEL` (default `qwen2.5vl:7b`), `AIB_OLLAMA_URL`,
`AIB_VISION_DEBUG=1`, plus the runner's `AIB_TASKS` / `AIB_REPS` / `AIB_OUT`.

The same test file also contains a **key-free conformance check** (runs in
CI, no model, no Ollama): it spawns the agent, performs handshake + manifest
exchange and asserts the deterministic first envelope. Any third-party
agent implementation can be verified the same way.

Requirements: `python3` (standard library only — no pip install).

## Note on screenshots in widget tests

`flutter_test` draws every glyph as a filled box unless real fonts are
loaded, which would leave a vision agent staring at unreadable rectangles.
The harness therefore loads Roboto and MaterialIcons from the pinned SDK
(`loadRealFonts()` in `apps/todo_app/test/benchmark/harness.dart`) before
the first frame.
