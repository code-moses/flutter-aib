/// Regressions: each test failed before its fix.
library;

import 'package:aib_agents/aib_agents.dart';
import 'package:aib_agents/testing.dart';
import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

/// Answers everything with an empty ok; declares nothing but the keys the
/// semantics strategy uses.
final class _Quiet implements BenchmarkEnvironment {
  @override
  Future<EnvironmentDescriptor> describe() async => const EnvironmentDescriptor(environmentId: 'quiet');

  @override
  Future<void> reset(FixtureRef fixture) async {}

  @override
  Future<EnvelopeResult> handle(Envelope envelope) async => EnvelopeResult.ok();

  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) async => const FinalStateSnapshot(results: []);
}

EpisodeMeta _meta() =>
    EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'a', environmentId: 'quiet', repetition: 1, startedAt: DateTime.utc(2026));

TaskSpec _task({List<FollowUp> turns = const []}) => TaskSpec(
  id: 't',
  title: 't',
  instruction: 'do it',
  budget: const Budget(maxSteps: 10, maxWallClockSeconds: 60),
  fixture: const FixtureRef(id: 'f', data: {}),
  turns: turns,
);

BudgetStatus get _budget => const BudgetStatus(stepsUsed: 0, maxSteps: 10, elapsedMs: 0, maxWallClockMs: 60000, tokensUsed: 0);

