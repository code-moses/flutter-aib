import 'dart:convert';

import 'package:aib_jev/aib_jev.dart';
import 'package:aib_jev/testing.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// A client whose backend answers with [reply], recording what was sent.
({HttpJevClient client, List<JsonMap> sent}) _client(JsonMap reply, {String model = 'Qwen/Qwen3.5-4B', int status = 200}) {
  final sent = <JsonMap>[];
  return (
    sent: sent,
    client: HttpJevClient(
      model: model,
      httpClient: MockClient((request) async {
        sent.add(asJsonMap(jsonDecode(request.body)));
        return http.Response(jsonEncode(reply), status);
      }),
    ),
  );
}

void main() {
  group('state', () {
    test('text, JSON and chat are the three shapes the contract allows', () {
      final client = HttpJevClient(model: 'm');
      expect(
        client.buildBody(
          const JevRequest(
            state: JevState.text('hello'),
            questions: {'q': JevNoul(instructions: '?')},
          ),
        )['state'],
        'hello',
      );
      expect(
        client.buildBody(
          const JevRequest(
            state: JevState.json({'open': 3}),
            questions: {'q': JevNoul(instructions: '?')},
          ),
        )['state'],
        {'open': 3},
      );
      final chat = client.buildBody(
        const JevRequest(
          state: JevState.chat([JevMessage.user('can you delete it?'), JevMessage.assistant('deleted')]),
          questions: {'q': JevNoul(instructions: '?')},
        ),
      );
      expect(chat.containsKey('state'), isFalse, reason: 'exactly one context');
      expect(chat['messages'], [
        {'role': 'user', 'content': 'can you delete it?'},
        {'role': 'assistant', 'content': 'deleted'},
      ]);
    });

    test('an image rides as a content part', () {
      final body = HttpJevClient(model: 'm').buildBody(
        JevRequest(
          state: JevState.chat([
            JevMessage(
              role: .user,
              parts: [
                const JevPart.text('is the form valid?'),
                JevImagePart.bytes(const [1, 2, 3], mediaType: 'image/png'),
              ],
            ),
          ]),
          questions: const {'q': JevNoul(instructions: '?')},
        ),
      );
      final parts = (body['messages'] as List).first as JsonMap;
      expect((parts['content'] as List).first, {'type': 'text', 'text': 'is the form valid?'});
      expect(asJsonMap((parts['content'] as List).last)['image_url'], {
        'url': 'data:image/png;base64,${base64Encode(const [1, 2, 3])}',
      });
    });
  });

  group('questions', () {
    test('a score question sends its rubric as an ordered array', () {
      final body = HttpJevClient(model: 'm').buildBody(
        const JevRequest(
          state: JevState.text('s'),
          questions: {
            'urgency': JevScore(instructions: 'How urgent?', levels: ['low', 'medium', 'high']),
          },
        ),
      );
      expect(asJsonMap(body['questions'])['urgency'], {
        'type': 'score',
        'instructions': 'How urgent?',
        'criteria': ['low', 'medium', 'high'],
      });
    });

    test('structured instructions replace the text form', () {
      final body = HttpJevClient(model: 'm').buildBody(
        const JevRequest(
          state: JevState.text('s'),
          questions: {
            'q': JevNoul(instructions: 'ignored', structured: JevPrompt.json({'rule': 'no deletions'})),
          },
        ),
      );
      expect(asJsonMap(asJsonMap(body['questions'])['q'])['instructions'], {'rule': 'no deletions'});
    });

    test('options and unknown top-level fields travel', () {
      final body = HttpJevClient(model: 'm').buildBody(
        const JevRequest(
          state: JevState.text('s'),
          questions: {'q': JevNoul(instructions: '?')},
          options: JevOptions(rawLogits: true, extra: {'future_knob': 1}),
          extra: {'tenant': 'acme'},
        ),
      );
      expect(body['options'], {'raw_logits': true, 'future_knob': 1});
      expect(body['tenant'], 'acme');
    });
  });

  group('answers', () {
    test('choice keeps the ranking, the margin and the ties', () {
      final answer = JevAnswer.fromJson(const {
        'type': 'choice',
        'choice': 'billing',
        'confidence': 0.6,
        'probabilities': {'billing': 0.6, 'tech': 0.3, 'other': 0.1},
        'margin': 0.3,
        'ties': ['billing'],
        'calibrated': false,
        'scoring': 'direct_label_logits',
      });
      expect(answer, isA<JevChoiceAnswer>());
      final choice = answer as JevChoiceAnswer;
      expect(choice.top(2), ['billing', 'tech']);
      expect(choice.margin, 0.3);
      expect(choice.ties, ['billing']);
      expect(choice.calibrated, isFalse);
      expect(choice.scoring, 'direct_label_logits');
      expect(choice.probabilityOf('nope'), 0);
    });

    test('score reads its legend, its level and a 0–1 form', () {
      final score =
          JevAnswer.fromJson(const {
                'type': 'score',
                'score': 1.9,
                'confidence': 0.92,
                'probabilities': {'0': 0.02, '1': 0.06, '2': 0.92},
                'legend': {'0': 'Unsupported', '1': 'Partial', '2': 'Full'},
                'variance': 0.1,
              })
              as JevScoreAnswer;
      expect(score.level, 2);
      expect(score.levelName, 'Full');
      expect(score.normalized, closeTo(0.95, 1e-9));
      expect(score.variance, 0.1);
      expect(score.probabilities[2], 0.92);
    });

    test('a score without a legend borrows the rubric from its question', () {
      const question = JevScore(instructions: 'How urgent?', levels: ['low', 'high']);
      final answer = question.parse(const {'type': 'score', 'score': 1.0});
      expect(answer.levelName, 'high');
      expect(answer.normalized, 1.0);
    });

    test('noul exposes its rating and never claims calibration', () {
      final noul =
          JevAnswer.fromJson(const {
                'type': 'noul',
                'noul': 0.93,
                'rating': {
                  'bins': [0.1, 0.2],
                  'probabilities': [0.1, 0.9],
                  'expected_score': 0.86,
                  'entropy': 0.32,
                },
              })
              as JevNoulAnswer;
      expect(noul.isTrue(), isTrue);
      expect(noul.isTrue(threshold: 0.95), isFalse);
      expect(noul.decisiveness, closeTo(0.86, 1e-9));
      expect(noul.rating!.entropy, 0.32);
      expect(noul.confidence, isNull, reason: 'noul reports none');
    });

    test('an answer with no type is read from the field it carries', () {
      expect(JevAnswer.fromJson(const {'noul': 0.5}), isA<JevNoulAnswer>());
      expect(JevAnswer.fromJson(const {'score': 1.0}), isA<JevScoreAnswer>());
      expect(
        JevAnswer.fromJson(const {
          'probabilities': {'a': 0.9, 'b': 0.1},
        }),
        isA<JevChoiceAnswer>().having((a) => a.choice, 'argmax', 'a'),
      );
    });

    test('asking for the wrong shape is an error, not a silent coercion', () {
      final response = HttpJevClient(model: 'm').parseResponse(const {
        'answers': {
          'q': {'type': 'noul', 'noul': 0.9},
        },
      });
      expect(() => response.answer<JevChoiceAnswer>('q'), throwsA(isA<JevAnswerMismatch>()));
      expect(() => response.answer<JevNoulAnswer>('absent'), throwsA(isA<JevAnswerMissing>()));
      expect(response.answer<JevNoulAnswer>('q').noul, 0.9);
    });

    test('metadata and usage are kept for provenance', () {
      final response = HttpJevClient(model: 'm').parseResponse(const {
        'model': 'Qwen/Qwen3.5-4B',
        'answers': <String, Object?>{},
        'usage': {'input_tokens': 612, 'output_tokens': 0},
        'metadata': {'backend': 'transformers', 'template_version': 'v1', 'calibration': 'not_calibrated', 'model_revision': 'abc123'},
      });
      expect(response.usage.inputTokens, 612);
      expect(response.usage.totalTokens, 612);
      expect(response.metadata.backend, 'transformers');
      expect(response.metadata.templateVersion, 'v1');
      expect(response.metadata.modelRevision, 'abc123');
      expect(response.metadata.calibration, 'not_calibrated');
      expect(response.raw['model'], 'Qwen/Qwen3.5-4B');
    });
  });

  group('JevAsk', () {
    test('choose / judge / rate return the answer\'s own type', () async {
      final jev = FakeJevClient(probabilities: {'a': 0.7, 'b': 0.3}, noul: 0.8, score: 1.5);
      final choice = await jev.choose(state: const JevState.text('s'), instructions: 'which?', options: {'a': null, 'b': null});
      expect(choice.choice, 'a');

      final noul = await jev.judge(state: const JevState.text('s'), statement: 'is it done?');
      expect(noul.noul, 0.8);

      final score = await jev.rate(state: const JevState.text('s'), instructions: 'how urgent?', levels: ['low', 'high']);
      expect(score.score, 1.5);
    });

    test('judgeEach asks one noul per candidate in a single call', () async {
      final jev = FakeJevClient(noul: 0.6);
      final answers = await jev.judgeEach(
        state: const JevState.text('create a todo'),
        candidates: {'todo.create': 'The tool creates a todo.', 'todo.delete': 'The tool deletes a todo.'},
      );
      expect(answers.keys, ['todo.create', 'todo.delete']);
      expect(answers['todo.create']!.noul, 0.6);
      expect(jev.requests.single.questions, hasLength(2), reason: 'one request, so the shared prefix is evaluated once');
    });
  });

  group('preselection', () {
    test('judgeEach chunks past the server\'s branch cap', () async {
      final jev = FakeJevClient(noul: 0.7);
      final answers = await jev.judgeEach(
        state: const JevState.text('s'),
        candidates: {for (var i = 0; i < 120; i++) 'tool$i': 'does tool $i fit?'},
        perRequest: 50,
      );
      expect(answers, hasLength(120));
      expect(answers['tool119']!.noul, 0.7);
      expect(jev.requests.map((r) => r.questions.length), [50, 50, 20], reason: 'three calls, none over the cap');
    });

    test('shortlist keeps what clears the threshold, most true first', () async {
      final jev = _NoulPerCandidate({'a': 0.9, 'b': 0.2, 'c': 0.7});
      expect(await jev.shortlist(state: const JevState.text('s'), candidates: {'a': 'a?', 'b': 'b?', 'c': 'c?'}), ['a', 'c']);
      expect(await jev.shortlist(state: const JevState.text('s'), candidates: {'a': 'a?', 'b': 'b?', 'c': 'c?'}, topK: 1), ['a']);
    });
  });

  group('typed handles', () {
    test('an answer comes back as the type its question promised', () async {
      final questions = JevQuestionSet();
      final route = questions.add('route', const JevChoice(instructions: 'which?', criteria: {'local': null, 'cloud': null}));
      final done = questions.add('done', const JevNoul(instructions: 'is it done?'));
      final response = await FakeJevClient(
        probabilities: {'local': 0.9, 'cloud': 0.1},
        noul: 0.7,
      ).decide(JevRequest.of(state: const JevState.text('s'), questions: questions));

      // No casts, no string keys: the handles carry the answer types.
      final JevChoiceAnswer chosen = response.get(route);
      final JevNoulAnswer finished = response.get(done);
      expect(chosen.choice, 'local');
      expect(finished.noul, 0.7);
    });

    test('the same id twice is refused, not silently overwritten', () {
      final questions = JevQuestionSet()..add('q', const JevNoul(instructions: 'a'));
      expect(() => questions.add('q', const JevNoul(instructions: 'b')), throwsArgumentError);
    });
  });

  group('HttpJevClient', () {
    test('speaks the System One shape end to end', () async {
      final (:client, :sent) = _client(const {
        'model': 'Qwen/Qwen3.5-4B',
        'answers': {
          'route': {
            'type': 'choice',
            'choice': 'local',
            'confidence': 0.8,
            'probabilities': {'local': 0.8, 'cloud': 0.2},
          },
        },
        'usage': {'input_tokens': 120},
      });
      final response = await client.decide(
        const JevRequest(
          state: JevState.text('task'),
          questions: {
            'route': JevChoice(instructions: 'which?', criteria: {'local': null, 'cloud': 'hard'}),
          },
        ),
      );
      expect(sent.single['model'], 'Qwen/Qwen3.5-4B');
      expect(response.answer<JevChoiceAnswer>('route').choice, 'local');
      expect(response.model, 'Qwen/Qwen3.5-4B');
    });

    test('lists models and reads health', () async {
      var path = '';
      final client = HttpJevClient(
        model: 'm',
        httpClient: MockClient((request) async {
          path = request.url.path;
          return http.Response(path == '/health' ? '{"status":"ready","model":"m"}' : '{"data":[{"id":"m"},{"id":"other"}]}', 200);
        }),
      );
      expect(await client.models(), ['m', 'other']);
      expect((await client.health())!['status'], 'ready');
    });

    test('a hosted backend without /health says so instead of failing', () async {
      final client = HttpJevClient(
        model: 'jev-1',
        baseUrl: HttpJevClient.hostedBaseUrl,
        httpClient: MockClient((_) async => http.Response('not found', 404)),
      );
      expect(await client.health(), isNull);
    });

    test('extra headers ride along, the key stays in its own place', () async {
      late http.Request seen;
      final client = HttpJevClient(
        model: 'm',
        apiKey: 'secret',
        headers: const {'x-tenant': 'acme'},
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response('{"answers":{}}', 200);
        }),
      );
      await client.decide(
        const JevRequest(
          state: JevState.text('s'),
          questions: {'q': JevNoul(instructions: '?')},
        ),
      );
      expect(seen.headers['authorization'], 'Bearer secret');
      expect(seen.headers['x-tenant'], 'acme');
    });
  });
}

/// Answers each question with the truth configured for its candidate, in the
/// order the request lists them.
final class _NoulPerCandidate implements JevClient {
  _NoulPerCandidate(this.truths);

  final Map<String, double> truths;

  @override
  String get model => 'fake';

  @override
  Future<JevResponse> decide(JevRequest request, {CancellationToken? cancellation}) async {
    final values = truths.values.toList();
    return JevResponse(
      model: model,
      answers: {for (final (i, id) in request.questions.keys.indexed) id: JevNoulAnswer(noul: values[i])},
    );
  }
}
