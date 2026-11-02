import 'dart:convert';

import 'package:aib_core/ports.dart';
import 'package:http/http.dart' as http;

import 'llm_client.dart';
import 'llm_http.dart';

/// Ollama /api/chat adapter — the stable local reference model of the risk
/// mitigation plan (spec §12: develop against Ollama, final runs against
/// API models).
final class OllamaClient implements LlmClient, LlmWarmUp, LlmPrefixWarmUp, LlmModelIdentity, LlmContextWindow, LlmStructuredOutput {
  OllamaClient({
    required this.model,
    this.baseUrl = 'http://localhost:11434',
    this.contextTokens = defaultContextTokens,
    this.think,
    this.retryPolicy = const LlmRetryPolicy(),
    http.Client? httpClient,
  }) : assert(think == null || think is bool || think is String, 'think must be a bool or a reasoning level string'),
       _http = httpClient ?? http.Client();

  /// Ollama defaults to a 4k context and silently drops the *oldest* messages
  /// beyond it, which can truncate the task instruction. The window is always
  /// stated explicitly.
  static const defaultContextTokens = 32768;

  @override
  final String model;
  final String baseUrl;

  /// `num_ctx` sent with every request (recorded per run, see
  /// `suites/agents/ollama.yaml`).
  @override
  final int contextTokens;

  /// Thinking models: `false` disables the reasoning phase, `true` forces
  /// it, `null` leaves the model default. Models with graded reasoning
  /// (gpt-oss) also accept a level string — `'low' | 'medium' | 'high'`.
  /// Kept explicit because it changes both latency and answer quality.
  final Object? think;

  final LlmRetryPolicy retryPolicy;

  final http.Client _http;

  /// Ollama's `format` takes a JSON schema and decodes under the grammar
  /// llama.cpp derives from it.
  @override
  bool get supportsResponseSchema => true;

  @override
  Future<LlmResponse> complete(LlmRequest request, {CancellationToken? cancellation}) => withRetries(
    () async => parseResponseBody(
      await postJson(
        _http,
        url: Uri.parse('$baseUrl/api/chat'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode(buildBody(request)),
      ),
      parseResponse,
    ),
    policy: retryPolicy,
    cancellation: cancellation,
  );

  /// Loads the model into memory without producing tokens, so the first
  /// episode of a run is not charged for Ollama's cold start.
  @override
  Future<void> warmUp() async {
    try {
      await postJson(
        _http,
        url: Uri.parse('$baseUrl/api/chat'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'model': model, 'messages': <JsonMap>[], 'stream': false}),
      );
    } on LlmClientException {
      // A failed warm-up is not a failed run: the first real call will
      // report the problem with a proper error.
    }
  }

  /// Evaluates the prompt with `num_predict: 0`: the server keeps its KV cache,
  /// and a following request that shares the prefix restores it instead of
  /// prefilling it. On a sliding-window model (gemma4) that only works when the
  /// prefix ends close to where the cached sequence ends, which is why it is
  /// sent on its own rather than hoped for from the previous conversation.
  @override
  Future<void> warmPrefix(LlmRequest request) async {
    final body = buildBody(request);
    try {
      await postJson(
        _http,
        url: Uri.parse('$baseUrl/api/chat'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({
          ...body,
          'options': {...asJsonMap(body['options']), 'num_predict': 0},
        }),
      );
    } on LlmClientException {
      // A failed warm-up costs the next call its cache, nothing more.
    }
  }

  /// A tag can be re-pulled onto different weights; the digest cannot.
  @override
  Future<JsonMap> modelIdentity() async {
    final response = await _http.get(Uri.parse('$baseUrl/api/tags'));
    final models = asJsonMap(jsonDecode(response.body))['models'] as List? ?? const [];
    String canonical(String name) => name.contains(':') ? name : '$name:latest';
    for (final entry in models) {
      final m = asJsonMap(entry);
      if (canonical('${m['name']}') == canonical(model)) {
        return {'provider': 'ollama', 'model': model, 'digest': m['digest'], if (m['details'] != null) 'details': m['details']};
      }
    }
    return {'provider': 'ollama', 'model': model, 'digest': null};
  }

  JsonMap buildBody(LlmRequest request) => {
    'model': model,
    'stream': false,
    if (think != null) 'think': think,
    // Sent because the loop's contract is one call per turn. Ollama accepts and
    // ignores the field, so [ToolLoopAgent] enforces the contract itself and
    // records what it dropped.
    'parallel_tool_calls': ?request.parallelToolCalls,
    // The schema constrains what the model writes, not which tools it is told
    // about: `tools` stays, so the chat template still renders every name and
    // description into the prompt. Ollama then leaves `message.content` as the
    // constrained JSON and reports no `tool_calls` — [ConstrainedToolCalls]
    // reads it from there. With thinking on, only the answer after the
    // reasoning is constrained.
    'format': ?request.responseSchema,
    'options': {'temperature': ?request.temperature, 'num_ctx': contextTokens, 'num_predict': request.maxTokens},
    'messages': [
      for (final message in request.messages)
        switch (message.role) {
          .system => {'role': 'system', 'content': message.content},
          .user => {'role': 'user', 'content': message.content},
          .assistant => {
            'role': 'assistant',
            'content': message.content,
            if (message.toolCalls.isNotEmpty)
              'tool_calls': [
                for (final call in message.toolCalls)
                  {
                    'function': {'name': call.name, 'arguments': call.arguments},
                  },
              ],
          },
          // `tool_name` ties a result to its call; Ollama sends no call ids.
          .tool => {'role': 'tool', 'content': message.content, 'tool_name': ?message.toolName},
        },
    ],
    if (request.tools.isNotEmpty)
      'tools': [
        for (final tool in request.tools)
          {
            'type': 'function',
            'function': {'name': tool.name, 'description': tool.description, 'parameters': tool.parameters},
          },
      ],
  };

  static LlmResponse parseResponse(JsonMap json) {
    final message = asJsonMap(json['message']);
    var callIndex = 0;
    return LlmResponse(
      text: message['content'] as String? ?? '',
      thinking: message['thinking'] as String?,
      toolCalls: [
        for (final raw in message['tool_calls'] as List? ?? const [])
          if (asJsonMap(asJsonMap(raw)['function']) case final function)
            if (LlmToolCall.decodeArguments(function['arguments']) case final decoded)
              LlmToolCall(
                // Ollama sends no call ids — synthesize deterministic ones.
                id: 'call_${callIndex++}',
                name: function['name'] as String? ?? '',
                arguments: decoded.arguments,
                argumentsError: decoded.error,
              ),
      ],
      // prompt_eval_count includes the cached prefix (0.40.1: 499 of which
      // 494 cached on a repeated call), the same split Anthropic reports.
      usage: LlmUsage(
        promptTokens: (json['prompt_eval_count'] as num?)?.toInt() ?? 0,
        completionTokens: (json['eval_count'] as num?)?.toInt() ?? 0,
        cachedPromptTokens: (json['prompt_eval_cached_count'] as num?)?.toInt() ?? 0,
      ),
      model: json['model'] as String? ?? '',
      stopReason: json['done_reason'] as String?,
      // Ollama reports its own timings in nanoseconds even without streaming,
      // and loading plus reading the prompt is exactly the wait before the
      // first token. Better than a client-side stopwatch, which cannot see
      // where the time went.
      firstTokenMs: switch ((json['load_duration'], json['prompt_eval_duration'])) {
        (final num load, final num prompt) => (load + prompt) ~/ 1000000,
        (_, final num prompt) => prompt ~/ 1000000,
        _ => null,
      },
    );
  }
}
