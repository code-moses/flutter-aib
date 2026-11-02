import 'dart:io';

import 'package:aib_agents/aib_agents.dart';
import 'package:aib_agents/testing.dart';
import 'package:aib_core/ports.dart';
import 'package:test/test.dart';

LlmRequest _ask(String text) => LlmRequest(messages: [LlmMessage.system('sys'), LlmMessage.user(text)]);

/// Fails with [kind] every time.
final class _Down implements LlmClient {
  _Down(this.model, this.kind);

  @override
  final String model;
  final LlmErrorKind kind;
  var calls = 0;

  @override
  Future<LlmResponse> complete(LlmRequest request, {CancellationToken? cancellation}) async {
    calls++;
    throw LlmClientException('$model is down', kind: kind);
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('aib_cassette'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('cassette', () {
    test('records, then replays without asking the model, in recorded order', () async {
      final path = '${dir.path}/llm/cassette.jsonl';
      final model = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([
            ('done', {'summary': 'first'}),
          ]),
          const LlmResponse(text: 'second', stopReason: 'stop', thinking: 'hm'),
        ],
      );
      final recording = CassetteLlmClient.wrap(model, path: path);
      await recording.complete(_ask('a'));
      await recording.complete(_ask('a'));
      expect(File(path).readAsLinesSync(), hasLength(2));

      final silent = FakeLlmClient();
      final replay = CassetteLlmClient.wrap(silent, path: path, mode: .replay) as CassetteLlmClient;
      final first = await replay.complete(_ask('a'));
      final second = await replay.complete(_ask('a'));
      // Past the last recording, the last one again.
      final third = await replay.complete(_ask('a'));
      expect(silent.requests, isEmpty);
      expect(first.toolCalls.single.arguments, {'summary': 'first'});
      expect(first.usage.promptTokens, 100);
      expect((second.text, second.stopReason, second.thinking), ('second', 'stop', 'hm'));
      expect(third.text, 'second');
      expect((await replay.modelIdentity())['cassette'], {'path': path, 'mode': 'replay'});

      // A request the cassette does not hold is an error a strict replay
      // classifies, never a call to the model.
      await expectLater(replay.complete(_ask('b')), throwsA(isA<LlmClientException>()));
      expect(silent.requests, isEmpty);
    });

    test('replayThenLive goes live from the first request it does not hold, and records it', () async {
      final path = '${dir.path}/c.jsonl';
      await CassetteLlmClient.wrap(
        FakeLlmClient(responses: [const LlmResponse(text: 'old')]),
        path: path,
      ).complete(_ask('a'));

      final model = FakeLlmClient(responses: [const LlmResponse(text: 'new')]);
      final client = CassetteLlmClient.wrap(model, path: path, mode: .replayThenLive) as CassetteLlmClient;
      expect((await client.complete(_ask('a'))).text, 'old');
      expect((await client.complete(_ask('changed'))).text, 'new');
      expect((client.replayed, client.live), (1, 1));
      expect(File(path).readAsLinesSync(), hasLength(2));
    });

    test('the key covers the whole request', () {
      String key(LlmRequest r) => CassetteLlmClient.requestKey(r, model: 'm');
      final base = _ask('a');
      expect(key(base), key(_ask('a')));
      expect(key(base), isNot(key(_ask('b'))));
      expect(
        key(base),
        isNot(
          key(
            LlmRequest(
              messages: base.messages,
              tools: const [LlmTool(name: 't', description: 'd')],
            ),
          ),
        ),
      );
      expect(key(base), isNot(CassetteLlmClient.requestKey(base, model: 'other')));
    });

    test('from an agent config, outside the arm\'s identity', () {
      final path = '${dir.path}/x.jsonl';
      final config = {
        'llm': {'provider': 'ollama', 'model': 'gemma4:26b'},
        'cassette': {'path': path, 'mode': 'record'},
      };
      expect(LlmClientFactory.fromConfig(config), isA<CassetteLlmClient>());
      expect(LlmClientFactory.otherSections(config), isNot(contains('cassette')));
      expect(
        () => LlmClientFactory.fromConfig({
          ...config,
          'cassette': {'path': path, 'mode': 'rewind'},
        }),
        throwsFormatException,
      );
    });
  });

