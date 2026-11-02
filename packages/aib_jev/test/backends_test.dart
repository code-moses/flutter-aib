import 'dart:convert';

import 'package:aib_jev/aib_jev.dart';
import 'package:aib_jev/testing.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

JevRequest _route(String state) => JevRequest(
  state: JevState.text(state),
  questions: {
    'route': const JevChoice(instructions: 'Which model?', criteria: {'local': 'small', 'cloud': 'big'}),
    'harm': const JevNoul(instructions: 'It deletes data.'),
  },
);

/// An Ollama that answers every call with [top] as the next-token list.
({http.Client client, List<Map<String, Object?>> sent, List<String> paths}) _ollama(List<(String, double)> Function(Map<String, Object?> body) top) {
  final sent = <Map<String, Object?>>[];
  final paths = <String>[];
  return (
    sent: sent,
    paths: paths,
    client: MockClient((request) async {
      paths.add(request.url.path);
      final body = asJsonMap(jsonDecode(request.body));
      sent.add(body);
      final entries = [
        for (final (token, logprob) in top(body)) {'token': token, 'logprob': logprob},
      ];
      return http.Response(
        jsonEncode({
          'model': body['model'],
          'prompt_eval_count': 42,
          'logprobs': [
            {'token': entries.first['token'], 'logprob': entries.first['logprob'], 'top_logprobs': entries},
          ],
        }),
        200,
      );
    }),
  );
}

