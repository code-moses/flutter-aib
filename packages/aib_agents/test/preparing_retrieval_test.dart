import 'package:aib_agents/aib_agents.dart';
import 'package:aib_agents/testing.dart';
import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

/// A catalogue written in English on an instance whose data — and whose user —
/// are German; term matching cannot reach it on its own.
final class _App implements BenchmarkEnvironment {
  _App({this.withAliases = false, this.failDiscovery = false});

  final bool withAliases;

  /// Makes the listing answer `unsupported`, the way an app does when the
  /// preparer asks it for something it does not publish.
  final bool failDiscovery;
  final List<Envelope> handled = [];

  static const _entries = [
    ('form.open', 'Open a form for filling, by assemblyId and maskId', 'act'),
    ('form.set', 'Set values on the open form', 'act'),
    ('nav.open', 'Open a route', 'act'),
    ('time.status', 'Is time tracking running', 'observe'),
  ];

  /// What the app would publish from its own translations.
  static const _aliases = {
    'form.open': ['Formular öffnen'],
    'nav.open': ['Seite öffnen'],
  };

  List<JsonMap> get catalogue => [
    for (final (name, summary, kind) in _entries)
      {'name': name, 'summary': summary, 'kind': kind, if (withAliases && _aliases[name] != null) 'aliases': _aliases[name]},
  ];

  @override
  Future<EnvironmentDescriptor> describe() async => const EnvironmentDescriptor(
    environmentId: 'fake-app',
    envelopes: [
      EnvelopeSpec(key: 'intents.catalog', kind: .observe),
      EnvelopeSpec(key: 'intents.describe', kind: .observe),
      EnvelopeSpec(key: 'intents.invoke', kind: .act),
    ],
  );

  @override
  Future<void> reset(FixtureRef fixture) async => handled.clear();

  @override
  Future<EnvelopeResult> handle(Envelope envelope) async {
    handled.add(envelope);
    switch (envelope.key) {
      case 'intents.catalog':
        return EnvelopeResult.ok({'intents': catalogue});
      case 'intents.describe':
        final wanted = {for (final raw in envelope.payload['names'] as List? ?? const []) '$raw'};
        return EnvelopeResult.ok({
          'intents': [
            for (final intent in catalogue)
              if (wanted.contains(intent['name'])) {...intent, 'description': intent['summary'], 'paramsSchema': const <String, Object?>{}},
          ],
        });
      case 'intents.invoke':
        if (failDiscovery) return EnvelopeResult.unsupported('app.forms');
        return EnvelopeResult.ok({'ok': true});
      default:
        return EnvelopeResult.unsupported(envelope.key);
    }
  }

  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) async => const FinalStateSnapshot(results: []);

  /// The names the preparer asked to have described, or null if it asked for
  /// none — which is what "retrieval found nothing" looks like from here.
  List<String>? get describedNames {
    for (final envelope in handled) {
      if (envelope.key == 'intents.describe') {
        return [for (final n in envelope.payload['names'] as List) '$n'];
      }
    }
    return null;
  }
}

