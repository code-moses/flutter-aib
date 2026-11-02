import 'package:aib_jev/aib_jev.dart';

import 'llama_logits.dart';
import 'model_store.dart';

/// `JevConfig` plus the in-process backend: `backend: llama` builds a
/// [LlamaJevLogits] client, fetching the model through a [JevModelStore]
/// when the block names a download; every other backend goes to
/// [JevConfig.clientFromJson] unchanged.
///
/// ```yaml
/// jev:
///   backend: llama
///   format: qwen3                    # the model's chat format (required)
///   download:                        # or modelPath: /path/to/model.gguf
///     url: https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf
///     sha256: 7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5
///     size: 2497280256
///   contextTokens: 8192
///   gpuLayers: 99
///   template: v1-noul-decimal        # default
/// ```
///
/// Kept apart from `JevConfig`, which is pure Dart and web-safe: this one
/// needs `dart:io` for the store and `dart:ffi` for the runtime.
abstract final class LlamaJevConfig {
  static Future<JevClient> clientFromJson(
    JsonMap block, {
    required JevModelStore store,
    JevSecretResolver? secret,
    void Function(int received, int? total)? onProgress,
    CancellationToken? cancellation,
  }) async {
    if (block['backend'] != 'llama') return JevConfig.clientFromJson(block, secret: secret);

    final path = switch ((block['modelPath'], block['download'])) {
      (final String path, null) => path,
      (null, final Map<Object?, Object?> download) => (await store.ensure(
        JevModelSource.fromJson(asJsonMap(download)),
        onProgress: onProgress,
        cancellation: cancellation,
      )).path,
      _ => throw const FormatException('jev backend "llama" needs exactly one of "modelPath" and "download"'),
    };
    final formatName = block['format'] as String?;
    final format = formatName == null ? null : JevChatFormat.byName(formatName);
    if (format == null) {
      throw FormatException(
        'jev backend "llama" needs "format" (${JevChatFormat.values.map((f) => f.name).join(' | ')}): '
        'a GGUF file does not say which chat template its prompts need',
      );
    }
    return LogitJevClient(
      logits: LlamaJevLogits(
        modelPath: path,
        renderer: format.renderer,
        // The pinned hash names the weights in provenance; a path alone would
        // name wherever the file happened to be.
        model: block['model'] as String? ?? _modelName(block),
        contextTokens: (block['contextTokens'] as num?)?.toInt() ?? 8192,
        gpuLayers: (block['gpuLayers'] as num?)?.toInt() ?? 99,
        threads: (block['threads'] as num?)?.toInt(),
      ),
      template: JevTemplate.byId(block['template'] as String? ?? JevTemplate.v1NoulDecimal.id),
    );
  }

  static String? _modelName(JsonMap block) => switch (block['download']) {
    final Map<Object?, Object?> download => 'gguf-sha256:${'${download['sha256']}'.toLowerCase().substring(0, 12)}',
    _ => null,
  };
}