void main() {
  group('LogitJevClient', () {
    test('plans, reads one logit row per branch and scores like the reference', () async {
      final logits = FakeJevLogits(
        (prompt) => [for (var i = 0; i < prompt.labels.length; i++) i.toDouble()],
        renderer: JevChatFormat.qwen35.renderer,
      );
      final client = LogitJevClient(logits: logits);
      final response = await client.decide(_route('Create a customer.'));

      expect(logits.prompts, hasLength(2));
      expect(logits.prompts.first.labels, ['A', 'B']);
      expect(logits.prompts.last.labels, ['1', '2', '3', '4', '5', '6', '7', '8', '9']);
      expect(logits.rendered.first, endsWith('<|im_start|>assistant\n<think>\n\n</think>\n\n{"answer": "'));
      expect(logits.rendered.first, contains('State:\n"Create a customer."'));

      final route = response.answer<JevChoiceAnswer>('route');
      expect(route.choice, 'cloud');
      expect(route.probabilityOf('cloud'), closeTo(0.7311, 1e-4));
      expect(route.margin, closeTo(0.4621, 1e-4));
      expect(
        response.answer<JevNoulAnswer>('harm').noul,
        closeTo(0.01 + (response.answer<JevNoulAnswer>('harm').rating!.expectedScore! / 10 - 0.1) * 1.225, 1e-9),
      );
      expect(response.usage.inputTokens, 20);
      expect(response.model, 'fake-logits');
      expect(response.metadata.backend, 'fake');
      expect(response.metadata.templateVersion, 'v1-noul-decimal');
      expect(response.metadata.calibration, 'not_calibrated');
    });

    test('refuses a question with more labels than the backend can read', () async {
      final client = LogitJevClient(logits: FakeJevLogits((p) => [for (final _ in p.labels) 0.0], maxLabels: 20));
      final wide = JevRequest(
        state: const JevState.text('x'),
        questions: {
          'tool': JevChoice(instructions: 'Which tool?', criteria: {for (var i = 0; i < 21; i++) 't$i': null}),
        },
      );
      expect(() => client.decide(wide), throwsA(isA<JevUnsupported>()));
    });

    test('rejects what a server would reject with a 422, before any model call', () async {
      final logits = FakeJevLogits((p) => [for (final _ in p.labels) 0.0]);
      final client = LogitJevClient(logits: logits);
      final one = JevRequest(
        state: const JevState.text('x'),
        questions: {
          'q': const JevChoice(instructions: 'Only one?', criteria: {'a': null}),
        },
      );
      await expectLater(client.decide(one), throwsA(isA<JevRequestInvalid>()));
      await expectLater(
        client.decide(
          const JevRequest(
            state: JevState.chat([]),
            questions: {'q': JevNoul(instructions: 'x')},
          ),
        ),
        throwsA(isA<JevRequestInvalid>()),
      );
      expect(logits.prompts, isEmpty);
    });

    test('image parts are refused rather than dropped', () async {
      final client = LogitJevClient(logits: FakeJevLogits((p) => [for (final _ in p.labels) 0.0]));
      final request = JevRequest(
        state: const JevState.chat([
          JevMessage(role: .user, parts: [JevPart.image('https://example.com/x.png')]),
        ]),
        questions: {'q': const JevNoul(instructions: 'Shows a cat.')},
      );
      expect(() => client.decide(request), throwsA(isA<JevUnsupported>()));
    });

    test('cancellation stops before the next branch', () async {
      final token = CancellationToken();
      final logits = FakeJevLogits((p) {
        token.cancel();
        return [for (final _ in p.labels) 0.0];
      });
      await expectLater(LogitJevClient(logits: logits).decide(_route('x'), cancellation: token), throwsA(isA<TransportException>()));
      expect(logits.prompts, hasLength(1));
    });
  });

  test('v1-noul-decimal changes the noul answer prefix and nothing else', () {
    final request = _route('x');
    final v1 = JevTemplate.v1.plan(request);
    final decimal = JevTemplate.v1NoulDecimal.plan(request);
    expect(decimal.branches[0].answerPrefix, v1.branches[0].answerPrefix);
    expect(decimal.branches[0].instruction, v1.branches[0].instruction);
    expect(v1.branches[1].answerPrefix, '{"answer": ');
    expect(decimal.branches[1].answerPrefix, '{"answer": 0.');
    expect(decimal.branches[1].instruction, v1.branches[1].instruction);
    expect(JevTemplate.byId('v1-noul-decimal'), JevTemplate.v1NoulDecimal);
    expect(() => JevTemplate.byId('v2'), throwsFormatException);
  });

  group('readTopLogprobs', () {
    test('matches exact tokens first, then tokens with a leading space', () {
      final read = readTopLogprobs(['A', 'B'], [(' B', -0.4), ('A', -1.2), (' A', -0.1), ('The', -3.0)]);
      expect(read.logits, [-1.2, -0.4]);
      expect(read.missing, isEmpty);
    });

    test('floors a missing label below the last reported token and says so', () {
      final read = readTopLogprobs(['1', '2', '9'], [('1', -0.2), ('2', -2.0), ('x', -7.0)], missingPenalty: 1);
      expect(read.logits, [-0.2, -2.0, -8.0]);
      expect(read.missing, ['9']);
    });

    test('no label at all is an error, not a uniform answer', () {
      expect(() => readTopLogprobs(['A', 'B'], [('The', -0.1), ('I', -2.0)]), throwsA(isA<JevLabelsUnreadable>()));
    });
  });

  group('OllamaJevLogits', () {
    test('raw mode: one token, logprobs, keep_alive, the prompt rendered in Dart', () async {
      final fake = _ollama((body) => [('B', -0.4), ('A', -1.2), ('1', -2), ('9', -0.3)]);
      final logits = OllamaJevLogits(model: 'qwen3:4b', renderer: JevChatFormat.qwen3.renderer, httpClient: fake.client);
      final response = await LogitJevClient(logits: logits).decide(_route('Rename project X to Y.'));

      expect(fake.paths, ['/api/generate', '/api/generate']);
      final body = fake.sent.first;
      expect(body['raw'], isTrue);
      expect(body['logprobs'], isTrue);
      expect(body['top_logprobs'], 20);
      expect(body['keep_alive'], '30m');
      expect(asJsonMap(body['options']), {'num_predict': 1, 'temperature': 0, 'num_ctx': 8192});
      expect(body['prompt'], startsWith('<|im_start|>system\nEvaluate the provided state'));
      expect(body['prompt'], endsWith('<think>\n\n</think>\n\n{"answer": "'));

      final route = response.answer<JevChoiceAnswer>('route');
      expect(route.choice, 'cloud');
      expect(route.probabilityOf('local'), closeTo(1 / (1 + 2.2255), 1e-3));
      // Seven of nine rating bins were not reported: floored, and visible.
      expect(response.answer<JevNoulAnswer>('harm').raw['missing_labels'], ['2', '3', '4', '5', '6', '7', '8']);
      expect(response.usage.inputTokens, 84);
      expect(response.metadata.backend, 'ollama-raw');
    });

    test('chat mode prefills the answer as an assistant turn and turns thinking off', () async {
      final fake = _ollama((body) => [('A', -0.1), ('B', -3.0), ('5', -0.1)]);
      final logits = OllamaJevLogits(model: 'mistral-small', httpClient: fake.client);
      final response = await LogitJevClient(logits: logits).decide(_route('x'));

      expect(fake.paths.first, '/api/chat');
      final messages = fake.sent.first['messages']! as List;
      expect(asJsonMap(messages.last), {'role': 'assistant', 'content': '{"answer": "'});
      expect(asJsonMap(messages.first)['role'], 'system');
      expect(fake.sent.first['think'], isFalse);
      expect(response.answer<JevChoiceAnswer>('route').choice, 'local');
      expect(response.metadata.backend, 'ollama-chat');
    });

    test('auto picks the raw format a model name implies, and chat otherwise', () {
      expect(OllamaJevLogits.auto(model: 'qwen3:8b').isRaw, isTrue);
      expect(OllamaJevLogits.auto(model: 'llama3.1:8b').isRaw, isTrue);
      expect(OllamaJevLogits.auto(model: 'phi4').isRaw, isFalse);
    });

    test('a reply without logprobs is a classified error', () async {
      final client = MockClient((_) async => http.Response(jsonEncode({'model': 'm', 'response': 'B'}), 200));
      final logits = OllamaJevLogits(model: 'm', renderer: JevChatFormat.chatml.renderer, httpClient: client, retryPolicy: RetryPolicy.disabled);
      expect(
        () => LogitJevClient(logits: logits).decide(_route('x')),
        throwsA(isA<TransportException>().having((e) => e.kind, 'kind', TransportErrorKind.badRequest)),
      );
    });
  });

  group('OpenAiCompletionsJevLogits', () {
    Future<JevResponse> decideWith(Map<String, Object?> Function(List<String> labels) reply, {List<Map<String, Object?>>? sent}) {
      final client = MockClient((request) async {
        sent?.add(asJsonMap(jsonDecode(request.body)));
        return http.Response(jsonEncode(reply(const [])), 200);
      });
      final logits = OpenAiCompletionsJevLogits(
        model: 'qwen3-4b',
        renderer: JevChatFormat.qwen3.renderer,
        httpClient: client,
        backendName: 'llama-server',
      );
      return LogitJevClient(logits: logits).decide(
        JevRequest(
          state: const JevState.text('x'),
          questions: {
            'route': const JevChoice(instructions: 'Which?', criteria: {'local': null, 'cloud': null}),
          },
        ),
      );
    }

    test('reads the legacy token → logprob map and sends one greedy token', () async {
      final sent = <Map<String, Object?>>[];
      final response = await decideWith(
        (_) => {
          'model': 'qwen3-4b',
          'usage': {'prompt_tokens': 512},
          'choices': [
            {
              'text': 'A',
              'logprobs': {
                'tokens': ['A'],
                'top_logprobs': [
                  {'A': -0.2, 'B': -1.8},
                ],
              },
            },
          ],
        },
        sent: sent,
      );
      expect(sent.single, containsPair('max_tokens', 1));
      expect(sent.single, containsPair('logprobs', 20));
      expect(sent.single['prompt'], endsWith('{"answer": "'));
      expect(response.answer<JevChoiceAnswer>('route').choice, 'local');
      expect(response.usage.inputTokens, 512);
      expect(response.metadata.backend, 'llama-server');
    });

    test('reads the chat-style content list', () async {
      final response = await decideWith(
        (_) => {
          'choices': [
            {
              'logprobs': {
                'content': [
                  {
                    'token': 'B',
                    'logprob': -0.1,
                    'top_logprobs': [
                      {'token': 'B', 'logprob': -0.1},
                      {'token': 'A', 'logprob': -2.5},
                    ],
                  },
                ],
              },
            },
          ],
        },
      );
      expect(response.answer<JevChoiceAnswer>('route').choice, 'cloud');
    });

    test("reads llama.cpp's native completion_probabilities, probabilities included", () async {
      final response = await decideWith(
        (_) => {
          'completion_probabilities': [
            {
              'probs': [
                {'tok_str': 'A', 'prob': 0.25},
                {'tok_str': 'B', 'prob': 0.75},
              ],
            },
          ],
        },
      );
      expect(response.answer<JevChoiceAnswer>('route').probabilityOf('cloud'), closeTo(0.75, 1e-6));
    });
  });

  group('chat formats', () {
    const turns = [JevTurn('system', 'S\n'), JevTurn('user', 'U'), JevTurn('assistant', 'A'), JevTurn('user', 'Q')];

    test('llama3 headers', () {
      expect(
        JevChatFormat.llama3.render(turns, '{"answer": '),
        '<|start_header_id|>system<|end_header_id|>\n\nS<|eot_id|>'
        '<|start_header_id|>user<|end_header_id|>\n\nU<|eot_id|>'
        '<|start_header_id|>assistant<|end_header_id|>\n\nA<|eot_id|>'
        '<|start_header_id|>user<|end_header_id|>\n\nQ<|eot_id|>'
        '<|start_header_id|>assistant<|end_header_id|>\n\n{"answer": ',
      );
    });

    test('gemma folds the system turn into the first user turn', () {
      expect(
        JevChatFormat.gemma.render(turns, 'P'),
        '<start_of_turn>user\nS\n\nU<end_of_turn>\n<start_of_turn>model\nA<end_of_turn>\n<start_of_turn>user\nQ<end_of_turn>\n<start_of_turn>model\nP',
      );
    });

    test('qwen3 keeps contents verbatim, qwen35 trims them', () {
      expect(JevChatFormat.qwen3.render(turns.take(2).toList(), ''), startsWith('<|im_start|>system\nS\n<|im_end|>'));
      expect(JevChatFormat.qwen35.render(turns.take(2).toList(), ''), startsWith('<|im_start|>system\nS<|im_end|>'));
    });

    test('model names map to formats only where the family is unambiguous', () {
      expect(JevChatFormat.forModel('Qwen/Qwen3.5-4B'), JevChatFormat.qwen35);
      expect(JevChatFormat.forModel('qwen3:1.7b'), JevChatFormat.qwen3);
      expect(JevChatFormat.forModel('qwen2.5:7b'), JevChatFormat.chatml);
      expect(JevChatFormat.forModel('llama3.1:8b'), JevChatFormat.llama3);
      expect(JevChatFormat.forModel('gemma3:4b'), JevChatFormat.gemma);
      expect(JevChatFormat.forModel('phi4'), isNull);
      expect(() => JevChatFormat.byName('vicuna'), throwsFormatException);
    });
  });

  group('JevConfig', () {
    test('defaults to a System One server, as the existing configs expect', () {
      final client = JevConfig.clientFromJson({'baseUrl': 'http://127.0.0.1:8000', 'model': 'Qwen/Qwen3.5-4B', 'threshold': 0.5});
      expect(client, isA<HttpJevClient>());
      expect(client.model, 'Qwen/Qwen3.5-4B');
    });

    test('the hosted API reads its key through the resolver, never from the platform', () {
      final asked = <String>[];
      final client = JevConfig.clientFromJson(
        {'baseUrl': HttpJevClient.hostedBaseUrl, 'model': 'jev-latest'},
        secret: (name) {
          asked.add(name);
          return 'k';
        },
      );
      expect(client, isA<HttpJevClient>());
      expect(asked, ['TYPESAFE_API_KEY']);
      // The hosted API answers a request without a model with a 422.
      expect(() => JevConfig.clientFromJson({'baseUrl': HttpJevClient.hostedBaseUrl}), throwsArgumentError);
    });

    test('ollama and openai build logit clients with the format asked for', () {
      final ollama = JevConfig.clientFromJson({'backend': 'ollama', 'model': 'qwen3:4b'}) as LogitJevClient;
      expect((ollama.logits as OllamaJevLogits).isRaw, isTrue);
      final native = JevConfig.clientFromJson({'backend': 'ollama', 'model': 'qwen3:4b', 'format': 'native'}) as LogitJevClient;
      expect((native.logits as OllamaJevLogits).isRaw, isFalse);
      final server = JevConfig.clientFromJson({'backend': 'llama-server', 'model': 'm.gguf', 'format': 'chatml'}) as LogitJevClient;
      expect(server.logits.backend, 'llama-server');
    });

    test('refuses what it does not implement', () {
      expect(() => JevConfig.clientFromJson({'backend': 'onnx', 'model': 'm'}), throwsFormatException);
      expect(() => JevConfig.clientFromJson({'backend': 'ollama', 'model': 'qwen3:4b', 'format': 'vicuna'}), throwsFormatException);
      expect(() => JevConfig.clientFromJson({'backend': 'openai', 'model': 'phi4'}), throwsArgumentError);
      expect(() => JevConfig.clientFromJson({'backend': 'ollama'}), throwsArgumentError);
      expect(() => JevConfig.clientFromJson({'baseUrl': 'http://127.0.0.1:8000'}), throwsArgumentError);
    });
  });
}