TaskSpec _task({List<String> requiredTools = const []}) => TaskSpec(
  id: 'form.open.anforderung',
  title: 'open',
  instruction: 'Öffne das Formular Anforderung.',
  budget: const Budget(maxSteps: 10, maxWallClockSeconds: 30),
  fixture: const FixtureRef(id: 'fx', data: {}),
  requiredTools: requiredTools,
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

FakeLlmClient _done() => FakeLlmClient(
  responses: [
    FakeLlmClient.calls([
      ('done', {'summary': 'ok'}),
    ]),
  ],
);

PreparingAgent _agent({required FakeLlmClient llm, PreparationStrategy strategy = .lexical, EmbeddingClient? embedding}) => PreparingAgent(
  client: llm,
  embeddingClient: embedding,
  preparation: PreparationConfig(strategy: strategy, prepare: const [PreparationAxis.tools], topK: 2),
);

Future<EpisodeRunResult> _run(BenchmarkAgent agent, _App app, {TaskSpec? task}) =>
    BenchmarkEngine().runEpisode(task: task ?? _task(), agent: agent, environment: app, meta: _meta);

void main() {
  group('a listing the app publishes as an intent', () {
    PreparingAgent discoverer(FakeLlmClient llm) => PreparingAgent(
      client: llm,
      preparation: const PreparationConfig(strategy: .lexical, prepare: [PreparationAxis.discovery], discoveryKeys: ['app.forms']),
    );

    test('is fetched through intents.invoke, not as a bare key', () async {
      // The descriptor does not declare `app.forms`: on this app it is an
      // intent. Sent as an envelope key it comes back `unsupported` — which is
      // exactly what the first live pilot did on every episode, spending two
      // prefetch turns to digest an error.
      final app = _App();
      await _run(discoverer(_done()), app);

      final discovery = app.handled.firstWhere((e) => e.key == 'intents.invoke');
      expect(discovery.payload['intent'], 'app.forms');
      expect(asJsonMap(discovery.payload['params'])['query'], isNotNull);
      expect(app.handled.any((e) => e.key == 'app.forms'), isFalse);
    });

    test('an unsupported result is named, not digested', () async {
      final llm = _done();
      await _run(discoverer(llm), _App(failDiscovery: true));

      final briefing = llm.requests.first.messages.lastWhere((m) => m.content.startsWith('Preparation:')).content;
      expect(briefing, contains('unsupported'));
      expect(briefing, isNot(contains('unsupported_key')), reason: 'the error payload itself must never reach the briefing');
    });
  });

  group('aliases carry retrieval across the language boundary', () {
    test('without them a German instruction promotes nothing', () async {
      final app = _App();
      await _run(_agent(llm: _done()), app);
      expect(app.describedNames, isNull);
    });

    test('with them the same instruction promotes the right intent', () async {
      final app = _App(withAliases: true);
      await _run(_agent(llm: _done()), app);
      expect(app.describedNames, contains('form.open'));
    });

    test('the briefing shows summaries, never the aliases', () async {
      // They exist to be matched, not to be read: a briefing that printed them
      // would spend on every later turn what they were meant to save.
      final llm = _done();
      await _run(_agent(llm: llm), _App(withAliases: true));
      final briefing = llm.requests.first.messages.lastWhere((m) => m.content.startsWith('Preparation:')).content;
      expect(briefing, contains('form.open'));
      expect(briefing, isNot(contains('Formular öffnen')));
    });

    test('the catalogue rendering drops them, so no agent pays for them', () async {
      // The hybrid agent renders the catalogue into the conversation verbatim;
      // this is where an alias would become a token on every turn.
      final llm = _done();
      await _run(IntentAgent(client: llm), _App(withAliases: true));
      final rendered = llm.requests.first.messages.last.content;
      expect(rendered, contains('form.open'));
      expect(rendered, isNot(contains('Formular')));
    });
  });

  group('dense retrieval', () {
    test('embeds the task and the whole catalogue in one call', () async {
      final embedding = FakeEmbeddingClient();
      final app = _App();
      await _run(_agent(llm: _done(), strategy: .vector, embedding: embedding), app);

      expect(embedding.batches, hasLength(1));
      // The task first, then one text per catalogue entry.
      expect(embedding.batches.single.first, contains('Anforderung'));
      expect(embedding.batches.single, hasLength(_App._entries.length + 1));
      expect(app.describedNames, isNotNull);
    });

    test('a dense strategy without an embedding client is refused', () {
      expect(() => _agent(llm: _done(), strategy: .vector), throwsArgumentError);
    });

    test('an embedder that fails falls back, and says so', () async {
      // Preparation is speculative: without an embedding it prepares less,
      // not nothing, never ends the episode, and the trace records why.
      final app = _App(withAliases: true);
      final result = await _run(_agent(llm: _done(), strategy: .hybrid, embedding: _FailingEmbedding()), app);
      expect(app.describedNames, contains('form.open'));
      final record = await RunEvaluation(metrics: MetricsRegistry.builtin(providers: [prefetchMetrics])).evaluateEpisode(result.trace, _task());
      expect(record.metrics['prefetch_dense_fallbacks'], 1);
    });

    test('reports its own spend apart from the agent\'s', () async {
      final result = await _run(_agent(llm: _done(), strategy: .vector, embedding: FakeEmbeddingClient()), _App());
      final record = await RunEvaluation(metrics: MetricsRegistry.builtin(providers: [prefetchMetrics])).evaluateEpisode(result.trace, _task());

      expect(record.metrics['prefetch_embed_calls'], 1);
      expect(record.metrics['prefetch_embed_tokens'], greaterThan(0));
      // The preparer's embedding is not an agent LLM call.
      expect(record.metrics['prefetch_llm_calls'], 0);
    });
  });

  group('the retrieval oracle', () {
    Future<EpisodeRecord> score(_App app, TaskSpec task) async {
      final result = await _run(_agent(llm: _done()), app, task: task);
      return RunEvaluation(metrics: MetricsRegistry.builtin(providers: [prefetchMetrics])).evaluateEpisode(result.trace, task);
    }

    test('scores what a correct solution needed, not what was used', () async {
      // Independent of the trajectory, which is the point: preparation changes
      // the trajectory, so a trajectory-relative number cannot judge it alone.
      final record = await score(_App(withAliases: true), _task(requiredTools: ['form.open']));
      expect(record.metrics['tool_recall_at_k'], 1);
      expect(record.metrics['tool_completeness_at_k'], 1);
      expect(record.metrics['tool_ndcg_at_k'], 1);
    });

    test('a miss is visible as a miss', () async {
      final record = await score(_App(withAliases: true), _task(requiredTools: ['time.status']));
      expect(record.metrics['tool_recall_at_k'], 0);
      expect(record.metrics['tool_completeness_at_k'], 0);
    });

    test('a task that declares no gold set scores null', () async {
      final record = await score(_App(withAliases: true), _task());
      expect(record.metrics['tool_recall_at_k'], isNull);
      expect(record.metrics['tool_completeness_at_k'], isNull);
    });
  });
  test('preparation.expand adds what the kept intents name, after the top-k cut', () async {
    final app = _ReferencingApp();
    await BenchmarkEngine().runEpisode(
      task: _task(),
      agent: PreparingAgent(
        client: _done(),
        preparation: const PreparationConfig(strategy: .lexical, prepare: [PreparationAxis.tools], topK: 1, expand: .references),
      ),
      environment: app,
      meta: _meta,
    );
    expect(app.describedNames, ['form.open', 'nav.open']);
    expect(PreparationConfig.fromJson(const {'strategy': 'vector', 'expand': 'references'}).toJson()['expand'], 'references');
    expect(() => PreparationConfig.fromJson(const {'strategy': 'jev', 'expand': 'references'}), throwsFormatException);
    expect(const PreparationConfig().toJson(), isNot(contains('expand')));
  });
}

final class _FailingEmbedding implements EmbeddingClient {
  @override
  String get model => 'failing';

  @override
  Future<EmbeddingResponse> embed(List<String> texts, {CancellationToken? cancellation}) async =>
      throw const LlmClientException('embedding endpoint down', kind: LlmErrorKind.transport);
}

/// form.open's summary names the intent its ids come from; the aliases let
/// the German task match it at all.
final class _ReferencingApp extends _App {
  _ReferencingApp() : super(withAliases: true);

  @override
  List<JsonMap> get catalogue => [
    for (final intent in super.catalogue)
      if (intent['name'] == 'form.open') {...intent, 'summary': 'Open a form for filling, by a route from nav.open'} else intent,
  ];
}
