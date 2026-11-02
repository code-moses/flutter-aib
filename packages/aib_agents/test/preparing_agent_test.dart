import 'package:aib_agents/aib_agents.dart';
import 'package:aib_agents/testing.dart';
import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

/// An app with a catalogue, a listing that takes a query, and one intent that
/// does the work — the shape preparation is about.
final class _FakeApp implements BenchmarkEnvironment {
  final List<Envelope> handled = [];

  static const _catalogue = [
    {'name': 'form.open', 'summary': 'Open a form for filling, by assemblyId and maskId', 'kind': 'act'},
    {'name': 'form.set', 'summary': 'Set values on the open form', 'kind': 'act'},
    {'name': 'nav.open', 'summary': 'Open a route', 'kind': 'act'},
    {'name': 'time.status', 'summary': 'Is time tracking running', 'kind': 'observe'},
  ];

  @override
  Future<EnvironmentDescriptor> describe() async => const EnvironmentDescriptor(
    environmentId: 'fake-app',
    envelopes: [
      EnvelopeSpec(key: 'intents.catalog', kind: .observe),
      EnvelopeSpec(key: 'intents.describe', kind: .observe),
      EnvelopeSpec(key: 'intents.invoke', kind: .act),
      EnvelopeSpec(key: 'app.forms', kind: .observe, description: 'Lists the forms of this instance'),
    ],
  );

  @override
  Future<void> reset(FixtureRef fixture) async => handled.clear();

  @override
  Future<EnvelopeResult> handle(Envelope envelope) async {
    handled.add(envelope);
    switch (envelope.key) {
      case 'intents.catalog':
        return EnvelopeResult.ok({'intents': _catalogue});
      case 'intents.describe':
        final wanted = {for (final raw in envelope.payload['names'] as List? ?? const []) '$raw'};
        return EnvelopeResult.ok({
          'intents': [
            for (final intent in _catalogue)
              if (wanted.contains(intent['name']))
                <String, Object?>{...intent, 'description': intent['summary'], 'paramsSchema': const <String, Object?>{}},
          ],
        });
      case 'app.forms':
        return EnvelopeResult.ok({
          'forms': [
            {'maskId': 64, 'name': 'Anforderung'},
            {'maskId': 12, 'name': 'Serviceauftrag'},
            {'maskId': 13, 'name': 'Urlaubsantrag'},
            {'maskId': 14, 'name': 'Spesenabrechnung'},
            {'maskId': 15, 'name': 'Materialschein'},
            {'maskId': 16, 'name': 'Wartungsbericht'},
          ],
        });
      case 'intents.invoke':
        return EnvelopeResult.ok({'ok': true});
      default:
        return EnvelopeResult.unsupported(envelope.key);
    }
  }

  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) async => const FinalStateSnapshot(results: []);
}

TaskSpec _task({String instruction = 'Open the Anforderung form.'}) => TaskSpec(
  id: 'form.open.anforderung',
  title: 'open',
  instruction: instruction,
  budget: const Budget(maxSteps: 10, maxWallClockSeconds: 30),
  fixture: const FixtureRef(id: 'fx', data: {}),
);

final _meta = EpisodeMeta(
  runId: 'r',
  episodeId: 'e',
  taskId: 'form.open.anforderung',
  agentId: 'prepared',
  environmentId: 'fake-app',
  repetition: 1,
  startedAt: DateTime.utc(2026, 9, 17),
);

PreparingAgent _agent(
  FakeLlmClient llm, {
  PreparationStrategy strategy = .lexical,
  List<PreparationAxis> prepare = const [PreparationAxis.tools, PreparationAxis.discovery],
  int topK = 2,
  bool escapeHatch = true,
}) => PreparingAgent(
  client: llm,
  preparation: PreparationConfig(strategy: strategy, prepare: prepare, topK: topK, discoveryKeys: const ['app.forms'], escapeHatch: escapeHatch),
);

Future<EpisodeRunResult> _run(PreparingAgent agent, _FakeApp app, {TaskSpec? task}) =>
    BenchmarkEngine().runEpisode(task: task ?? _task(), agent: agent, environment: app, meta: _meta);

FakeLlmClient _answers() => FakeLlmClient(
  responses: [
    FakeLlmClient.calls([
      ('intent_form_open', {'maskId': 64}),
    ]),
    FakeLlmClient.calls([
      ('done', {'summary': 'Formular 64 geöffnet.'}),
    ]),
  ],
);

