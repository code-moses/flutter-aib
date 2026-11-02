import 'dart:convert';

import 'package:aib_core/ports.dart';
import 'package:http/http.dart' as http;

import 'llm_client.dart';
import 'llm_http.dart';
import 'ollama_client.dart';

/// Provider-agnostic embedding port, next to [LlmClient]. A client that can
/// pin its model implements [LlmModelIdentity].
abstract interface class EmbeddingClient {
  String get model;

  Future<EmbeddingResponse> embed(List<String> texts, {CancellationToken? cancellation});
}

final class EmbeddingResponse {
  const EmbeddingResponse({required this.vectors, this.promptTokens = 0, this.model = ''});

  /// One vector per input text, in input order.
  final List<List<double>> vectors;
  final int promptTokens;
  final String model;
}

/// Ollama `/api/embed`.
final class OllamaEmbeddingClient implements EmbeddingClient, LlmModelIdentity {
  OllamaEmbeddingClient({
    required this.model,
    this.baseUrl = 'http://localhost:11434',
    this.retryPolicy = const LlmRetryPolicy(),
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  @override
  final String model;
  final String baseUrl;
  final LlmRetryPolicy retryPolicy;
  final http.Client _http;

  @override
  Future<EmbeddingResponse> embed(List<String> texts, {CancellationToken? cancellation}) => withRetries(
    () async {
      final json = asJsonMap(
        jsonDecode(
          await postJson(
            _http,
            url: Uri.parse('$baseUrl/api/embed'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({'model': model, 'input': texts}),
          ),
        ),
      );
      return EmbeddingResponse(
        vectors: _checked(texts, [for (final raw in json['embeddings'] as List? ?? const []) _vector(raw)]),
        promptTokens: (json['prompt_eval_count'] as num?)?.toInt() ?? 0,
        model: json['model'] as String? ?? model,
      );
    },
    policy: retryPolicy,
    cancellation: cancellation,
  );

  @override
  Future<JsonMap> modelIdentity() => OllamaClient(model: model, baseUrl: baseUrl, httpClient: _http).modelIdentity();
}

/// OpenAI-compatible `/v1/embeddings`.
final class OpenAiEmbeddingClient implements EmbeddingClient {
  OpenAiEmbeddingClient({
    required this.model,
    String? apiKey,
    this.baseUrl = 'https://api.openai.com',
    this.retryPolicy = const LlmRetryPolicy(),
    http.Client? httpClient,
  }) : _apiKey = apiKey ?? '',
       _http = httpClient ?? http.Client();

  @override
  final String model;
  final String baseUrl;
  final LlmRetryPolicy retryPolicy;
  final String _apiKey;
  final http.Client _http;

  @override
  Future<EmbeddingResponse> embed(List<String> texts, {CancellationToken? cancellation}) => withRetries(
    () async {
      final json = asJsonMap(
        jsonDecode(
          await postJson(
            _http,
            url: Uri.parse('$baseUrl/v1/embeddings'),
            headers: {'content-type': 'application/json', 'authorization': 'Bearer $_apiKey'},
            body: jsonEncode({'model': model, 'input': texts}),
          ),
        ),
      );
      // Items carry an index; the order they arrive in is not a promise.
      final data = [for (final raw in json['data'] as List? ?? const []) asJsonMap(raw)]
        ..sort((a, b) => (a['index'] as num).compareTo(b['index'] as num));
      return EmbeddingResponse(
        vectors: _checked(texts, [for (final item in data) _vector(item['embedding'])]),
        promptTokens: (asJsonMap(json['usage'])['prompt_tokens'] as num?)?.toInt() ?? 0,
        model: json['model'] as String? ?? model,
      );
    },
    policy: retryPolicy,
    cancellation: cancellation,
  );
}

List<double> _vector(Object? raw) => [for (final value in raw as List? ?? const []) (value as num).toDouble()];

/// A short answer would silently pair texts with the wrong vectors.
List<List<double>> _checked(List<String> texts, List<List<double>> vectors) {
  if (vectors.length != texts.length) {
    throw LlmClientException('expected ${texts.length} embedding(s), got ${vectors.length}', kind: LlmErrorKind.badRequest);
  }
  return vectors;
}
