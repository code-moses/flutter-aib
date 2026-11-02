/// M1 (spec §11, most critical milestone): a fully synthetic benchmark
/// (ScriptedAgent × MockEnvironment) runs end-to-end and yields verified,
/// expected metrics. This is the central measurement-validity argument
/// (spec §10.2): scripted episodes with known ground truth must produce
/// exactly the metric values they were constructed to produce.
library;

import 'dart:io';

import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:test/test.dart';

const fixtureData = {
  'db': {
    'todos': [
      {'title': 'Existing', 'completed': false, 'dueDate': '2026-07-05'},
    ],
  },
};

TaskSpec makeTask({
  int maxSteps = 25,
  int maxWallClockSeconds = 30,
  int? maxTokens,
  int? maxTurns,
  int? optimalSteps = 1,
  int? maxIdenticalRepeats = 2,
}) => TaskSpec(
  id: 'mock.create.simple',
  title: 'Insert a todo',
  instruction: 'Create a todo titled "Milch kaufen" due 2026-07-10.',
  budget: Budget(
    maxSteps: maxSteps,
    maxWallClockSeconds: maxWallClockSeconds,
    maxTokens: maxTokens,
    maxTurns: maxTurns,
    maxIdenticalRepeats: maxIdenticalRepeats,
  ),
  fixture: const FixtureRef(id: 'baseline', data: fixtureData),
  groundTruth: const GroundTruth(
    finalState: [
      FinalStateExpectation(
        query: "db.todos.where(title == 'Milch kaufen')",
        expectCount: 1,
        expectFields: {'dueDate': '2026-07-10', 'completed': false},
      ),
    ],
  ),
  successCriteria: const [SuccessCriterion(type: CriterionTypes.finalStateMatch)],
  partialCredit: const [PartialCreditRule(condition: "count == 1 && fields.dueDate != '2026-07-10'", credit: 0.5, label: 'Task created, wrong date')],
  optimalSteps: optimalSteps,
);

Envelope observeList() => const Envelope(
  key: 'state.list',
  kind: .observe,
  payload: {'path': 'db.todos'},
  decision: AgentDecision(model: 'scripted', tokensPrompt: 100, tokensCompletion: 20, llmLatencyMs: 5, llmCalls: 1),
);

Envelope insertMilk({String dueDate = '2026-07-10'}) => Envelope(
  key: 'state.insert',
  kind: .act,
  payload: {
    'path': 'db.todos',
    'item': {'title': 'Milch kaufen', 'completed': false, 'dueDate': dueDate},
  },
  decision: const AgentDecision(model: 'scripted', tokensPrompt: 200, tokensCompletion: 30, llmLatencyMs: 7, llmCalls: 1),
);

EpisodeMeta meta(String episodeId) => EpisodeMeta(
  runId: 'test-run',
  episodeId: episodeId,
  taskId: 'mock.create.simple',
  agentId: 'scripted',
  environmentId: 'mock',
  repetition: 1,
  startedAt: DateTime.utc(2026, 7, 2),
);

Future<EpisodeRecord> runAndEvaluate(ScriptedAgent agent, MockEnvironment environment, TaskSpec task, {String episodeId = 'e1'}) async {
  final result = await BenchmarkEngine().runEpisode(task: task, agent: agent, environment: environment, meta: meta(episodeId));
  // Round-trip through JSONL so the whole persistence path is under test.
  final trace = TraceCodec.decode(TraceCodec.encode(result.trace));
  return await RunEvaluation().evaluateEpisode(trace, task);
}