void main() {
  group('a follow-up reaches the model', () {
    test('as a user message after the done call is answered', () async {
      final client = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([
            ('done', {'summary': 'first'}),
          ]),
          FakeLlmClient.calls([
            ('done', {'summary': 'second'}),
          ]),
        ],
      );
      final result = await BenchmarkEngine().runEpisode(
        task: _task(
          turns: const [FollowUp(id: 'f1', instruction: 'UND JETZT X')],
        ),
        agent: SemanticsAgent(client: client),
        environment: _Quiet(),
        meta: _meta(),
      );
      expect(result.outcome.reason, TerminationReason.done);
      expect(result.outcome.message, 'second');

      final second = client.requests[1].messages;
      final doneCall = second.lastIndexWhere((m) => m.toolCalls.any((c) => c.name == 'done'));
      // Every tool call has its result before the next user turn — the shape
      // Anthropic and OpenAI require.
      expect(second[doneCall + 1].role, LlmRole.tool);
      expect(second[doneCall + 1].toolCallId, 'fake-call-0');
      expect(second.last.role, LlmRole.user);
      expect(second.last.content, contains('UND JETZT X'));
    });
  });

  group('arguments that are not JSON', () {
    test('are parsed without throwing and told to the model', () async {
      final parsed = OpenAiClient.parseResponse({
        'choices': [
          {
            'message': {
              'tool_calls': [
                {
                  'id': 'c1',
                  'function': {'name': 'tap', 'arguments': '{"nodeId": 3'},
                },
              ],
            },
          },
        ],
      });
      expect(parsed.toolCalls.single.argumentsError, '{"nodeId": 3');
      expect(parsed.toolCalls.single.arguments, isEmpty);

      final client = FakeLlmClient(
        responses: [
          parsed,
          FakeLlmClient.calls([
            ('tap', {'nodeId': 3}),
          ]),
        ],
      );
      final agent = SemanticsAgent(client: client);
      await agent.startEpisode(_task(), await _Quiet().describe());
      await agent.next(null, _budget); // bootstrap observation
      final envelope = await agent.next(EnvelopeResult.ok(), _budget);
      expect(envelope.key, 'semantics.tap');
      expect(envelope.payload['nodeId'], 3);
      final told = client.requests[1].messages.where((m) => m.role == .tool);
      expect(told.single.content, contains('not a JSON object'));
    });

    test('a response without choices is a provider error', () {
      expect(
        () => OpenAiClient.parseResponse(const {'choices': []}),
        throwsA(isA<LlmClientException>().having((e) => e.kind, 'kind', LlmErrorKind.server)),
      );
    });
  });

  group('the observation window elides in steps', () {
    test('the stubbed prefix stays stable between steps', () async {
      final client = FakeLlmClient(
        responses: [
          for (var i = 0; i < 8; i++) FakeLlmClient.calls([('observe_tree', const {})]),
          FakeLlmClient.calls([
            ('done', {'summary': 'ok'}),
          ]),
        ],
      );
      final agent = SemanticsAgent(client: client, config: const AgentConfig(observationWindow: 2, observationStride: 3));
      await agent.startEpisode(_task(), await _Quiet().describe());
      await agent.next(null, _budget);
      for (var i = 0; i < 9; i++) {
        await agent.next(EnvelopeResult.ok({'tree': 'result $i'}), _budget);
      }
      List<String> stubbed(LlmRequest request) => [
        for (final m in request.messages)
          if (m.role == .tool && m.content.contains('elided')) m.content,
      ];
      final counts = [for (final r in client.requests) stubbed(r).length];
      // Tool results per request: 0,1,2,…; the window is 2, the stride 3, so
      // the stub count jumps in threes and never lets more than 2 stay full.
      expect(counts, [0, 0, 0, 3, 3, 3, 6, 6, 6]);
    });
  });

  group('tool names', () {
    test('stay within the providers\' limit and stay distinct', () {
      final long = 'form.${'x' * 80}.one';
      final other = 'form.${'x' * 80}.two';
      final a = IntentStrategy.toolNameFor(long);
      final b = IntentStrategy.toolNameFor(other);
      expect(a.length, lessThanOrEqualTo(64));
      expect(RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(a), isTrue);
      expect(a, isNot(b));
      expect(IntentStrategy.toolNameFor('form.open'), 'intent_form_open');
    });
  });

  group('retrieval', () {
    test('min-max normalisation gives cosine and BM25 one threshold', () {
      // Cosines of one catalogue sit close together; relative to the best
      // alone, 0.25 let all of them through.
      final kept = rankAbove({'a': 0.9, 'b': 0.62, 'c': 0.6}, 0.25);
      expect(kept, ['a']);
      expect(rankAbove({'a': 2.0, 'b': 0.0}, 0.25, requireMatch: true), ['a']);
    });

    test('BM25 statistics belong to the collection being ranked', () {
      final analyzer = TextAnalyzer(TermAnalyzer.plain);
      final rows = Bm25Index({'0': 'Kabel rot', '1': 'Kabel blau', '2': 'Patchkabel grau'}, analyzer);
      final scores = rows.bm25(['kabel', 'blau']);
      expect(scores['1']!, greaterThan(scores['0']!));
      expect(scores['2'], 0);
    });

    test('the stem analyzer joins inflections and splits compounds', () {
      expect(TextAnalyzer.stem('Anforderungen'), TextAnalyzer.stem('Anforderung'));
      final analyzer = TextAnalyzer(TermAnalyzer.stem)..vocabulary = {TextAnalyzer.stem('Anforderung')};
      expect(analyzer.query('Materialanforderungen'), contains(TextAnalyzer.stem('Anforderung')));
    });

    test('the analyzer is part of the configuration only when it differs', () {
      expect(const PreparationConfig().toJson().containsKey('analyzer'), false);
      final stem = PreparationConfig.fromJson(const {'strategy': 'lexical', 'analyzer': 'stem'});
      expect(stem.analyzer, TermAnalyzer.stem);
      expect(stem.toJson()['analyzer'], 'stem');
      expect(() => PreparationConfig.fromJson(const {'analyzer': 'snowball'}), throwsFormatException);
    });
  });

  group('the prefetch metrics', () {
    EpisodeTrace trace({
      required List<JsonMap> items,
      List<String> catalogue = const ['form.open', 'app.forms'],
      List<(String key, String kind, JsonMap payload)> later = const [],
      String strategy = 'lexical',
    }) {
      var seq = 0;
      TraceEvent event(String type, JsonMap data) => TraceEvent(seq: seq++, tUs: seq, type: type, data: data);
      return EpisodeTrace(
        meta: _meta(),
        events: [
          event(TraceEventTypes.episodeStart, {
            'agent': {
              'agentId': 'prepared',
              'metadata': {
                'preparation': {
                  'strategy': strategy,
                  'prepare': ['tools'],
                },
              },
            },
          }),
          event(TraceEventTypes.agentEnvelope, {
            'seq': 0,
            'key': 'intents.catalog',
            'kind': 'observe',
            'decision': {
              'extra': {'prefetch': true},
            },
          }),
          event(TraceEventTypes.envResult, {
            'seq': 0,
            'status': 'ok',
            'payload': {
              'intents': [
                for (final name in catalogue) {'name': name},
              ],
            },
          }),
          event(TraceEventTypes.agentEnvelope, {
            'seq': 1,
            'key': 'intents.describe',
            'kind': 'observe',
            'decision': {
              'extra': {
                'prefetch': true,
                'prepared': {'items': items},
              },
            },
          }),
          for (final (i, step) in later.indexed) ...[
            event(TraceEventTypes.agentEnvelope, {'seq': i + 2, 'key': step.$1, 'kind': step.$2, 'payload': step.$3}),
            event(TraceEventTypes.envResult, {'seq': i + 2, 'status': 'ok'}),
          ],
          event(TraceEventTypes.episodeEnd, {'reason': 'done'}),
        ],
      );
    }

    Map<String, num?> score(EpisodeTrace trace, List<String> required) {
      final registry = MetricsRegistry.builtin(providers: [prefetchMetrics]);
      return registry.computeAll(
        registry.contextFor(
          trace,
          task: TaskSpec(
            id: 't',
            title: 't',
            instruction: 'x',
            budget: const Budget(maxSteps: 1, maxWallClockSeconds: 1),
            fixture: const FixtureRef(id: 'f'),
            requiredTools: required,
          ),
        ),
      );
    }

    test('a refetched listing is matched without its fingerprint', () {
      final m = score(
        trace(
          items: [
            {'id': 'obs:intents.invoke:app.forms#abcd1234', 'bytes': 10},
          ],
          later: [
            ('intents.invoke', 'observe', {'intent': 'app.forms'}),
          ],
        ),
        const [],
      );
      expect(m['prefetch_refetch_count'], 1);
    });

    test('an active preparer that promoted nothing scores 0, not null', () {
      final m = score(trace(items: const []), const ['form.open']);
      expect(m['tool_recall_at_k'], 0);
      expect(m['tool_completeness_at_k'], 0);
    });

    test('gold the preparer could not see is counted apart', () {
      final m = score(
        trace(
          items: [
            {'id': 'tool:form.open', 'bytes': 10},
          ],
        ),
        const ['form.open', 'form.set'],
      );
      expect(m['tool_recall_at_k'], 1);
      expect(m['tool_completeness_at_k'], 1);
      expect(m['tool_gold_out_of_scope'], 1);
    });

    test('described tools share the digest\'s bytes', () async {
      final app = _DescribeApp();
      final agent = PreparingAgent(
        client: FakeLlmClient(
          responses: [
            FakeLlmClient.calls([
              ('done', {'summary': 'ok'}),
            ]),
          ],
        ),
        preparation: const PreparationConfig(strategy: .rules, topK: 3, minScore: 0),
      );
      final result = await BenchmarkEngine().runEpisode(
        task: const TaskSpec(
          id: 't',
          title: 't',
          instruction: 'open form set form',
          budget: Budget(maxSteps: 5, maxWallClockSeconds: 30),
          fixture: FixtureRef(id: 'f', data: {}),
        ),
        agent: agent,
        environment: app,
        meta: _meta(),
      );
      final prepared = [
        for (final e in result.trace.byType(TraceEventTypes.agentEnvelope))
          ...?(asJsonMap(asJsonMap(asJsonMap(e.data['decision'])['extra'])['prepared'])['items'] as List?)?.map(asJsonMap),
      ];
      final digest = [
        for (final e in result.trace.byType(TraceEventTypes.agentEnvelope))
          if (asJsonMap(asJsonMap(asJsonMap(e.data['decision'])['extra'])['prepared'])['bytes'] case final num bytes) bytes,
      ].single;
      final total = prepared.fold<num>(0, (s, i) => s + (i['bytes'] as num));
      expect(prepared.length, greaterThan(1));
      expect(total, lessThanOrEqualTo(digest));
    });
  });

  group('the simulated user picks whole options', () {
    test('"Jahr" is not "Ja", and the longer option wins', () async {
      LlmUserSimulator user(String reply) =>
          LlmUserSimulator(
            client: FakeLlmClient(responses: [LlmResponse(text: reply)]),
          )..beginEpisode(
            const TaskSpec(
              id: 't',
              title: 't',
              instruction: 'x',
              budget: Budget(maxSteps: 1, maxWallClockSeconds: 1),
              fixture: FixtureRef(id: 'f'),
              userSimulator: UserSimulatorSpec(goal: 'g'),
            ),
          );
      expect(
        await user('Das Jahr').answer({
          'type': 'choice',
          'prompt': '?',
          'options': ['Ja', 'Nein'],
        }),
        'Das Jahr',
      );
      expect(
        await user('Das Patchkabel bitte').answer({
          'type': 'choice',
          'prompt': '?',
          'options': ['Kabel', 'Patchkabel'],
        }),
        'Patchkabel',
      );
    });
  });

  group('Ollama', () {
    test('tool results name their tool', () {
      final body = OllamaClient(model: 'm').buildBody(
        LlmRequest(
          messages: [LlmMessage.toolResult(callId: 'call_0', name: 'tap', content: '{}')],
        ),
      );
      expect((body['messages'] as List).single, containsPair('tool_name', 'tap'));
    });
  });
}

/// Publishes a small catalogue and describes whatever is asked for.
final class _DescribeApp implements BenchmarkEnvironment {
  static const _names = ['form.open', 'form.set', 'nav.open'];

  @override
  Future<EnvironmentDescriptor> describe() async => const EnvironmentDescriptor(
    environmentId: 'describe',
    envelopes: [
      EnvelopeSpec(key: 'intents.catalog', kind: .observe),
      EnvelopeSpec(key: 'intents.describe', kind: .observe),
    ],
  );

  @override
  Future<void> reset(FixtureRef fixture) async {}

  @override
  Future<EnvelopeResult> handle(Envelope envelope) async => EnvelopeResult.ok({
    'intents': [
      for (final name in _names)
        if (envelope.key == 'intents.catalog' || (envelope.payload['names'] as List? ?? const []).contains(name))
          {'name': name, 'summary': '${name.replaceAll('.', ' ')} does a thing', 'description': '${name.replaceAll('.', ' ')} does a thing'},
    ],
  });

  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) async => const FinalStateSnapshot(results: []);
}
