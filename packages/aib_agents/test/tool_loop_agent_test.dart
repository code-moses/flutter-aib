import 'package:aib_agents/aib_agents.dart';
import 'package:aib_agents/testing.dart';
import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

/// Minimal in-memory environment speaking the intent convention — enough to
/// exercise the full agent loop (catalog discovery, invoke, results)
/// without Flutter.
final class _FakeIntentEnvironment implements BenchmarkEnvironment {
  final List<Envelope> handled = [];
  final Set<String> completedTitles = {};

  static const _intents = [
    {
      'name': 'todo.toggle',
      'description': 'Toggles completion.',
      'paramsSchema': {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
        },
      },
    },
    {'name': 'todo.find', 'description': 'Finds todos.'},
  ];

  @override
  Future<EnvironmentDescriptor> describe() async => const EnvironmentDescriptor(
    environmentId: 'fake-intents',
    envelopes: [
      EnvelopeSpec(key: 'intents.catalog', kind: .observe),
      EnvelopeSpec(key: 'intents.describe', kind: .observe),
      EnvelopeSpec(key: 'intents.invoke', kind: .act),
    ],
  );

  @override
  Future<void> reset(FixtureRef fixture) async {
    handled.clear();
    completedTitles.clear();
  }

  @override
  Future<EnvelopeResult> handle(Envelope envelope) async {
    handled.add(envelope);
    switch (envelope.key) {
      case 'intents.catalog':
        return EnvelopeResult.ok({
          'intents': [
            for (final intent in _intents) {'name': intent['name'], 'summary': intent['description'], 'kind': 'act'},
          ],
        });
      case 'intents.describe':
        final wanted = {for (final raw in envelope.payload['names'] as List? ?? const []) '$raw'};
        return EnvelopeResult.ok({
          'intents': [
            for (final intent in _intents)
              if (wanted.contains(intent['name'])) intent,
          ],
        });
      case 'intents.invoke':
        final intent = envelope.payload['intent'];
        if (intent == 'todo.toggle') {
          completedTitles.add(asJsonMap(envelope.payload['params'])['title'] as String);
          return EnvelopeResult.ok({'completed': true});
        }
        if (intent == 'todo.find') {
          return EnvelopeResult.ok({'count': 2});
        }
        return EnvelopeResult.failed('unknown_intent', 'no intent $intent');
      default:
        return EnvelopeResult.unsupported(envelope.key);
    }
  }

  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) async => const FinalStateSnapshot(results: []);
}

TaskSpec _task({int maxSteps = 10}) => TaskSpec(
  id: 'fake.toggle',
  title: 'toggle',
  instruction: 'Mark "Steuer" as completed.',
  budget: Budget(maxSteps: maxSteps, maxWallClockSeconds: 30),
  fixture: const FixtureRef(id: 'fx', data: {}),
  successCriteria: const [
    SuccessCriterion(
      type: CriterionTypes.traceAssertion,
      config: {
        'assertions': [
          {'kind': 'everKey', 'key': 'intents.invoke'},
        ],
      },
    ),
  ],
);

EpisodeMeta _meta(String agentId) => EpisodeMeta(
  runId: 'r',
  episodeId: 'e',
  taskId: 'fake.toggle',
  agentId: agentId,
  environmentId: 'fake-intents',
  repetition: 1,
  startedAt: DateTime.utc(2026, 7, 6),
);

final class _PlanningAgent extends ToolLoopAgent {
  _PlanningAgent({required super.client});

  final planResults = <String>[];

  @override
  String get agentId => 'planning';
  @override
  String get promptVersion => 'test';
  @override
  String get systemPrompt => 'test';
  @override
  List<LlmTool> get strategyTools => const [];
  @override
  Envelope? bootstrapEnvelope() => null;
  @override
  List<Envelope> bootstrapPlan() => const [
    Envelope(key: 'intents.catalog', kind: .observe),
    Envelope(key: 'intents.invoke', kind: .observe, payload: {'intent': 'todo.find'}),
  ];
  @override
  void onPlanResult(Envelope sent, EnvelopeResult result, String rendered) {
    planResults.add(sent.key);
    super.onPlanResult(sent, result, rendered);
  }

