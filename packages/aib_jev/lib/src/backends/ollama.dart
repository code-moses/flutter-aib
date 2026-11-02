import 'dart:convert';

import 'package:aib_core/transport.dart';
import 'package:http/http.dart' as http;

import '../chat_format.dart';
import '../client.dart';
import '../logits.dart';
import '../transport_http.dart';

/// Label logits from Ollama's `logprobs`: the local decision model without a
/// Python server. Fast because of the request: `num_predict: 1`, `keep_alive`,
/// one HTTP client for the whole run, and branches sent in order so Ollama's
/// prefix cache evaluates the shared prefix once.
///
/// Two modes:
///
/// - **raw** ([renderer] given): `/api/generate` with `raw: true` and the prompt
///   rendered in Dart by a [JevChatFormat]. The prompt is the one the reference
///   scores, character for character.
/// - **chat** ([renderer] null): `/api/chat` with the answer prefix as a prefilled
///   assistant turn, rendered by the model's own Ollama template. Works for any
///   model, but the prompt is close to the reference, not equal to it.
///
/// Ollama reports only the top 20 tokens ([maxLabels]); a label outside them is
/// floored (see [readTopLogprobs]).
final class OllamaJevLogits implements JevLogits, JevWarmUp, JevServerInfo {
  OllamaJevLogits({
    required this.model,
    this.baseUrl = 'http://localhost:11434',
    this.renderer,
    this.topLogprobs = 20,
    this.keepAlive = '30m',
    this.contextTokens = 8192,
    this.missingPenalty = 1.0,
    this.retryPolicy = const RetryPolicy(timeout: Duration(seconds: 60)),
    http.Client? httpClient,
  }) : assert(topLogprobs >= 1 && topLogprobs <= 20, 'Ollama caps top_logprobs at 20'),
       _http = httpClient ?? http.Client();

  /// Raw mode with the format the model name implies, chat mode when the
  /// name implies none.
  factory OllamaJevLogits.auto({required String model, String baseUrl = 'http://localhost:11434', http.Client? httpClient}) =>
      OllamaJevLogits(model: model, baseUrl: baseUrl, renderer: JevChatFormat.forModel(model)?.renderer, httpClient: httpClient);

  @override
  final String model;
  final String baseUrl;

  /// Raw mode when set; see the class comment.
  final JevPromptRenderer? renderer;

  final int topLogprobs;

  /// How long Ollama keeps the model loaded after a call. A decision model
  /// that is unloaded between episodes pays its load on every decision.
  final String keepAlive;

  /// `num_ctx`. Ollama truncates a longer prompt from the *front* without an
  /// error, which here would cut the classifier instructions; state it.
  /// Changing it reloads the model, so match the agent's value when the
  /// decider and the agent share one model.
  final int contextTokens;

  final double missingPenalty;
  final RetryPolicy retryPolicy;
  final http.Client _http;

  bool get isRaw => renderer != null;

  @override
  String get backend => isRaw ? 'ollama-raw' : 'ollama-chat';

  @override
  int? get maxLabels => topLogprobs;

  @override
  Future<JevLabelLogits> labelLogits(JevScoringPrompt prompt, {CancellationToken? cancellation}) => withRetries(
    () async {
      final body = buildBody(prompt);
      final raw = await postJson(
        _http,
        url: Uri.parse('$baseUrl${isRaw ? '/api/generate' : '/api/chat'}'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode(body),
      );
      return parseResponse(asJsonMap(jsonDecode(raw)), prompt.labels);
    },
    policy: retryPolicy,
    cancellation: cancellation,
  );

  JsonMap buildBody(JevScoringPrompt prompt) => {
    'model': model,
    'stream': false,
    'keep_alive': keepAlive,
    'logprobs': true,
    'top_logprobs': topLogprobs,
    // Greedy and one token: the distribution is read, nothing is sampled.
    'options': {'num_predict': 1, 'temperature': 0, 'num_ctx': contextTokens},
    if (renderer case final render?) ...{
      'raw': true,
      'prompt': prompt.render(render),
    } else ...{
      'think': false,
      'messages': [
        for (final turn in prompt.turns) turn.toJson(),
        {'role': 'assistant', 'content': prompt.answerPrefix},
      ],
    },
  };

  JevLabelLogits parseResponse(JsonMap json, List<String> labels) {
    final positions = json['logprobs'] as List? ?? const [];
    if (positions.isEmpty) {
      throw TransportException(
        'Ollama returned no logprobs for $model — it needs Ollama ≥ 0.12 and a model it runs on its own engine',
        kind: .badRequest,
      );
    }
    final top = [
      for (final entry in asJsonMap(positions.first)['top_logprobs'] as List? ?? const [])
        if (asJsonMap(entry) case final e) ('${e['token']}', (e['logprob'] as num).toDouble()),
    ];
    return readTopLogprobs(
      labels,
      top,
      missingPenalty: missingPenalty,
      promptTokens: (json['prompt_eval_count'] as num?)?.toInt() ?? 0,
      model: json['model'] as String?,
      raw: {
        'top_logprobs': top.map((e) => {'token': e.$1, 'logprob': e.$2}).toList(),
        'total_duration': ?json['total_duration'],
      },
    );
  }

  /// Loads the model and pins it for [keepAlive] without generating.
  @override
  Future<void> warmUp() async {
    try {
      await postJson(
        _http,
        url: Uri.parse('$baseUrl/api/generate'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({
          'model': model,
          'keep_alive': keepAlive,
          'options': {'num_ctx': contextTokens},
        }),
      );
    } on TransportException {
      // The first real call reports the problem properly.
    }
  }

  @override
  Future<List<String>> models() async {
    final json = asJsonMap(jsonDecode(await getText(_http, Uri.parse('$baseUrl/api/tags'))));
    return [for (final m in json['models'] as List? ?? const []) '${asJsonMap(m)['name']}'];
  }

  /// Ollama's version and the model's digest: a tag can be re-pulled onto
  /// other weights, a digest cannot.
  @override
  Future<JsonMap?> health() async {
    final version = asJsonMap(jsonDecode(await getText(_http, Uri.parse('$baseUrl/api/version'))));
    final tags = asJsonMap(jsonDecode(await getText(_http, Uri.parse('$baseUrl/api/tags'))));
    String canonical(String name) => name.contains(':') ? name : '$name:latest';
    final entry = [
      for (final m in tags['models'] as List? ?? const [])
        if (canonical('${asJsonMap(m)['name']}') == canonical(model)) asJsonMap(m),
    ].firstOrNull;
    return {'status': entry == null ? 'model_missing' : 'ok', 'ollama': version['version'], 'model': model, 'digest': entry?['digest']};
  }
}
