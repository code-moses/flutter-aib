import 'dart:convert';

import 'package:aib_agents/aib_agents.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const _tool = LlmTool(name: 'tap', description: 'Tap.', parameters: {'type': 'object'});

LlmRequest _request({JsonMap? schema}) => LlmRequest(
  messages: [LlmMessage.system('s'), LlmMessage.user('u')],
  tools: const [_tool],
  temperature: 0,
  maxTokens: 256,
  parallelToolCalls: false,
  responseSchema: schema,
);

void main() {
  group('LlamaCppClient', () {
    test('request: max_tokens, cache_prompt, no streaming, tools kept', () {
      final body = LlamaCppClient(model: 'gemma4:26b').buildBody(_request());
      expect(body['max_tokens'], 256);
      expect(body.containsKey('max_completion_tokens'), isFalse);
      expect(body['cache_prompt'], isTrue);
      expect(body['stream'], isFalse);
      expect(body['temperature'], 0);
      expect(body['parallel_tool_calls'], isFalse);
      expect(body['tools'], hasLength(1));
      expect(body.containsKey('chat_template_kwargs'), isFalse, reason: 'think unset leaves the template default');
    });

    test('an empty assistant turn is sent with empty content, not with neither field', () {
      final request = LlmRequest(
        messages: [LlmMessage.system('s'), LlmMessage.user('u'), LlmMessage.assistant(''), LlmMessage.user('go on')],
        tools: const [_tool],
      );
      final assistant = (LlamaCppClient(model: 'm').buildBody(request)['messages'] as List)
          .map(asJsonMap)
          .firstWhere((m) => m['role'] == 'assistant');
      expect(assistant['content'], '');
    });

    test('think maps to the template, not to a server flag', () {
      expect(LlamaCppClient(model: 'm', think: false).buildBody(_request())['chat_template_kwargs'], {'enable_thinking': false});
      expect(LlamaCppClient(model: 'm', think: true).buildBody(_request())['chat_template_kwargs'], {'enable_thinking': true});
      expect(LlamaCppClient(model: 'm', think: 'low').buildBody(_request())['chat_template_kwargs'], {'reasoning_effort': 'low'});
    });

    test('a response schema becomes response_format', () {
      final body = LlamaCppClient(model: 'm').buildBody(_request(schema: const {'type': 'object'}));
      expect(asJsonMap(body['response_format'])['type'], 'json_schema');
      expect(LlamaCppClient(model: 'm').supportsResponseSchema, isTrue);
    });

    test('response: tool call, timings give cache hit and time to first token', () async {
      final client = LlamaCppClient(
        model: 'm',
        httpClient: MockClient((request) async {
          expect(request.url.path, '/v1/chat/completions');
          return http.Response(
            jsonEncode({
              'model': 'gemma-4',
              'choices': [
                {
                  'finish_reason': 'tool_calls',
                  'message': {
                    'content': '',
                    'reasoning_content': 'hm',
                    'tool_calls': [
                      {
                        'id': 'x',
                        'type': 'function',
                        'function': {'name': 'tap', 'arguments': '{"label":"A"}'},
                      },
                    ],
                  },
                },
              ],
              'usage': {'prompt_tokens': 900, 'completion_tokens': 12},
              'timings': {'cache_n': 800, 'prompt_ms': 123.6},
            }),
            200,
          );
        }),
      );
      final response = await client.complete(_request());
      expect(response.toolCalls.single.arguments, {'label': 'A'});
      expect(response.thinking, 'hm');
      expect(response.usage.promptTokens, 900);
      expect(response.usage.cachedPromptTokens, 800);
      expect(response.firstTokenMs, 124);
    });

    test('identity reads the GGUF, its digest and the slot context from /props', () async {
      final client = LlamaCppClient(
        model: 'gemma4:26b',
        httpClient: MockClient((request) async {
          expect(request.url.path, '/props');
          return http.Response(
            jsonEncode({
              'model_path': '/Users/x/.ollama/models/blobs/sha256-abc123',
              'build_info': 'b11429-d812350',
              'total_slots': 1,
              'default_generation_settings': {'n_ctx': 32768},
            }),
            200,
          );
        }),
      );
      final identity = await client.modelIdentity();
      expect(identity['digest'], 'abc123');
      expect(identity['ctxPerSlot'], 32768);
      expect(identity['provider'], 'llamacpp');
    });

    test('warmUp refuses a server that gives a request less context than the arm expects', () async {
      final client = LlamaCppClient(
        model: 'm',
        contextTokens: 32768,
        httpClient: MockClient((request) async {
          if (request.url.path == '/health') return http.Response('{"status":"ok"}', 200);
          return http.Response(
            jsonEncode({
              'default_generation_settings': {'n_ctx': 8192},
            }),
            200,
          );
        }),
      );
      expect(client.warmUp, throwsA(isA<LlmClientException>()));
    });

    test('warmUp refuses a model whose chat template renders no tools', () async {
      final client = LlamaCppClient(
        model: 'm',
        httpClient: MockClient((request) async {
          if (request.url.path == '/health') return http.Response('{"status":"ok"}', 200);
          return http.Response(
            jsonEncode({
              'default_generation_settings': {'n_ctx': 32768},
              'chat_template_caps': {'supports_tools': false},
            }),
            200,
          );
        }),
      );
      expect(client.warmUp, throwsA(isA<LlmClientException>()));
    });

    test('the factory builds it from provider: llamacpp', () {
      final client = LlmClientFactory.fromConfig({
        'llm': {'provider': 'llamacpp', 'model': 'qwen3.5:9b', 'baseUrl': 'http://localhost:8081', 'contextTokens': 16384, 'think': false},
      });
      expect(client, isA<LlamaCppClient>());
      expect((client as LlamaCppClient).baseUrl, 'http://localhost:8081');
      expect(client.contextTokens, 16384);
    });
  });
}