  @override
  Envelope? mapToolCall(LlmToolCall call) => null;
}

void main() {
  streamingTests();
  _instructionTests();

  test('a bootstrap plan runs before the first LLM call, marked prefetch', () async {
    final llm = FakeLlmClient(
      responses: [
        FakeLlmClient.calls([
          ('done', {'summary': 'two todos'}),
        ]),
      ],
    );
    final agent = _PlanningAgent(client: llm);
    final result = await BenchmarkEngine().runEpisode(task: _task(), agent: agent, environment: _FakeIntentEnvironment(), meta: _meta('planning'));
    final decisions = [for (final x in result.trace.exchanges()) AgentDecision.fromJson(asJsonMap(x.envelope.data['decision']))];
    expect(decisions.map((d) => d.isPrefetch), [true, true, false]);
    expect(decisions.take(2).map((d) => d.llmCalls), [0, 0]);
    expect(agent.planResults, ['intents.catalog', 'intents.invoke']);
    // Both results were in the one request the model saw.
    expect(llm.requests.single.messages.where((m) => m.content.contains('Initial observation')), hasLength(2));
    expect(decisions.last.extra?['tools'], 2, reason: 'done and abort');
  });

  /// Turn one of every IntentAgent script: the catalog only lists, so nothing
  /// is callable until it has been described.
  final describeBoth = FakeLlmClient.calls([
    (
      'describe_intents',
      {
        'names': ['todo.toggle', 'todo.find'],
      },
    ),
  ]);

  group('IntentAgent loop', () {
    late _FakeIntentEnvironment environment;
    late FakeLlmClient llm;
    late EpisodeRunResult result;

    setUp(() async {
      environment = _FakeIntentEnvironment();
      llm = FakeLlmClient(
        responses: [
          // The catalog only lists; the agent has to ask for the schema
          // before it can call anything.
          FakeLlmClient.calls([
            (
              'describe_intents',
              {
                'names': ['todo.toggle', 'todo.find'],
              },
            ),
          ]),
          FakeLlmClient.calls([
            ('intent_todo_toggle', {'title': 'Steuer'}),
          ]),
          FakeLlmClient.calls([
            ('done', {'summary': 'toggled'}),
          ]),
        ],
      );
      result = await BenchmarkEngine().runEpisode(
        task: _task(),
        agent: IntentAgent(client: llm),
        environment: environment,
        meta: _meta('intent'),
      );
    });

    test('bootstraps with intents.catalog before any LLM call', () {
      expect(environment.handled.first.key, 'intents.catalog');
      final exchanges = result.trace.exchanges();
      final bootstrap = exchanges.first;
      expect(bootstrap.kind, 'observe');
      final decision = asJsonMap(bootstrap.envelope.data['decision']);
      expect(decision['llmCalls'], 0, reason: 'bootstrap must not consume LLM budget');
    });

    test('the catalog offers no intent tools; describing them does', () {
      // Turn one: nothing from the catalog is callable yet. This is the whole
      // point of the split — the tool surface no longer grows with the size
      // of the app's configuration.
      final first = llm.requests.first.tools.map((t) => t.name).toList();
      expect(first, containsAll(['describe_intents', 'done', 'abort']));
      expect(first, isNot(contains('intent_todo_toggle')));

      // Turn two: exactly what was asked about, with the app's own schema.
      final second = llm.requests[1].tools.map((t) => t.name).toList();
      expect(second, containsAll(['intent_todo_toggle', 'intent_todo_find']));
      final toggle = llm.requests[1].tools.firstWhere((t) => t.name == 'intent_todo_toggle');
      expect(asJsonMap(toggle.parameters['properties']), contains('title'));
    });

    test('maps intent tool calls to intents.invoke and terminates via done', () {
      expect(environment.completedTitles, {'Steuer'});
      expect(result.outcome.reason, TerminationReason.done);
      expect(result.outcome.message, 'toggled');
    });

    test('self-reported telemetry rides on the emitted envelopes', () async {
      final decisions = result.trace.byType(TraceEventTypes.agentEnvelope).map((e) => e.data['decision']).whereType<Map<Object?, Object?>>().toList();
      // catalog (0 calls) + describe (1) + invoke (1) + done (1)
      expect(decisions, hasLength(4));
      final record = await RunEvaluation().evaluateEpisode(result.trace, _task());
      expect(record.metrics['llm_roundtrips'], 3);
      expect(record.metrics['tokens_total'], 3 * 120);
      expect(record.verdict.type, VerdictType.success);
    });

    test('conversation contains the tool result before the next LLM turn', () {
      final second = llm.requests[2].messages;
      expect(second.any((m) => m.role == .tool), isTrue);
      final toolResult = second.lastWhere((m) => m.role == .tool);
      expect(toolResult.content, contains('completed'));
      expect(toolResult.content, contains('[budget:'));
    });
  });

  group('loop edge cases', () {
    test('an abort after spent retries names their count and is the harness\'s', () async {
      final llm = FakeLlmClient(responses: [for (var i = 0; i < 4; i++) const LlmResponse(text: '')]);
      final agent = IntentAgent(client: llm);
      await agent.startEpisode(_task(), const EnvironmentDescriptor(environmentId: 'fake'));
      const budget = BudgetStatus(stepsUsed: 0, maxSteps: 10, elapsedMs: 0, maxWallClockMs: 30000, tokensUsed: 0);
      await agent.next(null, budget);
      final envelope = await agent.next(EnvelopeResult.ok({'intents': const []}), budget);
      expect(envelope.isAbort, isTrue);
      expect(envelope.payload['reason'], 'model returned an empty response (3 retries)');
      expect(envelope.decision!.isHarnessAuthored, isTrue);
    });

    test('multiple tool calls in one turn are emitted sequentially '
        'without extra LLM calls', () async {
      final environment = _FakeIntentEnvironment();
      final llm = FakeLlmClient(
        responses: [
          describeBoth,
          FakeLlmClient.calls([
            ('intent_todo_toggle', {'title': 'A'}),
            ('intent_todo_toggle', {'title': 'B'}),
          ]),
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      );
      final result = await BenchmarkEngine().runEpisode(
        task: _task(),
        agent: IntentAgent(client: llm),
        environment: environment,
        meta: _meta('intent'),
      );
      expect(environment.completedTitles, {'A', 'B'});
      // describe, the two-call turn, done — the pair costs one turn, not two.
      expect(llm.requests, hasLength(3));
      // Both tool results precede the next assistant turn — the describe
      // result from turn one is the third.
      final toolResults = llm.requests[2].messages.where((m) => m.role == .tool).toList();
      expect(toolResults, hasLength(3));
      expect(toolResults.sublist(1).every((m) => m.content.contains('completed')), isTrue);
      expect(result.outcome.reason, TerminationReason.done);
    });

    test('unknown tool gets an error result and the model may retry', () async {
      final environment = _FakeIntentEnvironment();
      final llm = FakeLlmClient(
        responses: [
          describeBoth,
          FakeLlmClient.calls([
            ('hallucinated_tool', {'x': 1}),
          ]),
          FakeLlmClient.calls([
            ('intent_todo_toggle', {'title': 'Steuer'}),
          ]),
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      );
      final result = await BenchmarkEngine().runEpisode(
        task: _task(),
        agent: IntentAgent(client: llm),
        environment: environment,
        meta: _meta('intent'),
      );
      expect(result.outcome.reason, TerminationReason.done);
      expect(environment.completedTitles, {'Steuer'});
      final retryMessages = llm.requests[2].messages.where((m) => m.role == .tool).toList();
      expect(retryMessages.last.content, contains('unknown tool'));
    });

    test('prose instead of a tool call is nudged, not read as done', () async {
      // A reasoning model narrates its plan in `content`. Taking the first
      // such turn as `done` ends the episode on the model's first thought
      // and reports it as a premature termination it never expressed.
      final llm = FakeLlmClient(
        responses: [
          describeBoth,
          const LlmResponse(text: "Okay, let's see. First I should check what the app can do."),
          FakeLlmClient.calls([
            ('intent_todo_toggle', {'title': 'Steuer'}),
          ]),
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      );
      final environment = _FakeIntentEnvironment();
      final result = await BenchmarkEngine().runEpisode(
        task: _task(),
        agent: IntentAgent(client: llm),
        environment: environment,
        meta: _meta('intent'),
      );

      expect(result.outcome.reason, TerminationReason.done);
      expect(environment.completedTitles, {'Steuer'});
      expect(llm.requests[2].messages.last.content, contains('no tool call'), reason: 'the model must be told its turn did nothing');
    });

    test('only the newest unusable turn stays in the history', () async {
      // Four rambles in the context are four examples of rambling. Each retry
      // drops the previous (prose, nudge) pair so the model sees one.
      final llm = FakeLlmClient(
        responses: [
          const LlmResponse(text: 'Okay, let me think about this first.'),
          const LlmResponse(text: 'Still thinking about the right approach.'),
          const LlmResponse(text: 'One more consideration before I act.'),
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      );
      final result = await BenchmarkEngine().runEpisode(
        task: _task(),
        agent: IntentAgent(client: llm),
        environment: _FakeIntentEnvironment(),
        meta: _meta('intent'),
      );

      expect(result.outcome.reason, TerminationReason.done);

      // By the fourth request only the third ramble and its nudge are left.
      final last = llm.requests.last.messages;
      expect(last.where((m) => m.content.contains('Okay, let me think')), isEmpty);
      expect(last.where((m) => m.content.contains('Still thinking')), isEmpty);
      expect(last.where((m) => m.content.contains('One more consideration')), hasLength(1));
      expect(last.where((m) => m.content.contains('benchmark runner')), hasLength(1));
    });

    test('the nudge says it is the runner, not the user', () async {
      final llm = FakeLlmClient(
        responses: [
          const LlmResponse(text: 'Let me consider the options.'),
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      );
      await BenchmarkEngine().runEpisode(
        task: _task(),
        agent: IntentAgent(client: llm),
        environment: _FakeIntentEnvironment(),
        meta: _meta('intent'),
      );

      expect(llm.requests.last.messages.last.content, startsWith('[benchmark runner, not the user]'));
    });

    test('prose every time is still taken as the answer', () async {
      // Asked to use a tool and answered in prose anyway, every time: the
      // prose is all there is, so it is the answer rather than nothing.
      final llm = FakeLlmClient(responses: List.filled(8, const LlmResponse(text: 'Nothing to do, the state already matches.')));
      final result = await BenchmarkEngine().runEpisode(
        task: _task(),
        agent: IntentAgent(client: llm),
        environment: _FakeIntentEnvironment(),
        meta: _meta('intent'),
      );

      expect(result.outcome.reason, TerminationReason.done);
      expect(result.outcome.message, contains('already matches'));
    });

    test('empty response is nudged, never counted as termination', () async {
      // Ollama drops tool calls whose name is not in the tool list, which
      // reaches the client as a turn with neither text nor tool calls.
      // Reading that as `done` would fabricate a premature termination.
      final llm = FakeLlmClient(
        responses: [
          describeBoth,
          const LlmResponse(),
          FakeLlmClient.calls([
            ('intent_todo_toggle', {'title': 'Steuer'}),
          ]),
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      );
      final environment = _FakeIntentEnvironment();
      final result = await BenchmarkEngine().runEpisode(
        task: _task(),
        agent: IntentAgent(client: llm),
        environment: environment,
        meta: _meta('intent'),
      );
      expect(result.outcome.reason, TerminationReason.done);
      expect(environment.completedTitles, {'Steuer'});
      expect(llm.requests[2].messages.last.content, contains('empty'), reason: 'the model must be told its turn was unusable');
    });

    test('only empty responses abort with a structured reason', () async {
      final result = await BenchmarkEngine().runEpisode(
        task: _task(),
        agent: IntentAgent(client: FakeLlmClient(responses: List.filled(8, const LlmResponse()))),
        environment: _FakeIntentEnvironment(),
        meta: _meta('intent'),
      );
      expect(result.outcome.reason, TerminationReason.abort);
      expect(result.outcome.message, contains('empty response'));
    });

    test('catalog observation is rendered as a summary listing, not tool names', () async {
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      );
      await BenchmarkEngine().runEpisode(
        task: _task(),
        agent: IntentAgent(client: llm),
        environment: _FakeIntentEnvironment(),
        meta: _meta('intent'),
      );
      final observation = llm.requests.single.messages.last.content;
      expect(observation, contains('"name":"todo.toggle"'));
      expect(observation, contains('"summary":"Toggles completion."'));
      // Not callable yet, so naming the tool here would invite a call that
      // the provider silently drops.
      expect(observation, isNot(contains('intent_todo_toggle')));
      expect(observation, contains('describe_intents'));
    });

    test('persistent LLM failure aborts the episode (agent-side, '
        'not a framework fault)', () async {
      final result = await BenchmarkEngine().runEpisode(
        task: _task(),
        agent: IntentAgent(client: _ThrowingLlmClient()),
        environment: _FakeIntentEnvironment(),
        meta: _meta('intent'),
      );
      expect(result.outcome.reason, TerminationReason.abort);
      expect(result.outcome.message, contains('llm_error'));
      final record = await RunEvaluation().evaluateEpisode(result.trace, _task());
      expect(record.metrics['infrastructure_error'], 0);
    });
  });

  group('SemanticsAgent mapping', () {
    test('bootstraps with semantics.tree and maps tools to semantics keys', () {
      final agent = SemanticsAgent(client: FakeLlmClient());
      expect(agent.bootstrapEnvelope()!.key, 'semantics.tree');

      final tap = agent.mapToolCall(const LlmToolCall(id: '1', name: 'tap', arguments: {'label': 'X'}));
      expect(tap!.key, 'semantics.tap');
      expect(tap.kind, EnvelopeKind.act);
      expect(tap.payload, {'label': 'X'});

      final setText = agent.mapToolCall(const LlmToolCall(id: '2', name: 'set_text', arguments: {'nodeId': 7, 'text': 'Milch'}));
      expect(setText!.key, 'semantics.setText');
      expect(setText.payload, {'nodeId': 7, 'text': 'Milch'});

      final scroll = agent.mapToolCall(const LlmToolCall(id: '3', name: 'scroll', arguments: {'label': 'L', 'direction': 'down'}));
      expect(scroll!.key, 'semantics.scroll');
      expect(agent.mapToolCall(const LlmToolCall(id: '4', name: 'nope')), isNull);
    });

    test('manifest pins model, temperature and prompt version', () {
      final manifest = SemanticsAgent(client: FakeLlmClient()).manifest;
      expect(manifest.agentId, 'semantics');
      expect(manifest.version, 'semantics_v2');
      expect(manifest.metadata['model'], 'fake-llm');
      expect(manifest.metadata['temperature'], 0);
    });
  });

  _budgetLineTests();
}

final class _ThrowingLlmClient implements LlmClient {
  @override
  String get model => 'down';

  @override
  Future<LlmResponse> complete(LlmRequest request, {CancellationToken? cancellation}) async =>
      throw const LlmClientException('503 service unavailable', statusCode: 503);
}

/// Streaming is an optimisation of the transport, never of the protocol.
void streamingTests() {
  group('streaming', () {
    // Text *and* a tool call: streaming is about the transport, so these
    // tests must not also depend on how a text-only turn is interpreted.
    LlmResponse answer() => FakeLlmClient.calls([('done', <String, Object?>{})], text: 'Es gibt 30 Artikel.');

    test('forwards text deltas when the client can stream', () async {
      final llm = FakeStreamingLlmClient(responses: [answer()]);
      final deltas = <String>[];
      final agent = IntentAgent(client: llm)..onTextDelta = deltas.add;

      await agent.startEpisode(_streamingTask, _streamingEnvironment);
      await _pastBootstrap(agent);

      expect(llm.didStream, isTrue);
      expect(deltas.join(), 'Es gibt 30 Artikel.');
      expect(deltas.length, greaterThan(1));
    });

    test('a benchmark run sets no sink, so nothing streams', () async {
      // The measured agent and the shipped agent have to issue the same
      // request; if the harness streamed by accident, latency would be
      // measured on a different code path than the one it reports.
      final llm = FakeStreamingLlmClient(responses: [answer()]);
      final agent = IntentAgent(client: llm);

      await agent.startEpisode(_streamingTask, _streamingEnvironment);
      await _pastBootstrap(agent);

      expect(llm.didStream, isFalse);
    });

    test('a client that cannot stream is used as before', () async {
      final llm = FakeLlmClient(responses: [answer()]);
      final deltas = <String>[];
      final agent = IntentAgent(client: llm)..onTextDelta = deltas.add;

      await agent.startEpisode(_streamingTask, _streamingEnvironment);
      final envelope = await _pastBootstrap(agent);

      expect(deltas, isEmpty);
      expect(envelope.key, isNotEmpty);
    });
  });
}

/// The budget line is what an agent reads to know it is nearly out of money.
void _budgetLineTests() {
  group('budget line', () {
    Future<String> lastUserContent(FakeLlmClient llm) async => llm.requests.last.messages.last.content;

    /// Drives three turns: bootstrap, one LLM turn (so a turn's cost is
    /// known), then the turn whose budget line is under test. Before a turn
    /// has been paid for there is nothing to extrapolate from, and the line
    /// carries numbers only.
    Future<FakeLlmClient> run(BudgetStatus budget, {int finishWarningTurns = 2}) async {
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([
            ('describe_intents', {'names': <String>[]}),
          ]),
          FakeLlmClient.calls([
            ('done', {'summary': 'ok'}),
          ]),
        ],
        usagePerCall: const LlmUsage(promptTokens: 9000, completionTokens: 100),
      );
      final agent = IntentAgent(
        client: llm,
        config: AgentConfig(finishWarningTurns: finishWarningTurns),
      );
      const observed = EnvelopeResult(status: .ok, payload: {'intents': <Object?>[]});
      await agent.startEpisode(_streamingTask, _streamingEnvironment);
      await agent.next(null, budget);
      await agent.next(observed, budget);
      await agent.next(observed, budget);
      return llm;
    }

    test('reports every budget that has a limit', () async {
      final llm = await run(
        const BudgetStatus(
          stepsUsed: 1,
          maxSteps: 30,
          elapsedMs: 12000,
          maxWallClockMs: 300000,
          tokensUsed: 20000,
          maxTokens: 120000,
          turnsUsed: 2,
          maxTurns: 20,
        ),
      );
      final rendered = await lastUserContent(llm);
      expect(rendered, contains('20000/120000 tokens'));
      expect(rendered, contains('2/20 turns'));
      expect(rendered, contains('1/30 actions'));
    });

    test('a suite that sets no token budget is told about none', () async {
      final llm = await run(_streamingBudget);
      expect(await lastUserContent(llm), isNot(contains('tokens')));
    });

    test('says so in words when the tokens will not pay for two more turns', () async {
      // One 9 100-token turn has happened, so ~2 turns are affordable out of
      // 120 000 - 100 000.
      final llm = await run(
        const BudgetStatus(stepsUsed: 1, maxSteps: 30, elapsedMs: 40000, maxWallClockMs: 300000, tokensUsed: 100000, maxTokens: 120000),
      );
      final rendered = await lastUserContent(llm);
      expect(rendered, contains('nearly'));
      expect(rendered, contains('done'));
      expect(rendered, contains('abort'));
    });

    test('stays quiet while there is money left', () async {
      final llm = await run(
        const BudgetStatus(stepsUsed: 1, maxSteps: 30, elapsedMs: 5000, maxWallClockMs: 300000, tokensUsed: 9100, maxTokens: 120000),
      );
      expect(await lastUserContent(llm), isNot(contains('nearly')));
    });

    test('finishWarningTurns 0 switches the warning off', () async {
      final llm = await run(
        const BudgetStatus(stepsUsed: 1, maxSteps: 30, elapsedMs: 40000, maxWallClockMs: 300000, tokensUsed: 119000, maxTokens: 120000),
        finishWarningTurns: 0,
      );
      expect(await lastUserContent(llm), isNot(contains('nearly')));
    });
  });
}

/// The first `next` returns the bootstrap observation without consulting the
/// model; the model is only asked once its result comes back.
Future<Envelope> _pastBootstrap(BenchmarkAgent agent) async {
  await agent.next(null, _streamingBudget);
  return agent.next(const EnvelopeResult(status: .ok, payload: {'intents': <Object?>[]}), _streamingBudget);
}

final _streamingTask = TaskSpec(
  id: 'stream',
  title: 'stream',
  instruction: 'Wie viele Artikel gibt es?',
  budget: const Budget(maxSteps: 5, maxWallClockSeconds: 60),
  fixture: const FixtureRef(id: 'live'),
);

const _streamingEnvironment = EnvironmentDescriptor(
  environmentId: 'fake',
  version: '1',
  envelopes: [EnvelopeSpec(key: 'intents.catalog', kind: .observe, description: 'catalog')],
);

const _streamingBudget = BudgetStatus(stepsUsed: 0, maxSteps: 5, elapsedMs: 0, maxWallClockMs: 60000, tokensUsed: 0);

/// ADR 0018: what the app says about its instance follows the frozen prompt.
void _instructionTests() {
  group('environment instructions', () {
    const withText = EnvironmentDescriptor(
      environmentId: 'fake',
      envelopes: [EnvelopeSpec(key: 'intents.catalog', kind: .observe)],
      instructions: 'Users here mostly work with service orders.',
    );

    Future<String> systemOf(HybridAgent agent, FakeLlmClient llm, EnvironmentDescriptor environment) async {
      await agent.startEpisode(_streamingTask, environment);
      await _pastBootstrap(agent);
      return llm.requests.first.messages.first.content;
    }

    test('are appended after the frozen prompt, which stays a prefix', () async {
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      );
      final agent = HybridAgent(client: llm);
      final system = await systemOf(agent, llm, withText);

      expect(system, startsWith(agent.systemPrompt));
      expect(system, endsWith('Users here mostly work with service orders.'));
      expect(system, contains(ToolLoopAgent.instanceHeading));
    });

    test('leave the prompt untouched when the app publishes none', () async {
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      );
      final agent = HybridAgent(client: llm);
      expect(await systemOf(agent, llm, _streamingEnvironment), agent.systemPrompt);
    });

    test('are ignored by an arm that switches them off, which changes its identity', () async {
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      );
      const off = AgentConfig(parallelToolCalls: false, environmentInstructions: false);
      final agent = HybridAgent(client: llm, config: off);

      expect(await systemOf(agent, llm, withText), agent.systemPrompt);
      expect(off.identity['environmentInstructions'], isFalse);
      expect(const AgentConfig(parallelToolCalls: false).identity.containsKey('environmentInstructions'), isFalse);
      expect(AgentConfig.fromJson({'environmentInstructions': false}).environmentInstructions, isFalse);
    });
  });
}