void main() {
  group('M1 scenario 1 — perfect episode', () {
    late EpisodeRecord record;

    setUp(() async {
      final agent = ScriptedAgent(
        scripts: {
          'mock.create.simple': [observeList(), insertMilk()],
        },
      );
      record = await runAndEvaluate(agent, MockEnvironment(), makeTask());
    });

    test('verdict is success with score 1', () {
      expect(record.verdict.type, VerdictType.success);
      expect(record.verdict.score, 1.0);
    });

    test('effectiveness metrics are exact', () {
      expect(record.metrics['success'], 1);
      expect(record.metrics['weighted_score'], 1.0);
      expect(record.metrics['failure'], 0);
      expect(record.metrics['abort'], 0);
      expect(record.metrics['infrastructure_error'], 0);
      expect(record.metrics['unsupported_envelope_count'], 0);
      expect(record.metrics['kind_integrity_violations'], 0);
    });

    test('efficiency metrics are exact', () {
      expect(record.metrics['action_count'], 1);
      expect(record.metrics['observation_count'], 1);
      expect(record.metrics['observation_bytes'], greaterThan(0));
      expect(record.metrics['redundant_action_ratio'], 0.0);
      expect(record.metrics['path_efficiency'], 1.0);
      expect(record.metrics['wall_clock_ms'], greaterThanOrEqualTo(0));
    });

    test('self-reported telemetry is summed exactly', () {
      // observe: 100+20, act: 200+30, meta.done carries no decision.
      expect(record.metrics['tokens_prompt'], 300);
      expect(record.metrics['tokens_completion'], 50);
      expect(record.metrics['tokens_total'], 350);
      expect(record.metrics['llm_roundtrips'], 2);
      expect(record.metrics['llm_latency_ms'], 12);
    });
  });

  group('M1 scenario 2 — detours (redundant actions)', () {
    test('redundant_action_ratio and path_efficiency reflect the detours', () async {
      final agent = ScriptedAgent(
        scripts: {
          'mock.create.simple': [const Envelope(key: 'state.noop', kind: .act), const Envelope(key: 'state.noop', kind: .act), insertMilk()],
        },
      );
      final record = await runAndEvaluate(agent, MockEnvironment(), makeTask());
      expect(record.verdict.type, VerdictType.success);
      expect(record.metrics['action_count'], 3);
      expect(record.metrics['redundant_action_ratio'], closeTo(2 / 3, 1e-9));
      expect(record.metrics['path_efficiency'], closeTo(1 / 3, 1e-9));
    });
  });

  group('M1 scenario 3 — failure and abort', () {
    test('injected env failure + abort -> failure verdict, abort counted', () async {
      final agent = ScriptedAgent(
        scripts: {
          'mock.create.simple': [insertMilk(), Envelope.abort(reason: 'cannot recover from failure')],
        },
      );
      final environment = MockEnvironment(failKeys: {'state.insert': 'simulated app crash on insert'});
      final record = await runAndEvaluate(agent, environment, makeTask());

      expect(record.verdict.type, VerdictType.failure);
      expect(record.verdict.reason, contains('abort'));
      expect(record.metrics['abort'], 1);
      expect(record.metrics['success'], 0);
      // A failed act does not change state -> counted as redundant.
      expect(record.metrics['redundant_action_ratio'], 1.0);
    });

    test('wrong due date -> partial credit 0.5 with rule label', () async {
      final agent = ScriptedAgent(
        scripts: {
          'mock.create.simple': [insertMilk(dueDate: '2026-07-11')],
        },
      );
      final record = await runAndEvaluate(agent, MockEnvironment(), makeTask());
      expect(record.verdict.type, VerdictType.partial);
      expect(record.verdict.score, 0.5);
      expect(record.verdict.label, 'Task created, wrong date');
      expect(record.metrics['weighted_score'], 0.5);
    });
  });

  group('M1 scenario 4 — budget limits', () {
    test('step budget terminates the episode', () async {
      final agent = ScriptedAgent(
        scripts: {'mock.create.simple': List.filled(10, const Envelope(key: 'state.noop', kind: .act))},
      );
      final result = await BenchmarkEngine().runEpisode(
        task: makeTask(maxSteps: 3),
        agent: agent,
        environment: MockEnvironment(),
        meta: meta('budget-steps'),
      );
      expect(result.outcome.reason, TerminationReason.budgetSteps);
      final record = await RunEvaluation().evaluateEpisode(result.trace, makeTask(maxSteps: 3));
      expect(record.metrics['action_count'], 3);
      expect(record.verdict.type, VerdictType.failure);
    });

    test('token budget terminates the episode (self-reported)', () async {
      final agent = ScriptedAgent(
        scripts: {
          'mock.create.simple': [
            observeList(), // 120 tokens
            observeList(),
            observeList(),
            insertMilk(),
          ],
        },
      );
      final result = await BenchmarkEngine().runEpisode(
        task: makeTask(maxTokens: 200),
        agent: agent,
        environment: MockEnvironment(),
        meta: meta('budget-tokens'),
      );
      expect(result.outcome.reason, TerminationReason.budgetTokens);
    });

    test('turn budget terminates the episode, counting observations too', () async {
      // The dimension the token budget cannot express. Three observations
      // cost nothing in steps — observing is free, by design — and on a real
      // instance they would cost most of a token budget in re-sent prefix
      // without the agent having read anything new. Turns count them.
      final agent = ScriptedAgent(
        scripts: {
          'mock.create.simple': [observeList(), observeList(), observeList(), insertMilk()],
        },
      );
      final result = await BenchmarkEngine().runEpisode(
        task: makeTask(maxTurns: 3, maxIdenticalRepeats: null),
        agent: agent,
        environment: MockEnvironment(),
        meta: meta('budget-turns'),
      );
      expect(result.outcome.reason, TerminationReason.budgetTurns);
    });

    test('a turn budget left unset caps nothing', () async {
      final agent = ScriptedAgent(
        scripts: {
          'mock.create.simple': [observeList(), observeList(), insertMilk()],
        },
      );
      final result = await BenchmarkEngine().runEpisode(
        task: makeTask(maxIdenticalRepeats: null),
        agent: agent,
        environment: MockEnvironment(),
        meta: meta('budget-turns-off'),
      );
      expect(result.outcome.reason, TerminationReason.done);
    });

    test('wall clock budget terminates the episode', () async {
      final agent = ScriptedAgent(
        scripts: {'mock.create.simple': List.filled(50, const Envelope(key: 'state.noop', kind: .act))},
      );
      final result = await BenchmarkEngine().runEpisode(
        // The script is 50 copies of one envelope, so the no-progress guard
        // would stop it first; this test is about the wall clock.
        task: makeTask(maxWallClockSeconds: 1, maxIdenticalRepeats: null),
        agent: agent,
        environment: MockEnvironment(handleDelay: const Duration(milliseconds: 150)),
        meta: meta('budget-time'),
      );
      expect(result.outcome.reason, TerminationReason.timeout);
    });
  });

  group('M1 scenario 4b — the no-progress guard', () {
    Future<EpisodeRunResult> run(ScriptedAgent agent, {int? maxIdenticalRepeats = 2}) => BenchmarkEngine().runEpisode(
      task: makeTask(maxIdenticalRepeats: maxIdenticalRepeats),
      agent: agent,
      environment: MockEnvironment(),
      meta: meta('no-progress'),
    );

    test('an envelope that keeps returning the same answer ends the episode', () async {
      final agent = ScriptedAgent(
        scripts: {
          'mock.create.simple': [observeList(), observeList(), observeList(), observeList()],
        },
      );

      final result = await run(agent);

      expect(result.outcome.reason, TerminationReason.noProgress);
      expect(result.outcome.message, contains('state.list'));
    });

    test('the agent is told it is looping instead of being handed the answer again', () async {
      final agent = ScriptedAgent(
        scripts: {
          'mock.create.simple': [observeList(), observeList(), observeList()],
        },
      );

      await run(agent);

      // The first answer is the real one; every identical repeat after it is
      // replaced by a notice, which is both shorter and the only thing the
      // agent did not already know.
      expect(agent.receivedResults.first.status, EnvelopeStatus.ok);
      expect(agent.receivedResults.skip(1).map((r) => r.error?.code), everyElement('no_progress'));
      expect(agent.receivedResults.last.error!.message, contains('meta.abort'));
    });

    test('the same answer to a different question is a loop too', () async {
      // The signature guard cannot see this one: every call carries a
      // different payload, so every call is a fresh signature — while the
      // environment hands back the identical document each time. An app
      // that lists everything when a query matches nothing does exactly
      // this, and qwen3:8b spent ten turns varying a query against it.
      Envelope probe(int i) => Envelope(key: 'state.get', kind: .observe, payload: {'path': null, 'attempt': i});
      final agent = ScriptedAgent(
        scripts: {
          'mock.create.simple': [probe(1), probe(2), probe(3), probe(4)],
        },
      );

      await run(agent);

      // Two genuinely different attempts are allowed through; the third
      // identical document is the one that gets told, on the same
      // `maxIdenticalRepeats` knob the signature guard uses.
      expect(agent.receivedResults.first.status, EnvelopeStatus.ok);
      expect(agent.receivedResults[1].status, EnvelopeStatus.ok);
      final told = agent.receivedResults[2];
      expect(told.error?.code, 'no_progress');
      expect(told.error!.message, contains('different parameter sets'));
    });

    test('a different question with a different answer is left alone', () async {
      final agent = ScriptedAgent(
        scripts: {
          'mock.create.simple': [observeList(), insertMilk(), observeList()],
        },
      );

      await run(agent);

      expect(agent.receivedResults.map((r) => r.status), everyElement(EnvelopeStatus.ok));
    });

    test('the trace keeps what the environment said, not what the agent was handed', () async {
      final agent = ScriptedAgent(
        scripts: {
          'mock.create.simple': [observeList(), observeList()],
        },
      );

      final result = await run(agent);

      final results = result.trace.byType(TraceEventTypes.envResult).toList();
      expect(results.last.data['status'], 'ok');
      expect(results.last.data['suppressed'], isTrue);
      expect(results.last.data['repeatIndex'], 1);
    });

    test('a repeat whose answer changed is progress and resets the count', () async {
      // The insert changes what the list returns, so the two observations
      // after it are a fresh pair rather than a continuation of the first.
      final agent = ScriptedAgent(
        scripts: {
          'mock.create.simple': [observeList(), observeList(), insertMilk(), observeList(), observeList()],
        },
      );

      final result = await run(agent);

      expect(result.outcome.reason, TerminationReason.done);
    });

    test('a task may switch the guard off', () async {
      final agent = ScriptedAgent(
        scripts: {
          'mock.create.simple': [observeList(), observeList(), observeList(), observeList()],
        },
      );

      final result = await run(agent, maxIdenticalRepeats: null);

      expect(result.outcome.reason, TerminationReason.done);
      expect(agent.receivedResults.map((r) => r.status), everyElement(EnvelopeStatus.ok));
    });
  });

  group('M1 scenario 5 — kind integrity (declare but verify)', () {
    test('act declared as observe is counted as violation', () async {
      final sneaky = Envelope(
        key: 'state.insert',
        kind: .observe, // lies about its nature
        payload: insertMilk().payload,
      );
      final agent = ScriptedAgent(
        scripts: {
          'mock.create.simple': [sneaky],
        },
      );
      final record = await runAndEvaluate(agent, MockEnvironment(), makeTask());
      expect(record.metrics['kind_integrity_violations'], 1);
      // And it evades action_count — exactly why the violation is reported.
      expect(record.metrics['action_count'], 0);
    });
  });

  group('M1 scenario 6 — framework fault is not attributed to the agent', () {
    test('environment crash -> error verdict, infrastructure_error = 1', () async {
      final agent = ScriptedAgent(
        scripts: {
          'mock.create.simple': [insertMilk()],
        },
      );
      final environment = _CrashingEnvironment();
      final result = await BenchmarkEngine().runEpisode(task: makeTask(), agent: agent, environment: environment, meta: meta('framework-fault'));
      expect(result.outcome.reason, TerminationReason.frameworkFault);
      final record = await RunEvaluation().evaluateEpisode(result.trace, makeTask());
      expect(record.verdict.type, VerdictType.error);
      expect(record.metrics['infrastructure_error'], 1);
      expect(record.metrics['weighted_score'], isNull, reason: 'framework faults must not enter agent scoring');
    });
  });

  group('M1 end-to-end — full runner + aggregation + reports', () {
    test('runner persists manifest+traces; evaluation and reports add up', () async {
      final task = makeTask();
      final suite = TaskSuite(name: 'mock_m1', schema: TaskSuite.supportedSchema, defaultRepetitions: 3, tasks: [task], sourceHash: 'testhash');
      final tempDir = await createTempDir();
      final store = RunStore(tempDir);
      final runner = BenchmarkRunner(
        suite: suite,
        agents: {
          'scripted': ScriptedAgent(
            scripts: {
              task.id: [observeList(), insertMilk()],
            },
          ),
        },
        environment: MockEnvironment(),
        store: store,
        seed: 7,
        runId: 'm1-run',
      );
      final manifest = await runner.run();
      expect(manifest.taskOrder, [task.id]);

      // Separate evaluation pass over persisted traces (P6).
      final traces = store.readTraces();
      expect(traces, hasLength(3));
      final records = await RunEvaluation().evaluateRun(traces, suite);
      expect(records.every((r) => r.verdict.type == .success), isTrue);

      final aggregates = Aggregator().aggregate(records);
      final successRate = aggregates.firstWhere((r) => r.agentId == 'scripted' && r.taskId == '*' && r.metric == 'success_rate');
      expect(successRate.mean, 1.0);
      expect(successRate.n, 3);
      expect(successRate.ciLow, lessThan(1.0)); // Wilson CI, n=3
      expect(successRate.ciHigh, 1.0);

      final data = RunReportData(manifest: manifest, records: records, aggregates: aggregates);
      expect(CsvReporter().render(data), contains('m1-run,mock.create.simple__scripted__rep1'));
      expect(MarkdownReporter().render(data), contains('| scripted '));
      expect(JsonReporter().render(data), contains('"success_rate"'));
    });
  });
}

final class _CrashingEnvironment implements BenchmarkEnvironment {
  final MockEnvironment _inner = MockEnvironment();

  @override
  Future<EnvironmentDescriptor> describe() => _inner.describe();

  @override
  Future<void> reset(FixtureRef fixture) => _inner.reset(fixture);

  @override
  Future<EnvelopeResult> handle(Envelope envelope) async => throw StateError('environment crashed');

  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) => _inner.captureFinalState(queries);
}

Future<Directory> createTempDir() async {
  final dir = await Directory.systemTemp.createTemp('aib_m1_');
  addTearDown(() => dir.delete(recursive: true));
  return dir;
}