  group('fallback chain', () {
    test('an outage moves down the chain and says so; the answer is priced at who gave it', () async {
      final primary = _Down('claude-sonnet-5', LlmErrorKind.server);
      final local = FakeLlmClient(
        model: 'gemma4:26b',
        responses: [const LlmResponse(text: 'ok')],
      );
      final chain = FallbackLlmClient([primary, local]);
      expect(chain.model, 'claude-sonnet-5');

      final response = await chain.complete(_ask('a'));
      expect(response.text, 'ok');
      expect(response.model, 'gemma4:26b');
      expect(chain.model, 'gemma4:26b');
      expect(chain.takeFallbacks(), ['claude-sonnet-5: server']);
      expect(chain.takeFallbacks(), isEmpty, reason: 'cleared by reading');
    });

    test('what is the model\'s fault does not move: the agent hears it', () async {
      final primary = _Down('a', LlmErrorKind.contextLength);
      final next = FakeLlmClient(responses: [const LlmResponse(text: 'never')]);
      await expectLater(FallbackLlmClient([primary, next]).complete(_ask('a')), throwsA(isA<LlmClientException>()));
      expect(next.requests, isEmpty);
    });

    test('the last link\'s failure is the chain\'s', () async {
      await expectLater(
        FallbackLlmClient([_Down('a', LlmErrorKind.server), _Down('b', LlmErrorKind.transport)]).complete(_ask('a')),
        throwsA(isA<LlmClientException>().having((e) => e.kind, 'kind', LlmErrorKind.transport)),
      );
    });

    test('from an llm block; faults fail the first model only', () async {
      final client = LlmClientFactory.fromConfig({
        'llm': {
          'provider': 'ollama',
          'model': 'gemma4:26b',
          'fallback': [
            {'provider': 'ollama', 'model': 'gemma4:e4b'},
          ],
          'fallbackOn': ['server'],
        },
      });
      expect(client, isA<FallbackLlmClient>());
      final chain = client as FallbackLlmClient;
      expect([for (final c in chain.chain) c.model], ['gemma4:26b', 'gemma4:e4b']);
      expect(chain.on, {LlmErrorKind.server});
      expect(
        () => LlmClientFactory.fromConfig({
          'llm': {
            'provider': 'ollama',
            'model': 'm',
            'fallbackOn': ['server'],
          },
        }),
        throwsArgumentError,
      );

      final faulted = LlmClientFactory.fromConfig({
        'llm': {
          'provider': 'ollama',
          'model': 'gemma4:26b',
          'fallback': [
            {'provider': 'ollama', 'model': 'gemma4:e4b'},
          ],
        },
        'faults': {'llmFailureRate': 1.0},
      });
      final links = (faulted as FallbackLlmClient).chain;
      expect(links.first, isA<FaultInjectingLlmClient>());
      expect(links.last, isA<OllamaClient>());
    });

    test('the agent records which model answered after a fallback', () async {
      final chain = FallbackLlmClient([
        _Down('cloud', LlmErrorKind.timeout),
        FakeLlmClient(
          model: 'local',
          responses: [
            FakeLlmClient.calls([
              ('done', {'summary': 'ok'}),
            ]),
          ],
        ),
      ]);
      final agent = HybridAgent(client: chain);
      await agent.startEpisode(
        const TaskSpec(
          id: 't',
          title: 't',
          instruction: 'x',
          fixture: FixtureRef(id: 'f', data: {}),
          budget: Budget(maxSteps: 5, maxWallClockSeconds: 60),
        ),
        const EnvironmentDescriptor(
          environmentId: 'e',
          envelopes: [EnvelopeSpec(key: 'intents.catalog', kind: .observe)],
        ),
      );
      const budget = BudgetStatus(stepsUsed: 0, maxSteps: 5, elapsedMs: 0, maxWallClockMs: 60000, tokensUsed: 0);
      await agent.next(null, budget);
      final done = await agent.next(EnvelopeResult.ok(), budget);
      final call = (done.decision!.extra!['llm'] as List).single as Map;
      expect(call['fallbacks'], ['cloud: timeout']);
      expect(call['answeredBy'], 'local');
      expect(done.decision!.model, 'local');
    });
  });
}
