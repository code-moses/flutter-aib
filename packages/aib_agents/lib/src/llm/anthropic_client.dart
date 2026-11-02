import 'dart:convert';

import 'package:aib_core/ports.dart';
import 'package:http/http.dart' as http;

import 'llm_client.dart';
import 'llm_http.dart';

/// Anthropic Messages API adapter.
final class AnthropicClient implements LlmClient {
  AnthropicClient({
    required this.model,
    String? apiKey,
    this.baseUrl = 'https://api.anthropic.com',
    this.retryPolicy = const LlmRetryPolicy(),
    this.promptCaching = true,
    http.Client? httpClient,
  }) : _apiKey = apiKey ?? '',
       _http = httpClient ?? http.Client();

  @override
  final String model;
  final String baseUrl;
  final LlmRetryPolicy retryPolicy;

  /// Whether to mark the stable part of the request as cacheable.
  ///
  /// Caching changes what a request costs, never what the model is shown. Cache
  /// reads and writes are folded back into `promptTokens`, so every metric but
  /// `cost_usd` is identical with it on and off. Off is for quoting an uncached
  /// price, or a proxy that rejects the field.
  final bool promptCaching;

  final String _apiKey;
  final http.Client _http;

  @override
  Future<LlmResponse> complete(LlmRequest request, {CancellationToken? cancellation}) => withRetries(
    () async => parseResponseBody(
      await postJson(
        _http,
        url: Uri.parse('$baseUrl/v1/messages'),
        headers: {'content-type': 'application/json', 'x-api-key': _apiKey, 'anthropic-version': '2023-06-01'},
        body: jsonEncode(buildBody(request)),
      ),
      parseResponse,
    ),
    policy: retryPolicy,
    cancellation: cancellation,
  );

  /// Request mapping (exposed for the conformance-style unit tests).
  JsonMap buildBody(LlmRequest request) {
    final system = request.messages.where((m) => m.role == .system).map((m) => m.content).join('\n\n');

    final messages = <JsonMap>[];
    for (final message in request.messages) {
      switch (message.role) {
        case .system:
          break; // top-level `system` field
        case .user:
          messages.add({
            'role': 'user',
            'content': [
              {'type': 'text', 'text': message.content},
            ],
          });
        case .assistant:
          messages.add({
            'role': 'assistant',
            'content': [
              if (message.content.isNotEmpty) {'type': 'text', 'text': message.content},
              for (final call in message.toolCalls) {'type': 'tool_use', 'id': call.id, 'name': call.name, 'input': call.arguments},
            ],
          });
        case .tool:
          final block = {'type': 'tool_result', 'tool_use_id': message.toolCallId, 'content': message.content};
          // Consecutive tool results must share one user message.
          if (messages case [
            ...,
            {"role": "user", "content": final List lastContent},
          ] when (lastContent.lastOrNull as Map?)?["type"] == "tool_result") {
            lastContent.add(block);
          } else {
            messages.add({
              'role': 'user',
              'content': [block],
            });
          }
      }
    }

    // Two breakpoints. Anthropic renders tools, then system, then messages, and
    // a breakpoint caches everything before it.
    //
    // - After `system`: tools + system, byte-identical across episodes. - After
    // the last message: the conversation so far, which the next turn re-sends
    // before
    //    appending to it. Each turn writes only what is new and reads everything before it.
    if (promptCaching) {
      if (messages.lastOrNull?['content'] case final List content when content.isNotEmpty) {
        // Rebuilt rather than mutated: the block literals above infer narrow
        // value types, and writing a map into one of those lists in place
        // throws at runtime rather than failing to compile.
        messages[messages.length - 1] = {
          ...messages.last,
          'content': <JsonMap>[
            for (final block in content.take(content.length - 1)) asJsonMap(block),
            {
              ...asJsonMap(content.last),
              'cache_control': const {'type': 'ephemeral'},
            },
          ],
        };
      }
    }

    return {
      'model': model,
      'max_tokens': request.maxTokens,
      if (request.temperature != null) 'temperature': request.temperature,
      if (system.isNotEmpty)
        'system': promptCaching
            ? [
                {
                  'type': 'text',
                  'text': system,
                  'cache_control': const {'type': 'ephemeral'},
                },
              ]
            : system,
      'messages': messages,
      if (request.tools.isNotEmpty)
        'tools': [
          for (final tool in request.tools) {'name': tool.name, 'description': tool.description, 'input_schema': tool.parameters},
        ],
    };
  }

  static LlmResponse parseResponse(JsonMap json) {
    final text = StringBuffer();
    final thinking = StringBuffer();
    final toolCalls = <LlmToolCall>[];
    for (final raw in json['content'] as List? ?? const []) {
      final block = asJsonMap(raw);
      switch (block['type']) {
        case 'text':
          text.write(block['text'] as String? ?? '');
        case 'thinking':
          thinking.write(block['thinking'] as String? ?? '');
        case 'tool_use':
          toolCalls.add(LlmToolCall(id: block['id'] as String, name: block['name'] as String, arguments: asJsonMap(block['input'])));
      }
    }
    final usage = asJsonMap(json['usage']);
    return LlmResponse(
      text: text.toString(),
      thinking: thinking.isEmpty ? null : thinking.toString(),
      toolCalls: toolCalls,
      usage: LlmUsage(
        // Anthropic reports cache reads and writes outside input_tokens; the
        // port's contract is that cached tokens are part of the prompt count.
        promptTokens:
            ((usage['input_tokens'] as num?)?.toInt() ?? 0) +
            ((usage['cache_read_input_tokens'] as num?)?.toInt() ?? 0) +
            ((usage['cache_creation_input_tokens'] as num?)?.toInt() ?? 0),
        completionTokens: (usage['output_tokens'] as num?)?.toInt() ?? 0,
        cachedPromptTokens: (usage['cache_read_input_tokens'] as num?)?.toInt() ?? 0,
        cacheWriteTokens: (usage['cache_creation_input_tokens'] as num?)?.toInt() ?? 0,
      ),
      model: json['model'] as String? ?? '',
      stopReason: json['stop_reason'] as String?,
    );
  }
}
