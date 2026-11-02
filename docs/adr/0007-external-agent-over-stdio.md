# ADR 0007 — The foreign agent: vision modality over stdio

Date: 2026-08-19 · Status: accepted

## Context

M6 asks for evidence that the framework absorbs an agent it was not designed
around — ideally in another language, over the wire protocol (spec §7
VisionAgent, §11 Phase 6). The evidence is only worth something if the core
stays untouched: `git diff` of `aib_core` must be empty for the whole
exercise.

Three obstacles were in the way, none of them in the core:

1. There was **no way to attach a child process**. `aib_protocol` had
   `LineJsonTransport` and `RemoteAgent`, but nothing that starts an
   executable and wires the pipes.
2. The Flutter adapter published no **screen/pointer vocabulary** — the
   semantics and intent bridges assume an agent that reads structure.
3. `flutter_test` renders text as **filled boxes** unless real fonts are
   loaded. A vision agent in that harness would be asked to read text that
   was never drawn — the measurement would describe the harness, not the
   agent.

## Decision

- `SubprocessTransport.spawn(executable, args)` in `aib_protocol`: starts the
  agent process, speaks line-delimited JSON on its stdin/stdout, forwards its
  stderr to the run log with a prefix (a Python traceback must not surface as
  a timeout).
- `VisionBridge` in `aib_flutter` publishes `screen.capture` (base64 PNG plus
  the logical-pixel coordinate space) and `pointer.tap` / `pointer.drag` /
  `pointer.text`. Screenshot and gestures are **host callbacks**, so the same
  bridge serves a widget-test host (`RenderRepaintBoundary.toImage`) and, in
  Phase 5, a device host. Optional gestures are only published when the host
  supplies them; everything else answers `unsupported` (§4.2).
- The agent itself lives outside the Dart workspace, in
  `agents/vision_python/vision_agent.py`: standard library only, no pip
  install, and it mirrors the Dart agents' loop (deterministic bootstrap
  observation, one envelope per `next()`, self-reported telemetry).
- **Structured output instead of tool calling.** The Python agent asks Ollama
  for a fixed JSON shape (`format:` schema) rather than function calls. Small
  local vision models support images far more reliably than tools, and the
  decision is a closed set (`tap|type|done|abort`), so a schema expresses it
  exactly. This is a property of that agent, not of the framework.
- `loadRealFonts()` in the todo harness loads Roboto/MaterialIcons from the
  pinned SDK before the first frame. No font is vendored into the repo.
- A **key-free conformance test** ships next to the live one: it spawns the
  Python agent, performs handshake + manifest exchange and asserts the
  deterministic first envelope. It runs in CI without Ollama and is the
  template for verifying any third-party agent.

## Consequences

- M6's structural claim is verifiable at any time and cheap to re-check: the
  core diff for this ADR is empty; everything happened in `aib_protocol`
  (transport), `aib_flutter` (bridge) and outside the workspace (agent).
- The first live episode showed the *measurement* works and the local model
  is weak: `qwen2.5vl:7b` located the todo row correctly, tapped it (opening
  the edit screen instead of the checkbox) and then looped on "type" without
  ever supplying text until the token budget ended the episode. That is a
  result about a 7B vision model, not about the framework — and exactly the
  kind of result the benchmark exists to produce.
- Two rules follow from that episode, both kept agent-side: a `type` decision
  without text is rejected and re-observed instead of sent as an empty
  no-op, and the host types into the **focused** field only — falling back to
  "the first text field on screen" would repair a mis-aimed tap and credit
  the agent with precision it did not have. With both in place the same
  episode ends in a *legible* failure after 7 steps ("the title on screen
  does not match the task") instead of burning the token budget — the
  difference between a measurement and a timeout.
- The vision strategy costs one observation per action (a screenshot cannot
  be cached across a state change), which makes `observation_bytes` the
  metric that separates it from the structural strategies.
