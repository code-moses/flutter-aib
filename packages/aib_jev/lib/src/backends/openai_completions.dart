import 'dart:convert';
import 'dart:math' as math;

import 'package:aib_core/transport.dart';
import 'package:http/http.dart' as http;

import '../chat_format.dart';
import '../client.dart';
import '../logits.dart';
import '../transport_http.dart';

/// Label logits from any server that speaks OpenAI's `/v1/completions` with
/// `logprobs`: llama.cpp's `llama-server`, vLLM, LM Studio, hugind, SGLang.
///
/// The prompt is always raw ([renderer]); completions endpoints apply no chat
/// template. `max_tokens: 1`, `temperature: 0`, `echo: false`.
///
/// Three reply shapes are read, because the servers disagree:
/// - OpenAI completions (`choices[0].logprobs.top_logprobs[0]`, a token → logprob
///   map): vLLM, LM Studio, llama-server's compat layer;
/// - chat-style (`choices[0].logprobs.content[0].top_logprobs`, a list);
/// - llama.cpp's native `completion_probabilities`.
///
/// [topLogprobs] is what the server allows: vLLM defaults to a maximum of 20,
/// llama-server takes more, OpenAI's own endpoint caps at 5.
final class OpenAiCompletionsJevLogits implements JevLogits, JevServerInfo {
  OpenAiCompletionsJevLogits({
    required this.model,
    required this.renderer,
    this.baseUrl = 'http://127.0.0.1:8080',
    String? apiKey,
    this.topLogprobs = 20,
    this.missingPenalty = 1.0,
    this.backendName = 'openai-completions',
    this.retryPolicy = const RetryPolicy(timeout: Duration(seconds: 60)),
    http.Client? httpClient,
  }) : _apiKey = apiKey ?? '',
       _http = httpClient ?? http.Client();

  @override
  final String model;
  final JevPromptRenderer renderer;
  final String baseUrl;
  final int topLogprobs;
  final double missingPenalty;

  /// Recorded as `metadata.backend` — name the server (`llama-server`,
  /// `vllm`) when it is known.
  final String backendName;

  final RetryPolicy retryPolicy;
  final String _apiKey;
  final http.Client _http;

  @override
  String get backend => backendName;

  @override
  int? get maxLabels => topLogprobs;

  Map<String, String> get _headers => {'content-type': 'application/json', if (_apiKey.isNotEmpty) 'authorization': 'Bearer $_apiKey'};

  @override
  Future<JevLabelLogits> labelLogits(JevScoringPrompt prompt, {CancellationToken? cancellation}) => withRetries(
    () async {
      final raw = await postJson(_http, url: Uri.parse('$baseUrl/v1/completions'), headers: _headers, body: jsonEncode(buildBody(prompt)));
      return parseResponse(asJsonMap(jsonDecode(raw)), prompt.labels);
    },
    policy: retryPolicy,
    cancellation: cancellation,
  );

  JsonMap buildBody(JevScoringPrompt prompt) => {
    'model': model,
    'prompt': prompt.render(renderer),
    'max_tokens': 1,
    'temperature': 0,
    'logprobs': topLogprobs,
    'echo': false,
    // llama-server's native knob, ignored elsewhere.
    'n_probs': topLogprobs,
  };

  JevLabelLogits parseResponse(JsonMap json, List<String> labels) {
    final top = _top(json);
    if (top.isEmpty) {
      throw TransportException('the server returned no logprobs — does it support "logprobs" on /v1/completions?', kind: .badRequest);
    }
    final usage = asJsonMap(json['usage']);
    return readTopLogprobs(
      labels,
      top,
      missingPenalty: missingPenalty,
      promptTokens: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
      model: json['model'] as String?,
      raw: {
        'top_logprobs': top.map((e) => {'token': e.$1, 'logprob': e.$2}).toList(),
      },
    );
  }

  static List<(String, double)> _top(JsonMap json) {
    final choices = json['choices'] as List? ?? const [];
    if (choices.isNotEmpty) {
      final logprobs = asJsonMap(asJsonMap(choices.first)['logprobs']);
      // Legacy: top_logprobs is a list (per position) of token → logprob maps.
      if (logprobs['top_logprobs'] case final List positions when positions.isNotEmpty && positions.first is Map) {
        return [
          for (final MapEntry(:key, :value) in asJsonMap(positions.first).entries)
            if (value is num) (key, value.toDouble()),
        ];
      }
      // Chat-style: content[0].top_logprobs is a list of {token, logprob}.
      if (logprobs['content'] case final List content when content.isNotEmpty) {
        return _entries(asJsonMap(content.first)['top_logprobs']);
      }
    }
    // llama.cpp native: completion_probabilities[0].top_logprobs (or probs).
    if (json['completion_probabilities'] case final List positions when positions.isNotEmpty) {
      final first = asJsonMap(positions.first);
      return _entries(first['top_logprobs'] ?? first['probs']);
    }
    return const [];
  }

  static List<(String, double)> _entries(Object? list) => [
    for (final entry in list as List? ?? const [])
      if (asJsonMap(entry) case final e)
        // Older llama-server builds report probabilities, not logprobs.
        if ((e['logprob'] ?? e['prob']) case final num value)
          ('${e['token'] ?? e['tok_str']}', e['logprob'] != null ? value.toDouble() : math.log(math.max(value.toDouble(), 1e-30))),
  ];

  @override
  Future<List<String>> models() async {
    final json = jsonDecode(await getText(_http, Uri.parse('$baseUrl/v1/models'), headers: _headers));
    final data = json is Map ? asJsonMap(json)['data'] : json;
    return [
      for (final entry in data as List? ?? const [])
        if (entry is Map) '${asJsonMap(entry)['id']}',
    ];
  }

  @override
  Future<JsonMap?> health() async {
    try {
      return asJsonMap(jsonDecode(await getText(_http, Uri.parse('$baseUrl/health'), headers: _headers)));
    } on TransportException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }
}
