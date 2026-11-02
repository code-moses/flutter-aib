import 'dart:convert';

import 'package:aib_agents/aib_agents.dart';
import 'package:aib_agents/testing.dart';
import 'package:aib_core/ports.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const _task = TaskSpec(
  id: 't1',
  title: 'route me',
  instruction: 'create a customer named Ada',
  fixture: FixtureRef(id: 'fx', data: {}),
  budget: Budget(maxSteps: 10, maxWallClockSeconds: 60),
);

const _descriptor = EnvironmentDescriptor(
  environmentId: 'env',
  envelopes: [
    EnvelopeSpec(key: 'intents.catalog', kind: .observe),
    EnvelopeSpec(key: 'intents.invoke', kind: .act),
  ],
);

const _budget = BudgetStatus(stepsUsed: 0, maxSteps: 10, elapsedMs: 0, maxWallClockMs: 60000, tokensUsed: 0);

ModelRouter _router(RouteDecider decider, {FakeLlmClient? local}) => ModelRouter(
  local:
      local ??
      FakeLlmClient(
        model: 'qwen3:8b',
        responses: [
          FakeLlmClient.calls([
            ('ask_user', {'type': 'text', 'prompt': '?'}),
          ]),
        ],
      ),
  cloud: FakeLlmClient(
    model: 'claude-sonnet-5',
    responses: [
      FakeLlmClient.calls([
        ('ask_user', {'type': 'text', 'prompt': '?'}),
      ]),
    ],
  ),
  decider: decider,
  cloudSupportsTemperature: false,
);

