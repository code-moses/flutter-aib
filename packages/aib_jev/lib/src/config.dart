import 'package:aib_core/transport.dart';
import 'package:http/http.dart' as http;

import 'backends/ollama.dart';
import 'backends/openai_completions.dart';
import 'chat_format.dart';
import 'client.dart';
import 'http_client.dart';
import 'logits.dart';
import 'template.dart';

/// Resolves a secret by name (an environment variable in the harness, a
/// keychain entry or a server-side proxy in an app). Returns null when unset.
typedef JevSecretResolver = String? Function(String name);

/// A [JevClient] from a declarative `jev:` block, so an app or an arm moves
/// between backends by editing YAML.
///
/// ```yaml
/// # A System One server: simple-jev, LiteVar, openjev (default backend)
/// jev: {baseUrl: http://127.0.0.1:8000, model: Qwen/Qwen3.5-4B}
///
/// # The hosted API (key from TYPESAFE_API_KEY unless apiKeyEnv says otherwise;
/// # models from GET /v1/models: jev-latest, jev-preview)
/// jev: {baseUrl: https://api.typesafe.ai, model: jev-latest}
///
/// # Local, through Ollama's logprobs; the prompt is rendered in Dart
/// jev: {backend: ollama, model: qwen3:4b, format: auto, keepAlive: 30m}
///
/// # Local, any /v1/completions server with logprobs (llama-server, vLLM)
/// jev: {backend: openai, baseUrl: http://127.0.0.1:8080, model: qwen3-4b,
///       format: qwen3}
/// ```
///
/// `template` (local backends only) is `v1-noul-decimal` by default (see
/// [JevTemplate.v1NoulDecimal]) or `v1`, the reference exactly.
///
/// `format` names a [JevChatFormat], `native` (Ollama only: the model's own
/// template) or `auto` (the format the model id implies; Ollama falls back to
/// `native`, a completions server refuses).
///
/// An unknown backend or format throws. Keys it does not know are left alone:
/// the same block carries the router's `threshold` and `criteria`.
///
/// dart:io-free: secrets come in through [JevSecretResolver].
abstract final class JevConfig {
  static const backends = ['systemone', 'ollama', 'openai'];

  static JevClient clientFromJson(JsonMap block, {JevSecretResolver? secret, http.Client? httpClient}) {
    final backend = block['backend'] as String? ?? 'systemone';
    final retry = block['retry'] == null ? null : RetryPolicy.fromJson(asJsonMap(block['retry']));
    final model = block['model'] as String? ?? '';
    String? key(String? env) => env == null ? null : secret?.call(env);

    switch (backend) {
      case 'systemone' || 'http':
        final baseUrl = block['baseUrl'] as String? ?? 'http://127.0.0.1:8000';
        final hosted = baseUrl == HttpJevClient.hostedBaseUrl;
        // Both reject a request that does not name its model: simple-jev
        // with the id it was started with, the hosted API with a 422.
        if (model.isEmpty) {
          throw ArgumentError(
            hosted
                ? 'jev config requires "model" for the hosted API (jev-latest or jev-preview)'
                : 'jev config requires "model" for a self-hosted server '
                      '(simple-jev rejects a request that does not name its model)',
          );
        }
        return HttpJevClient(
          model: model,
          baseUrl: baseUrl,
          path: block['path'] as String? ?? '/v1/systemone',
          apiKey: key(block['apiKeyEnv'] as String? ?? (hosted ? 'TYPESAFE_API_KEY' : null)),
          headers: {for (final e in asJsonMap(block['headers']).entries) e.key: '${e.value}'},
          retryPolicy: retry ?? const RetryPolicy(timeout: Duration(seconds: 30)),
          httpClient: httpClient,
        );
      case 'ollama':
        _requireModel(model, backend);
        final format = block['format'] as String? ?? 'auto';
        return LogitJevClient(
          logits: OllamaJevLogits(
            model: model,
            baseUrl: block['baseUrl'] as String? ?? 'http://localhost:11434',
            renderer: switch (format) {
              'native' => null,
              'auto' => JevChatFormat.forModel(model)?.renderer,
              _ => JevChatFormat.byName(format).renderer,
            },
            topLogprobs: (block['topLogprobs'] as num?)?.toInt() ?? 20,
            keepAlive: block['keepAlive'] as String? ?? '30m',
            contextTokens: (block['contextTokens'] as num?)?.toInt() ?? 8192,
            retryPolicy: retry ?? const RetryPolicy(timeout: Duration(seconds: 60)),
            httpClient: httpClient,
          ),
          template: _template(block),
          parallel: block['parallel'] as bool? ?? false,
        );
      case 'openai' || 'llama-server' || 'vllm':
        _requireModel(model, backend);
        final format = block['format'] as String? ?? 'auto';
        final resolved = format == 'auto' ? JevChatFormat.forModel(model) : JevChatFormat.byName(format);
        if (resolved == null) {
          throw ArgumentError(
            'jev backend "$backend" needs "format" (${JevChatFormat.values.map((f) => f.name).join(' | ')}): "$model" does not imply one',
          );
        }
        return LogitJevClient(
          logits: OpenAiCompletionsJevLogits(
            model: model,
            renderer: resolved.renderer,
            baseUrl: block['baseUrl'] as String? ?? 'http://127.0.0.1:8080',
            apiKey: key(block['apiKeyEnv'] as String?),
            topLogprobs: (block['topLogprobs'] as num?)?.toInt() ?? 20,
            backendName: backend == 'openai' ? 'openai-completions' : backend,
            retryPolicy: retry ?? const RetryPolicy(timeout: Duration(seconds: 60)),
            httpClient: httpClient,
          ),
          template: _template(block),
          parallel: block['parallel'] as bool? ?? false,
        );
      default:
        throw FormatException('jev backend "$backend" is not implemented (${backends.join(' | ')})');
    }
  }

  /// `template:` for the local backends; v1-noul-decimal unless the block
  /// says otherwise.
  static JevTemplate _template(JsonMap block) => JevTemplate.byId(block['template'] as String? ?? JevTemplate.v1NoulDecimal.id);

  static void _requireModel(String model, String backend) {
    if (model.isEmpty) throw ArgumentError('jev backend "$backend" requires "model"');
  }
}
