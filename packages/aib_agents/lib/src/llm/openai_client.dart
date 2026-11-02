import 'dart:convert';

import 'package:aib_core/ports.dart';
import 'package:http/http.dart' as http;

import 'llm_client.dart';
import 'llm_http.dart';

/// OpenAI Chat Completions adapter (function calling).
class OpenAiClient implements LlmClient {
  OpenAiClient({
    required this.model,
    String? apiKey,
    this.baseUrl = 'https://api.openai.com',
    this.retryPolicy = const LlmRetryPolicy(),
    http.Client? httpClient,
  }) : apiKey = apiKey ?? '',
       httpClient = httpClient ?? http.Client();

  @override
  final String model;
  final String baseUrl;
  final LlmRetryPolicy retryPolicy;

  /// Visible to subclasses (the Azure adapter differs only in URL and
  /// auth header, not in body building or parsing).
  final String apiKey;
  final http.Client httpClient;

  /// Endpoint of a chat-completions request.
  Uri get endpoint => Uri.parse('$baseUrl/v1/chat/completions');

  Map<String, String> get headers => {'content-type': 'application/json', 'authorization': 'Bearer $apiKey'};

  @override
  Future<LlmResponse> complete(LlmRequest request, {CancellationToken? cancellation}) => withRetries(
    () async => parseResponseBody(await postJson(httpClient, url: endpoint, headers: headers, body: jsonEncode(buildBody(request))), parseResponse),
    policy: retryPolicy,
    cancellation: cancellation,
  );

  JsonMap buildBody(LlmRequest request) => {
    'model': model,
    if (request.temperature != null) 'temperature': request.temperature,
    if (request.parallelToolCalls != null) 'parallel_tool_calls': request.parallelToolCalls,
    'max_completion_tokens': request.maxTokens,
    'messages': [
      for (final message in request.messages)
        switch (message.role) {
          .system => {'role': 'system', 'content': message.content},
          .user => {'role': 'user', 'content': message.content},
          .assistant => {
            'role': 'assistant',
            if (message.content.isNotEmpty) 'content': message.content,
            if (message.toolCalls.isNotEmpty)
              'tool_calls': [
                for (final call in message.toolCalls)
                  {
                    'id': call.id,
                    'type': 'function',
                    'function': {'name': call.name, 'arguments': jsonEncode(call.arguments)},
                  },
              ],
          },
          .tool => {'role': 'tool', 'tool_call_id': message.toolCallId, 'content': message.content},
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
    final choices = json['choices'] as List? ?? const [];
    if (choices.isEmpty) {
      // A provider-side condition (a content filter, an overloaded
      // deployment), not the harness: classified so it is retried and, if it
      // persists, aborts as an LLM error rather than a framework fault.
      throw LlmClientException('response without choices: ${jsonEncode(json)}', kind: LlmErrorKind.server);
    }
    final choice = asJsonMap(choices.first);
    final message = asJsonMap(choice['message']);
    final usage = asJsonMap(json['usage']);
    return LlmResponse(
      text: message['content'] as String? ?? '',
      // Not part of OpenAI's own API; servers that speak it (vLLM, llama.cpp,
      // DeepSeek-style gateways) return the reasoning under one of these.
      thinking: (message['reasoning_content'] ?? message['reasoning']) as String?,
      toolCalls: [
        for (final raw in message['tool_calls'] as List? ?? const [])
          if (asJsonMap(asJsonMap(raw)['function']) case final function)
            if (LlmToolCall.decodeArguments(function['arguments']) case final decoded)
              LlmToolCall(
                id: asJsonMap(raw)['id'] as String? ?? '',
                name: function['name'] as String? ?? '',
                arguments: decoded.arguments,
                argumentsError: decoded.error,
              ),
      ],
      usage: LlmUsage(
        promptTokens: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
        completionTokens: (usage['completion_tokens'] as num?)?.toInt() ?? 0,
        cachedPromptTokens: (asJsonMap(usage['prompt_tokens_details'])['cached_tokens'] as num?)?.toInt() ?? 0,
        reasoningTokens: (asJsonMap(usage['completion_tokens_details'])['reasoning_tokens'] as num?)?.toInt() ?? 0,
      ),
      model: json['model'] as String? ?? '',
      stopReason: choice['finish_reason'] as String?,
    );
  }
}
