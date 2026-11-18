## 1.1.0

- New provider `llamacpp` (`LlamaCppClient`) for llama.cpp's `llama-server`: prompt
  cache hits and time to first token from the server's timings, `think` as
  `reasoning_effort`, prefix warm-up. Warm-up fails when the loaded model's chat
  template has no tool support.
- The GenUi tools and prompts write the A2UI version the environment declares
  (`a2uiVersionOf`, `ToolStrategy.bind`); for v0.9 hosts they are unchanged.
- `agent.toolSurface: full` offers every intent with its schema from the first
  call (prompts `hybrid_v8`, `hybrid_v9`, `intent_v5`).
- The LLM judge samples at temperature 0.7 by default; a judge config may set
  `k` and `temperature`. An answer without the required tool call is reported as a
  format failure.

## 1.0.0

- First published release.