void main() {
  group('the plan', () {
    test('discovers before the first LLM call and costs no tokens', () async {
      final app = _FakeApp();
      final llm = _answers();
      final result = await _run(_agent(llm), app);

      expect(app.handled.map((e) => e.key).take(3), ['intents.catalog', 'intents.describe', 'app.forms']);
      final decisions = [for (final x in result.trace.exchanges()) AgentDecision.fromJson(asJsonMap(x.envelope.data['decision']))];
      expect(decisions.take(3).map((d) => d.isPrefetch), [true, true, true]);
      expect(decisions.take(3).map((d) => d.llmCalls), [0, 0, 0]);
      // The form intent was callable on the very first model turn.
      expect(llm.requests.first.tools.map((t) => t.name), contains('intent_form_open'));
    });

    test('the listing is narrowed by the task\'s most specific word', () async {
      final app = _FakeApp();
      await _run(_agent(_answers()), app);
      final listing = app.handled.firstWhere((e) => e.key == 'app.forms');
      expect(listing.payload['query'], 'anforderung');
    });

    test('a catalogue in another language promotes nothing, and says so', () async {
      // The instance's data is German and its intent descriptions are English.
      // Term matching cannot bridge that, and pretending otherwise would be
      // the wrong finding: this is the gap a vector strategy exists for.
      final app = _FakeApp();
      final llm = _answers();
      await _run(_agent(llm), app, task: _task(instruction: 'Öffne das Formular Anforderung.'));
      expect(app.handled.where((e) => e.key == 'intents.describe'), isEmpty);
      final briefing = llm.requests.first.messages.lastWhere((m) => m.content.startsWith('Preparation:')).content;
      expect(briefing, contains('no intent matched'));
      // Discovery still works, because the app's *data* is German.
      expect(app.handled.firstWhere((e) => e.key == 'app.forms').payload['query'], 'anforderung');
    });

    test('stays within the envelope budget', () async {
      final app = _FakeApp();
      final agent = PreparingAgent(
        client: _answers(),
        preparation: const PreparationConfig(
          strategy: .lexical,
          prepare: [PreparationAxis.tools, PreparationAxis.discovery],
          discoveryKeys: ['app.forms'],
          maxEnvelopes: 2,
        ),
      );
      await _run(agent, app);
      expect(app.handled.where((e) => e.key == 'app.forms'), isEmpty);
    });
  });

  group('the briefing', () {
    Future<String> briefing(PreparingAgent agent, FakeLlmClient llm) async {
      await _run(agent, _FakeApp());
      return llm.requests.first.messages.lastWhere((m) => m.content.startsWith('Preparation:')).content;
    }

    test('reduces a listing and says what it dropped', () async {
      final llm = _answers();
      final text = await briefing(_agent(llm), llm);
      expect(text, contains('Anforderung'));
      expect(text, contains('and 4 more'));
      expect(text, isNot(contains('Wartungsbericht')));
    });

    test('names every intent in scope, so the hatch is usable', () async {
      // describe_intents takes catalogue names, and nothing else in the
      // request would say what they are.
      final llm = _answers();
      final text = await briefing(_agent(llm), llm);
      expect(text, contains('time.status'));
      expect(text, contains('nav.open'));
    });

    test('an omitted axis is stated, not hidden', () async {
      final llm = _answers();
      final text = await briefing(_agent(llm, prepare: const [PreparationAxis.tools], escapeHatch: false), llm);
      expect(text, contains('Not prepared'));
      expect(text, isNot(contains('time.status')));
    });

    test('one message, not one per observation', () async {
      final llm = _answers();
      await _run(_agent(llm), _FakeApp());
      expect(llm.requests.first.messages.where((m) => m.content.startsWith('Initial observation')), isEmpty);
    });
  });

  group('the control condition', () {
    test('strategy none is the hybrid agent with another prompt', () async {
      final app = _FakeApp();
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([
            (
              'describe_intents',
              {
                'names': ['form.open'],
              },
            ),
          ]),
          FakeLlmClient.calls([
            ('intent_form_open', {'maskId': 64}),
          ]),
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      );
      final agent = _agent(llm, strategy: .none);
      await _run(agent, app);
      expect(app.handled.first.key, 'intents.catalog');
      expect(app.handled.where((e) => e.key == 'app.forms'), isEmpty);
      expect(agent.promptVersion, 'prepared_v1');
      expect(agent.systemPrompt, isNot(Prompts.hybridV4));
    });

    test('an unimplemented strategy is refused, never substituted', () {
      // `model` is the one still unbuilt: a reranker over the fused list.
      expect(() => PreparationConfig.fromJson({'strategy': 'model'}), throwsFormatException);
      expect(
        () => PreparationConfig.fromJson({
          'strategy': 'lexical',
          'prepare': ['data'],
        }),
        throwsFormatException,
      );
    });
  });

  group('prefetch metrics', () {
    test('precision and recall read the trace, not the agent', () async {
      final llm = _answers();
      final result = await _run(_agent(llm), _FakeApp());
      final record = await RunEvaluation(metrics: MetricsRegistry.builtin(providers: [prefetchMetrics])).evaluateEpisode(result.trace, _task());

      // Three items: form.open and form.set promoted, one listing digest.
      expect(record.metrics['prefetch_item_count'], 3);
      // form.open was called and the listing's "64" reached the invoke.
      expect(record.metrics['prefetch_precision'], greaterThan(0.5));
      expect(record.metrics['prefetch_recall'], 1);
      expect(record.metrics['prefetch_refetch_count'], 0);
      expect(record.metrics['prefetch_llm_calls'], 0);
    });

    test('an agent that prepares nothing scores null, not zero', () async {
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      );
      final result = await _run(_agent(llm, strategy: .none), _FakeApp());
      final record = await RunEvaluation(metrics: MetricsRegistry.builtin(providers: [prefetchMetrics])).evaluateEpisode(result.trace, _task());
      expect(record.metrics['prefetch_precision'], isNull);
      expect(record.metrics['prefetch_item_count'], isNull);
    });
  });
}
