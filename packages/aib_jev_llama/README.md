# aib_jev_llama — a decision model inside the process

`LlamaJevLogits` reads label logits from llama.cpp in-process. Wrapped in
`aib_jev`'s `LogitJevClient`, it answers the same questions with the same
template and scoring as every other backend, with no server at all.

```dart
final jev = LogitJevClient(
  logits: LlamaJevLogits(modelPath: 'qwen3-4b-q4_k_m.gguf', renderer: JevChatFormat.qwen3.renderer),
  template: JevTemplate.v1NoulDecimal,
);
await jev.warmUp();                      // loads once, ~0.6 s for qwen3:4b
final answer = await jev.judge(state: JevState.text(task), statement: 'The task deletes data.');
```

- **Full logits.** No top-20 cap and nothing floored, so a 30-way choice
  works.
- **A worker isolate** holds the model and context. A decode never blocks
  the caller, so a Flutter UI keeps drawing.
- **KV-cache reuse across calls.** Only the part of a prompt that differs
  from the previous one is evaluated, which in practice means the question
  suffix.
- **The reference's single-token check** runs on every call: `text + label`
  must tokenize to the prompt's tokens plus exactly one more, and the labels
  must be distinct tokens.

Measured on an M3 Max (Metal), qwen3:4b Q4_K_M, the Ollama blob loaded
directly:

| | |
|---|---|
| load | 612 ms |
| one-question decision, warm | 49 ms |
| agreement with Ollama on the same weights and prompt | noul 0.562 vs 0.556 and 0.114 vs 0.117 |

## Getting the model: a pinned download

`JevModelStore` fetches a GGUF by content, not by name. A model is stored
as `<sha256>.gguf` and is used only when its bytes hash to the pin, so a
repository that swaps a file under the same URL cannot swap the decider.

```dart
final store = JevModelStore(Directory('${support.path}/jev'));
final file = await store.ensure(JevModelSource.qwen3_4bQ4KM,
    onProgress: (received, total) => print('$received / $total'));
```

- **Resumable.** Bytes arrive in `<sha256>.gguf.part`. An interrupted or
  cancelled download continues with a range request, and starts over when
  the server ignores the range.
- **Atomic.** The final name appears only after the hash and the size
  matched. A mismatch deletes the partial file and throws
  `JevModelChecksumMismatch`.
- **Verified once.** A verified file gets a sidecar with its size and
  modification time, so later starts skip the multi-second hash of 2.5 GB.
  If either changes, the file is hashed again, and `verify: true` forces a
  re-hash.

From a config block, `LlamaJevConfig.clientFromJson` handles `backend: llama`
(and hands every other backend to `JevConfig`):

```yaml
jev:
  backend: llama
  format: qwen3
  download:
    url: https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf
    sha256: 7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5
    size: 2497280256
```

The client then reports `gguf-sha256:7485fe6f11af` as its model, so
provenance names the weights rather than a file path. The pin above is
Qwen's own Q4_K_M build, as the Hugging Face API reported it on
2026-09-23. It is not byte-identical to Ollama's `qwen3:4b` blob; the
routing arm's numbers came from the Ollama one.

## Why llamadart's internals

llamadart (0.8.24, verified publisher, prebuilt binaries via its build hook)
exposes generation, embeddings and structured output, but not logits. This
package reuses its native library and its generated `@Native` bindings from
`src/`. That is about twelve llama.cpp functions, and it saves both writing
our own ffigen bindings and asking every app build for a C++ toolchain. The
catch is that those bindings are not llamadart's public API, so the version
is pinned exactly and the live test is the check on any bump.

Verified on macOS. The Linux and Android bundles split their GPU backends
into modules, which load best-effort; the CPU always works.

```sh
JEV_GGUF=~/.ollama/models/blobs/sha256-… JEV_OLLAMA_MODEL=qwen3:4b \
  fvm dart test -t live --run-skipped
```
