import 'dart:convert';

import 'package:aib_agents/aib_agents.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Conversation used for all provider mapping tests: system + user, an
/// assistant turn with two tool calls, and their two results.
final _request = LlmRequest(
  messages: [
    LlmMessage.system('You are an agent.'),
    LlmMessage.user('Do the task.'),
    LlmMessage.assistant(
      '',
      toolCalls: const [
        LlmToolCall(id: 'c1', name: 'tap', arguments: {'label': 'X'}),
        LlmToolCall(id: 'c2', name: 'tap', arguments: {'label': 'Y'}),
      ],
    ),
    LlmMessage.toolResult(callId: 'c1', name: 'tap', content: '{"ok":1}'),
    LlmMessage.toolResult(callId: 'c2', name: 'tap', content: '{"ok":2}'),
  ],
  tools: const [
    LlmTool(
      name: 'tap',
      description: 'Tap a node.',
      parameters: {
        'type': 'object',
        'properties': {
          'label': {'type': 'string'},
        },
      },
    ),
  ],
  temperature: 0,
  maxTokens: 512,
);

void main() {
  _d4();
  group('AnthropicClient', () {
    test('request mapping: system field, tool_use, merged tool_result', () {
      final body = AnthropicClient(model: 'claude-x', apiKey: 'k', promptCaching: false).buildBody(_request);
      expect(body['system'], 'You are an agent.');
      expect(body['max_tokens'], 512);
      expect((body['tools'] as List).single, {'name': 'tap', 'description': 'Tap a node.', 'input_schema': _request.tools.single.parameters});

      final messages = (body['messages'] as List).map(asJsonMap).toList();
      expect(messages, hasLength(3), reason: 'user, assistant, merged results');
      expect(messages[1]['role'], 'assistant');
      final toolUses = (messages[1]['content'] as List).map(asJsonMap);
      expect(toolUses.map((b) => b['type']), everyElement('tool_use'));
      // Both tool results merged into ONE user message (API requirement).
      expect(messages[2]['role'], 'user');
      final resultBlocks = (messages[2]['content'] as List).map(asJsonMap);
      expect(resultBlocks.map((b) => b['type']), everyElement('tool_result'));
      expect(resultBlocks.map((b) => b['tool_use_id']), ['c1', 'c2']);
    });

    test('prompt caching marks the two prefixes that get re-sent', () {
      final body = AnthropicClient(model: 'claude-x', apiKey: 'k').buildBody(_request);

      // Anthropic renders tools, then system, then messages, and a breakpoint
      // caches everything before it — so one after system covers the tools
      // too, and the system field becomes a block list to carry it.
      final system = (body['system'] as List).map(asJsonMap).toList();
      expect(system.single['text'], 'You are an agent.');
      expect(system.single['cache_control'], {'type': 'ephemeral'});

      // And one at the very end, on the history the next turn re-sends
      // verbatim before appending to it. That is the 80%.
      final messages = (body['messages'] as List).map(asJsonMap).toList();
      final lastBlocks = (messages.last['content'] as List).map(asJsonMap);
      expect(lastBlocks.last['cache_control'], {'type': 'ephemeral'});
      expect(lastBlocks.where((b) => b.containsKey('cache_control')), hasLength(1), reason: 'only the final block carries the moving breakpoint');
      // Nothing about what the model reads changed.
      expect(lastBlocks.map((b) => b['tool_use_id']), ['c1', 'c2']);
      expect(body['tools'], (AnthropicClient(model: 'claude-x', apiKey: 'k', promptCaching: false).buildBody(_request)['tools']));
    });

    test('cache reads and writes are part of the prompt count, not extra to '
        'it', () {
      final response = AnthropicClient.parseResponse(const {
        'model': 'claude-x',
        'content': [
          {'type': 'text', 'text': 'ok'},
        ],
        'usage': {'input_tokens': 100, 'cache_read_input_tokens': 8000, 'cache_creation_input_tokens': 500, 'output_tokens': 20},
      });

      // A run that reported only input_tokens would say this turn cost 100
      // prompt tokens. It cost 8 600, and the invoice says so.
      expect(response.usage.promptTokens, 8600);
      expect(response.usage.cachedPromptTokens, 8000);
      expect(response.usage.cacheWriteTokens, 500);
      expect(response.usage.completionTokens, 20);
    });

    test('complete(): endpoint, headers, response parsing', () async {
      late http.Request captured;
      final client = AnthropicClient(
        model: 'claude-x',
        apiKey: 'secret',
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'model': 'claude-x',
              'content': [
                {'type': 'text', 'text': 'ok'},
                {
                  'type': 'tool_use',
                  'id': 'toolu_1',
                  'name': 'tap',
                  'input': {'label': 'X'},
                },
              ],
              'stop_reason': 'tool_use',
              'usage': {'input_tokens': 42, 'output_tokens': 7},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final response = await client.complete(_request);
      expect(captured.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(captured.headers['x-api-key'], 'secret');
      expect(captured.headers['anthropic-version'], isNotNull);
      expect(response.text, 'ok');
      expect(response.toolCalls.single.name, 'tap');
      expect(response.toolCalls.single.arguments, {'label': 'X'});
      expect(response.usage.promptTokens, 42);
      expect(response.usage.completionTokens, 7);
    });

    test('non-200 raises LlmClientException', () async {
      final client = AnthropicClient(model: 'claude-x', apiKey: 'k', httpClient: MockClient((_) async => http.Response('overloaded', 529)));
      expect(() => client.complete(_request), throwsA(isA<LlmClientException>()));
    });
  });

  group('OpenAiClient', () {
    test('request mapping: tool_calls with JSON-string arguments', () {
      final body = OpenAiClient(model: 'gpt-x', apiKey: 'k').buildBody(_request);
      final messages = (body['messages'] as List).map(asJsonMap).toList();
      expect(messages[0], {'role': 'system', 'content': 'You are an agent.'});
      final assistant = messages[2];
      final call = asJsonMap((assistant['tool_calls'] as List).first);
      expect(call['type'], 'function');
      expect(asJsonMap(call['function'])['arguments'], '{"label":"X"}');
      expect(messages[3], {'role': 'tool', 'tool_call_id': 'c1', 'content': '{"ok":1}'});
    });

    test('response parsing decodes argument strings', () {
      final response = OpenAiClient.parseResponse(
        asJsonMap(
          jsonDecode('''
        {"model": "gpt-x",
         "choices": [{"finish_reason": "tool_calls",
           "message": {"content": null,
             "tool_calls": [{"id": "call_9", "type": "function",
               "function": {"name": "tap", "arguments": "{\\"label\\": \\"X\\"}"}}]}}],
         "usage": {"prompt_tokens": 10, "completion_tokens": 3}}
      '''),
        ),
      );
      expect(response.toolCalls.single.id, 'call_9');
      expect(response.toolCalls.single.arguments, {'label': 'X'});
      expect(response.usage.promptTokens, 10);
    });
  });

  group('OllamaClient', () {
    test('request mapping and response with synthesized call ids', () async {
      late http.Request captured;
      final client = OllamaClient(
        model: 'qwen3',
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'model': 'qwen3',
              'message': {
                'role': 'assistant',
                'content': '',
                'tool_calls': [
                  {
                    'function': {
                      'name': 'tap',
                      'arguments': {'label': 'X'},
                    },
                  },
                ],
              },
              'done_reason': 'stop',
              'prompt_eval_count': 20,
              'eval_count': 5,
            }),
            200,
          );
        }),
      );
      final response = await client.complete(_request);
      expect(captured.url.toString(), 'http://localhost:11434/api/chat');
      final body = asJsonMap(jsonDecode(captured.body));
      expect(body['stream'], false);
      expect(asJsonMap(body['options'])['temperature'], 0);
      expect(response.toolCalls.single.id, 'call_0');
      expect(response.toolCalls.single.arguments, {'label': 'X'});
      expect(response.usage.promptTokens, 20);
    });

    test('sampling options: explicit num_ctx, num_predict, think', () {
      final defaults = OllamaClient(model: 'qwen3').buildBody(_request);
      // Ollama's 4k default would silently drop the oldest messages once
      // serialized trees enter the conversation (§6.2 observation_bytes).
      expect(asJsonMap(defaults['options'])['num_ctx'], OllamaClient.defaultContextTokens);
      expect(asJsonMap(defaults['options'])['num_predict'], 512);
      expect(defaults.containsKey('think'), isFalse, reason: 'unset think leaves the model default untouched');

      final tuned = OllamaClient(model: 'qwen3', contextTokens: 8192, think: false).buildBody(_request);
      expect(asJsonMap(tuned['options'])['num_ctx'], 8192);
      expect(tuned['think'], false);
    });
  });

  group('LlmClientFactory', () {
    test('builds provider clients from declarative config', () {
      expect(LlmClientFactory.fromConfig(const {'provider': 'anthropic', 'model': 'claude-x'}), isA<AnthropicClient>());
      expect(LlmClientFactory.fromConfig(const {'provider': 'openai', 'model': 'gpt-x'}), isA<OpenAiClient>());
      final ollama = LlmClientFactory.fromConfig(const {'provider': 'ollama', 'model': 'qwen3', 'baseUrl': 'http://10.0.0.5:11434'});
      expect((ollama as OllamaClient).baseUrl, 'http://10.0.0.5:11434');
      expect(ollama.contextTokens, OllamaClient.defaultContextTokens);
      expect(ollama.think, isNull);
      final tuned =
          LlmClientFactory.fromConfig(const {'provider': 'ollama', 'model': 'qwen3', 'contextTokens': 8192, 'think': false}) as OllamaClient;
      expect(tuned.contextTokens, 8192);
      expect(tuned.think, false);
      expect(() => LlmClientFactory.fromConfig(const {'provider': 'x', 'model': 'm'}), throwsArgumentError);
      expect(() => LlmClientFactory.fromConfig(const {'provider': 'openai'}), throwsArgumentError);
    });
  });
}

