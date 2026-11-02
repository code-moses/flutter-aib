import 'dart:io';

import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:test/test.dart';

/// P7 — resumable runs (§5.2, after AgentBench's resumable evaluation).
///
/// The live runs are ~300 LLM episodes; a provider outage at episode 250 must
/// not cost the whole run and its API budget.

const _fixture = {
  'db': {
    'todos': [
      {'title': 'Existing', 'completed': false},
    ],
  },
};

/// Two tasks, one of which the agent can only solve when [solvable] is true —
/// used to produce a differing outcome on re-execution.
TaskSuite _suite({String hash = 'hash-1', int repetitions = 2}) => TaskSuite(
  name: 'resume_demo',
  schema: TaskSuite.supportedSchema,
  defaultRepetitions: repetitions,
  sourceHash: hash,
  sourcePath: 'suites/resume_demo.yaml',
  tasks: [
    for (final id in ['t1', 't2'])
      TaskSpec(
        id: id,
        title: id,
        instruction: 'complete it',
        budget: const Budget(maxSteps: 5, maxWallClockSeconds: 30),
        fixture: const FixtureRef(id: 'seed', data: _fixture),
        groundTruth: const GroundTruth(
          finalState: [
            FinalStateExpectation(query: "db.todos.where(title == 'Existing')", expectCount: 1, expectFields: {'completed': true}),
          ],
        ),
        successCriteria: const [SuccessCriterion(type: CriterionTypes.finalStateMatch)],
      ),
  ],
);

final _completeEnvelope = Envelope(
  key: 'state.update',
  kind: .act,
  payload: {
    'path': 'db.todos',
    'where': {'title': 'Existing'},
    'set': {'completed': true},
  },
);

/// Counts how often the agent was actually asked to run an episode.
final class _CountingAgent implements BenchmarkAgent {
  _CountingAgent({String agentId = 'counting'}) : _inner = ScriptedAgent(agentId: agentId, defaultScript: [_completeEnvelope]);

  final ScriptedAgent _inner;
  int episodes = 0;

  @override
  AgentManifest get manifest => _inner.manifest;

  @override
  Future<void> startEpisode(TaskSpec task, EnvironmentDescriptor environment) {
    episodes++;
    return _inner.startEpisode(task, environment);
  }

  @override
  Future<Envelope> next(EnvelopeResult? lastResult, BudgetStatus budget) => _inner.next(lastResult, budget);

  @override
  Future<void> endEpisode(EpisodeOutcome outcome) => _inner.endEpisode(outcome);
}

/// Environment that fails the very first episode with a framework fault.
final class _FaultyOnceEnvironment implements BenchmarkEnvironment {
  final MockEnvironment _inner = MockEnvironment();
  bool _thrown = false;

  @override
  Future<void> reset(FixtureRef fixture) {
    if (!_thrown) {
      _thrown = true;
      throw StateError('environment crashed');
    }
    return _inner.reset(fixture);
  }

