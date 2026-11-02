/// A decision model inside the process: [LlamaJevLogits] reads label logits
/// from llama.cpp through llamadart's native library. Wrap it in a
/// `LogitJevClient` and it answers the same questions, with the same
/// template and scoring, as every other `aib_jev` backend.
///
/// ```dart
/// final jev = LogitJevClient(
///   logits: LlamaJevLogits(modelPath: 'qwen3-4b-q4_k_m.gguf', renderer: JevChatFormat.qwen3.renderer),
///   template: JevTemplate.v1NoulDecimal,
/// );
/// await jev.warmUp();
/// ```
///
/// Separate from `aib_jev` because it needs `dart:ffi` and a native build
/// hook; `aib_jev` stays pure Dart and web-safe.
library;

export 'src/config.dart';
export 'src/llama_logits.dart';
export 'src/model_store.dart';