void main() {
  group('RouteDecider', () {
    test('rules: long or matching instructions go to the cloud', () async {
      final rules = RuleRouteDecider(maxLocalWords: 5, cloudPatterns: [r'\bunless\b']);
      expect((await rules.decide('add a note')).route, ModelRoute.local);
      expect((await rules.decide('one two three four five six')).reason, 'words=6>5');
      expect((await rules.decide('Do it UNLESS')).route, ModelRoute.cloud);
    });

    test('jev: p(local) against the threshold, model recorded', () async {
      final jev = FakeJevClient(model: 'jev-1.13.0', probabilities: {'local': 0.4, 'cloud': 0.6});
      final low = await JevRouteDecider(client: jev).decide('x');
      expect(low.route, ModelRoute.cloud);
      expect(low.probabilityLocal, 0.4);
      expect(low.deciderModel, 'jev-1.13.0');

      final lenient = await JevRouteDecider(client: jev, threshold: 0.3).decide('x');
      expect(lenient.route, ModelRoute.local);

      final question = jev.requests.first.questions['route']! as JevChoice;
      expect(question.options, ['local', 'cloud']);
      expect((jev.requests.first.state as JevText).text, 'x');
    });

    test('self: only a clear LOCAL stays local', () async {
      Future<ModelRoute> answer(String text) async => (await SelfAssessRouteDecider(
        client: FakeLlmClient(responses: [LlmResponse(text: text)]),
      ).decide('x')).route;
      expect(await answer(' local.'), ModelRoute.local);
      expect(await answer('CLOUD'), ModelRoute.cloud);
      expect(await answer('I think I could'), ModelRoute.cloud);
    });
  });

  group('ModelRouter', () {
    test('a failing decider falls back to onError and says so', () async {
      final router = _router(JevRouteDecider(client: FakeJevClient(error: const LlmClientException('down'))));
      final decision = await router.beginEpisode('x');
      expect(decision.route, ModelRoute.cloud);
      expect(decision.fallback, isTrue);
      expect(decision.reason, contains('down'));
    });

    test('names both sides between episodes, the active one inside', () async {
      final router = _router(const FixedRouteDecider(ModelRoute.local));
      expect(router.model, 'qwen3:8b|claude-sonnet-5');
      await router.beginEpisode('x');
      expect(router.model, 'qwen3:8b');
      router.endEpisode();
      expect(router.model, 'qwen3:8b|claude-sonnet-5');
      expect(() => router.complete(const LlmRequest(messages: [])), throwsStateError);
    });

    test('drops temperature only for a side that rejects it', () async {
      final router = _router(const FixedRouteDecider(ModelRoute.cloud));
      await router.beginEpisode('x');
      await router.complete(const LlmRequest(messages: [], temperature: 0));
      final cloud = router.cloud as FakeLlmClient;
      expect(cloud.requests.single.temperature, isNull);
    });

    test('an agent records the route and the routed model', () async {
      final router = _router(JevRouteDecider(client: FakeJevClient(probabilities: {'local': 0.9, 'cloud': 0.1})));
      final agent = HybridAgent(client: router);
      await agent.startEpisode(_task, _descriptor);

      final bootstrap = await agent.next(null, _budget);
      final route = asJsonMap(bootstrap.decision!.extra!['modelRoute']);
      expect(route['route'], 'local');
      expect(route['decider'], 'jev');
      expect(route['probabilityLocal'], 0.9);

      final asked = await agent.next(EnvelopeResult.ok(), _budget);
      expect(asked.decision!.model, 'qwen3:8b');
      expect(asked.decision!.extra, isNot(contains('modelRoute')));
      expect((router.cloud as FakeLlmClient).requests, isEmpty);

      await agent.endEpisode(const EpisodeOutcome(reason: .done));
      expect(router.decision, isNull);
    });
  });

  group('LlmClientFactory.modelRouterFromConfig', () {
    test('builds both sides and the decider from one block', () {
      final client = LlmClientFactory.fromConfig({
        'modelRouter': {
          'decider': 'jev',
          'onError': 'local',
          'local': {'provider': 'ollama', 'model': 'qwen3:8b'},
          'cloud': {'provider': 'anthropic', 'model': 'claude-sonnet-5', 'supportsTemperature': false},
          'jev': {'model': 'Qwen/Qwen3.5-4B', 'threshold': 0.7},
        },
      });
      expect(client, isA<ModelRouter>());
      final router = client as ModelRouter;
      expect(router.onError, ModelRoute.local);
      expect(router.cloudSupportsTemperature, isFalse);
      expect((router.decider as JevRouteDecider).threshold, 0.7);
      // The question names the two models it is deciding between.
      final criteria = (router.decider as JevRouteDecider).criteria;
      expect(criteria['local'], contains('qwen3:8b'));
      expect(criteria['cloud'], contains('claude-sonnet-5'));
    });

    test('refuses an unknown decider and a stray llm block', () {
      expect(
        () => LlmClientFactory.fromConfig({
          'modelRouter': {'decider': 'vibes'},
        }),
        throwsFormatException,
      );
      expect(
        () => LlmClientFactory.fromConfig({
          'llm': {'provider': 'ollama', 'model': 'x'},
          'modelRouter': {'decider': 'local'},
        }),
        throwsArgumentError,
      );
    });

    test('jev can run locally through Ollama, and ask in the task\'s language', () async {
      final client =
          LlmClientFactory.fromConfig({
                'modelRouter': {
                  'decider': 'jev',
                  'local': {'provider': 'ollama', 'model': 'qwen3:1.7b'},
                  'cloud': {'provider': 'ollama', 'model': 'qwen3:8b'},
                  'jev': {'backend': 'ollama', 'model': 'qwen3:4b', 'template': 'v1-noul-decimal', 'language': 'auto'},
                },
              })
              as ModelRouter;
      final decider = client.decider as JevRouteDecider;
      expect(decider.client, isA<LogitJevClient>());
      expect((decider.client as LogitJevClient).template, JevTemplate.v1NoulDecimal);
      expect(decider.language.name, 'auto');
      expect(decider.translations['de']!.criteria['local'], contains('qwen3:1.7b'));
    });

    test('a German task gets the German question under language: auto, and every route records the task language', () async {
      final jev = FakeJevClient(probabilities: {'local': 0.8, 'cloud': 0.2});
      final decider = JevRouteDecider(
        client: jev,
        language: const JevLanguagePolicy.matchState(),
        translations: {'de': JevRouteDecider.germanFor(localModel: 'klein', cloudModel: 'groß')},
      );
      final router = _router(decider);

      final german = await router.beginEpisode('Lösche alle erledigten Aufgaben.');
      final asked = jev.requests.last.questions['route']! as JevChoice;
      expect(asked.instructions, startsWith('Der Zustand ist eine Aufgabe'));
      expect(asked.criteria['local'], contains('klein'));
      expect(german.language, 'de');
      expect(german.askedIn, 'de');
      expect(german.toJson(), containsPair('language', 'de'));
      router.endEpisode();

      final english = await router.beginEpisode('Mark the todo "Existing" as completed.');
      expect((jev.requests.last.questions['route']! as JevChoice).instructions, JevRouteDecider.defaultInstructions);
      expect(english.language, 'en');
      expect(english.askedIn, 'en');
      router.endEpisode();

      // The default asks in English whatever the task says — what every run so far measured.
      final fixed = await JevRouteDecider(client: jev).decide('Lösche alle erledigten Aufgaben.');
      expect(fixed.askedIn, 'en');
      expect((jev.requests.last.questions['route']! as JevChoice).instructions, JevRouteDecider.defaultInstructions);
    });

    test('a jev needs its model id, self-hosted or hosted', () {
      expect(() => LlmClientFactory.jevFromConfig({}), throwsArgumentError);
      expect(() => LlmClientFactory.jevFromConfig({'baseUrl': HttpJevClient.hostedBaseUrl}), throwsArgumentError);
      expect(LlmClientFactory.jevFromConfig({'baseUrl': HttpJevClient.hostedBaseUrl, 'model': 'jev-latest'}), isA<HttpJevClient>());
    });
  });

  group('HttpJevClient', () {
    test('speaks the System One shape and reads simple-jev\'s answer', () async {
      late JsonMap sent;
      late http.Request raw;
      final client = HttpJevClient(
        model: 'Qwen/Qwen3.5-4B',
        apiKey: 'k',
        httpClient: MockClient((request) async {
          raw = request;
          sent = asJsonMap(jsonDecode(request.body));
          return http.Response(
            jsonEncode({
              'model': 'Qwen/Qwen3.5-4B',
              'answers': {
                'route': {
                  'type': 'choice',
                  'choice': 'local',
                  'confidence': 0.8,
                  'probabilities': {'local': 0.8, 'cloud': 0.2},
                },
                'done': {'type': 'noul', 'noul': 0.93},
              },
              'usage': {'input_tokens': 120, 'output_tokens': 0},
            }),
            200,
          );
        }),
      );
      final response = await client.decide(
        const JevRequest(
          state: JevState.text('task'),
          questions: {
            'route': JevChoice(instructions: 'which?', criteria: {'local': null, 'cloud': 'hard'}),
            'done': JevNoul(instructions: 'is it done?', ifTrue: 'saved'),
          },
        ),
      );

      expect(raw.url.toString(), 'http://127.0.0.1:8000/v1/systemone');
      expect(raw.headers['authorization'], 'Bearer k');
      expect(sent['model'], 'Qwen/Qwen3.5-4B');
      expect(asJsonMap(sent['questions'])['done'], {
        'type': 'noul',
        'instructions': 'is it done?',
        'criteria': {'true': 'saved'},
      });
      expect(response.answer<JevChoiceAnswer>('route').probabilityOf('local'), 0.8);
      expect(response.answer<JevNoulAnswer>('done').noul, 0.93);
      expect(response.usage.inputTokens, 120);
    });

    test('takes the hosted API\'s per-answer model', () {
      final response = HttpJevClient(model: '').parseResponse({
        'answers': {
          'route': {'choice': 'cloud', 'model': 'jev-1.13.0'},
        },
      });
      expect(response.model, 'jev-1.13.0');
      expect(response.answer<JevChoiceAnswer>('route').choice, 'cloud');
    });

    test('a 422 is a bad request, not retried', () async {
      var calls = 0;
      final client = HttpJevClient(
        model: 'm',
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('{"error":{"message":"Loaded model"}}', 422);
        }),
      );
      await expectLater(
        client.decide(
          const JevRequest(
            state: JevState.text('s'),
            questions: {'q': JevNoul(instructions: '?')},
          ),
        ),
        throwsA(isA<LlmClientException>().having((e) => e.kind, 'kind', LlmErrorKind.badRequest)),
      );
      expect(calls, 1);
    });
  });
}