  @override
  Future<EnvironmentDescriptor> describe() => _inner.describe();
  @override
  Future<EnvelopeResult> handle(Envelope envelope) => _inner.handle(envelope);
  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) => _inner.captureFinalState(queries);
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('aib_resume'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<({RunManifest manifest, int executed, List<String> skipped})> run({
    required BenchmarkAgent agent,
    BenchmarkEnvironment? environment,
    TaskSuite? suite,
    bool resume = true,
  }) async {
    final skipped = <String>[];
    var executed = 0;
    final manifest = await BenchmarkRunner(
      suite: suite ?? _suite(),
      agents: {agent.manifest.agentId: agent},
      environment: environment ?? MockEnvironment(),
      store: RunStore(dir),
      resume: resume,
      onEpisode: (_, _) => executed++,
      onSkipped: (meta, _) => skipped.add(meta.episodeId),
    ).run();
    return (manifest: manifest, executed: executed, skipped: skipped);
  }

  test('a fresh directory executes every episode', () async {
    final result = await run(agent: _CountingAgent());
    expect(result.executed, 4, reason: '2 tasks × 2 reps');
    expect(result.skipped, isEmpty);
    expect(result.manifest.resumes, isEmpty);
  });

  test('re-running reuses complete episodes instead of re-executing them', () async {
    await run(agent: _CountingAgent());

    final agent = _CountingAgent();
    final second = await run(agent: agent);

    expect(second.executed, 0);
    expect(second.skipped, hasLength(4));
    expect(agent.episodes, 0, reason: 'the agent — and its API budget — is never touched again');
    expect(second.manifest.resumes, hasLength(1), reason: 'the manifest records that the run happened in two sittings');
  });

  test('a resumed run keeps its identity', () async {
    final first = await run(agent: _CountingAgent());
    final second = await run(agent: _CountingAgent());

    expect(second.manifest.runId, first.manifest.runId);
    expect(second.manifest.createdAt, first.manifest.createdAt);
    expect(second.manifest.taskOrder, first.manifest.taskOrder);
    for (final trace in RunStore(dir).readTraces()) {
      expect(trace.meta.runId, first.manifest.runId, reason: 'traces must not end up with two different run ids');
    }
  });

  test('--force re-executes everything', () async {
    await run(agent: _CountingAgent());
    final agent = _CountingAgent();
    final forced = await run(agent: agent, resume: false);

    expect(forced.executed, 4);
    expect(agent.episodes, 4);
    expect(forced.skipped, isEmpty);
  });

  test('missing and truncated traces are re-executed', () async {
    await run(agent: _CountingAgent());
    final store = RunStore(dir);

    final gone = BenchmarkRunner.episodeId('t1', 'counting', 1);
    File(store.traceFilePath(gone)).deleteSync();

    // Killed mid-write: valid meta line, no episode.end.
    final truncated = BenchmarkRunner.episodeId('t2', 'counting', 2);
    final file = File(store.traceFilePath(truncated));
    final kept = file.readAsLinesSync().takeWhile((l) => !l.contains('episode.end')).join('\n');
    file.writeAsStringSync('$kept\n');
    expect(store.readTraceOrNull(truncated)!.isComplete, isFalse);

    final second = await run(agent: _CountingAgent());
    expect(second.executed, 2);
    expect(second.skipped, hasLength(2));
    expect(store.readTraceOrNull(gone), isNotNull);
    expect(store.readTraceOrNull(truncated)!.isComplete, isTrue);
  });

  test('framework faults are always re-executed, never reused (§5.2)', () async {
    final first = await run(agent: _CountingAgent(), environment: _FaultyOnceEnvironment());
    expect(first.executed, 4);

    final faulted = RunStore(dir).readTraces().where((t) => t.endReason == TerminationReason.frameworkFault.name);
    expect(faulted, hasLength(1), reason: 'exactly one episode crashed');

    final second = await run(agent: _CountingAgent());
    expect(second.executed, 1, reason: 'the crashed episode is repeated, the other three reused');
    expect(second.skipped, hasLength(3));
    expect(RunStore(dir).readTraces().where((t) => t.endReason == TerminationReason.frameworkFault.name), isEmpty);
  });

  group('resuming is refused when the experiment changed', () {
    Future<List<String>> conflictReasons({TaskSuite? suite, BenchmarkAgent? agent}) async {
      await run(agent: _CountingAgent());
      try {
        await run(agent: agent ?? _CountingAgent(), suite: suite);
        return const [];
      } on ResumeConflict catch (e) {
        return e.reasons;
      }
    }

    test('changed suite file', () async {
      expect((await conflictReasons(suite: _suite(hash: 'hash-2'))).join(), contains('suite hash'));
    });

    test('changed repetition count', () async {
      expect((await conflictReasons(suite: _suite(repetitions: 3))).join(), contains('repetitions: 2 -> 3'));
    });

    test('changed environment version', () async {
      // The suite hash describes the questions; this describes what they were
      // asked of. Two halves of one run against two different apps, and nothing
      // downstream could have told.
      await run(agent: _CountingAgent());
      try {
        await run(
          agent: _CountingAgent(),
          environment: MockEnvironment(version: '2.0.0'),
        );
        fail('a changed environment must refuse the resume');
      } on ResumeConflict catch (e) {
        expect(e.reasons.join(), contains('environment version'));
      }
    });

    test('changed agent set', () async {
      expect((await conflictReasons(agent: _CountingAgent(agentId: 'other'))).join(), contains('agents'));
    });

    test('the conflict names the run and how to get out of it', () async {
      await run(agent: _CountingAgent());
      expect(
        () => run(
          agent: _CountingAgent(),
          suite: _suite(hash: 'hash-2'),
        ),
        throwsA(isA<ResumeConflict>().having((e) => e.toString(), 'message', contains('--force'))),
      );
    });
  });
}