void _d4() {
  group('time to first token (D4)', () {
    test('comes from Ollama\'s own timings, loading included', () {
      // A cold load really is part of what the user waits for, and it is the
      // bulk of it: 3975 ms of load against 76 ms reading the prompt on a
      // measured call.
      final response = OllamaClient.parseResponse(const {
        'message': {'content': 'hi'},
        'load_duration': 3974535250,
        'prompt_eval_duration': 76310000,
        'eval_duration': 72680000,
      });
      expect(response.firstTokenMs, 4050);
    });

    test('a warm call is just the prompt', () {
      final response = OllamaClient.parseResponse(const {
        'message': {'content': 'hi'},
        'prompt_eval_duration': 76310000,
      });
      expect(response.firstTokenMs, 76);
    });

    test('the cached prefix is reported as cached prompt tokens', () {
      // Ollama counts the cached prefix inside prompt_eval_count.
      final response = OllamaClient.parseResponse(const {
        'message': {'content': 'hi'},
        'prompt_eval_count': 499,
        'prompt_eval_cached_count': 494,
      });
      expect(response.usage.promptTokens, 499);
      expect(response.usage.cachedPromptTokens, 494);
      expect(
        OllamaClient.parseResponse(const {
          'message': {'content': 'hi'},
        }).usage.cachedPromptTokens,
        0,
      );
    });

    test('a provider that reports no timing reports no TTFT', () {
      final response = OllamaClient.parseResponse(const {
        'message': {'content': 'hi'},
      });
      expect(response.firstTokenMs, isNull);
    });
  });

  test('a 200 that is not a response is a classified server error, not a crash', () async {
    const noRetry = LlmRetryPolicy(maxAttempts: 1);
    final clients = <LlmClient Function(String body)>[
      (body) => OllamaClient(model: 'm', retryPolicy: noRetry, httpClient: MockClient((_) async => http.Response(body, 200))),
      (body) => OpenAiClient(model: 'm', apiKey: 'k', retryPolicy: noRetry, httpClient: MockClient((_) async => http.Response(body, 200))),
      (body) => AnthropicClient(model: 'm', apiKey: 'k', retryPolicy: noRetry, httpClient: MockClient((_) async => http.Response(body, 200))),
    ];
    for (final client in clients) {
      for (final body in [
        '<html>Bad gateway</html>',
        '[1]',
        jsonEncode({'message': 'not a map', 'choices': 'no', 'content': 7}),
      ]) {
        await expectLater(
          client(body).complete(_request),
          throwsA(isA<LlmClientException>().having((e) => e.kind, 'kind', LlmErrorKind.server)),
          reason: '${client(body).runtimeType}: $body',
        );
      }
    }
  });
}
