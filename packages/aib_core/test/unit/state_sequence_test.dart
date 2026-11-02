import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:test/test.dart';

/// P1 — essential-state oracle (`stateSequence`, spec §5.2).
///
/// The point of the oracle is the case `finalStateMatch` cannot see: a state
/// the episode *passed through*. The end-to-end group therefore uses a task
/// whose final state is identical for a correct and an incorrect episode.

const _fixture = FixtureRef(
  id: 'seed',
  data: {
    'db': {
      'todos': [
        {'title': 'Obsolete', 'completed': false},
        {'title': 'Keep', 'completed': false},
      ],
    },
  },
);

TaskSpec _archiveThenDelete({List<SuccessCriterion> criteria = const [SuccessCriterion(type: CriterionTypes.stateSequence)]}) => TaskSpec(
  id: 'archive.then.delete',
  title: 'Archive, then delete',
  instruction: 'Mark "Obsolete" as completed, then delete it.',
  budget: const Budget(maxSteps: 10, maxWallClockSeconds: 30),
  fixture: _fixture,
  groundTruth: const GroundTruth(
    finalState: [FinalStateExpectation(query: "db.todos.where(title == 'Obsolete')", expectCount: 0)],
    milestones: [
      MilestoneSpec(
        id: 'archived',
        expectation: FinalStateExpectation(query: "db.todos.where(title == 'Obsolete')", expectCount: 1, expectFields: {'completed': true}),
      ),
    ],
  ),
  successCriteria: criteria,
);

Envelope _complete(String title) => Envelope(
  key: 'state.update',
  kind: .act,
  payload: {
    'path': 'db.todos',
    'where': {'title': title},
    'set': {'completed': true},
  },
);

Envelope _delete(String title) => Envelope(
  key: 'state.delete',
  kind: .act,
  payload: {
    'path': 'db.todos',
    'where': {'title': title},
  },
);

/// MockEnvironment whose *state queries* are slow — probing must not be
/// charged to the episode, so this separates probe cost from handle cost.
final class _SlowProbeEnvironment implements BenchmarkEnvironment {
  _SlowProbeEnvironment(this.delay);

  final Duration delay;
  final MockEnvironment _inner = MockEnvironment();

  @override
  Future<EnvironmentDescriptor> describe() => _inner.describe();
  @override
  Future<void> reset(FixtureRef fixture) => _inner.reset(fixture);
  @override
  Future<EnvelopeResult> handle(Envelope envelope) => _inner.handle(envelope);

  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) async {
    await Future<void>.delayed(delay);
    return _inner.captureFinalState(queries);
  }
}

/// Throws for the milestone query only, so the final-state capture still
/// works and the failure is isolated to probing.
final class _ThrowingProbeEnvironment implements BenchmarkEnvironment {
  static const marker = 'probe.explodes';

  final MockEnvironment _inner = MockEnvironment();

  @override
  Future<EnvironmentDescriptor> describe() => _inner.describe();
  @override
  Future<void> reset(FixtureRef fixture) => _inner.reset(fixture);
  @override
  Future<EnvelopeResult> handle(Envelope envelope) => _inner.handle(envelope);

  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) {
    if (queries.any((q) => q.query == marker)) {
      throw StateError('probe exploded');
    }
    return _inner.captureFinalState(queries);
  }
}

Future<EpisodeRunResult> _run(TaskSpec task, List<Envelope> script) => BenchmarkEngine().runEpisode(
  task: task,
  agent: ScriptedAgent(scripts: {task.id: script}),
  environment: MockEnvironment(),
  meta: EpisodeMeta(
    runId: 'r',
    episodeId: 'e',
    taskId: task.id,
    agentId: 'scripted',
    environmentId: 'mock',
    repetition: 1,
    startedAt: DateTime.utc(2026),
  ),
);

void main() {
  final evaluator = EpisodeEvaluator();
  final metrics = MetricsRegistry.builtin();

  group('engine probing', () {
    test('probes the milestone queries after reset and after every exchange', () async {
      final task = _archiveThenDelete();
      final result = await _run(task, [_complete('Obsolete'), _delete('Obsolete')]);

      final probes = result.trace.probes();
      expect(probes.map((p) => p.seq), [-1, 0, 1], reason: 'initial state plus one probe per exchange');
      expect(probes.every((p) => p.error == null), isTrue);
      expect(probes.map((p) => p.resultFor("db.todos.where(title == 'Obsolete')")!.count), [
        1,
        1,
        0,
      ], reason: 'the entry exists, is updated in place, then disappears');
    });

    test('tasks without milestones are not probed at all', () async {
      final task = TaskSpec(
        id: 'plain',
        title: 'plain',
        instruction: 'delete it',
        budget: const Budget(maxSteps: 10, maxWallClockSeconds: 30),
        fixture: _fixture,
        successCriteria: const [SuccessCriterion(type: CriterionTypes.finalStateMatch)],
      );
      final result = await _run(task, [_delete('Obsolete')]);
      expect(result.trace.byType(TraceEventTypes.stateProbe), isEmpty);
    });

    test('probe time is excluded from the wall clock and from the budget', () async {
      // Probing is expensive here; wall_clock_ms must still only contain
      // agent + app time (probing is instrumentation, P4).
      final task = _archiveThenDelete();
      final environment = _SlowProbeEnvironment(const Duration(milliseconds: 20));
      final result = await BenchmarkEngine().runEpisode(
        task: task,
        agent: ScriptedAgent(
          scripts: {
            task.id: [_complete('Obsolete'), _delete('Obsolete')],
          },
        ),
        environment: environment,
        meta: EpisodeMeta(
          runId: 'r',
          episodeId: 'e',
          taskId: task.id,
          agentId: 'scripted',
          environmentId: 'mock',
          repetition: 1,
          startedAt: DateTime.utc(2026),
        ),
      );

      final wallClockMs = result.trace.firstOfType(TraceEventTypes.episodeEnd)!.data['wallClockMs'] as int;
      final probeMs = result.trace.byType(TraceEventTypes.stateProbe).fold<int>(0, (sum, e) => sum + (e.data['probeMs'] as int));
      final handleMs = result.trace.byType(TraceEventTypes.envResult).fold<int>(0, (sum, e) => sum + (e.data['handleMs'] as int));

      expect(probeMs, greaterThan(0), reason: 'probing really did cost time');
      expect(wallClockMs, greaterThanOrEqualTo(handleMs));
      expect(wallClockMs, lessThan(handleMs + probeMs), reason: 'probe time is not billed to the episode');
    });

    test('a throwing probe is recorded but does not end the episode', () async {
      final task = TaskSpec(
        id: 'exploding.probe',
        title: 'exploding probe',
        instruction: 'do something',
        budget: const Budget(maxSteps: 10, maxWallClockSeconds: 30),
        fixture: _fixture,
        groundTruth: const GroundTruth(
          finalState: [FinalStateExpectation(query: 'db.todos', expectCount: 2)],
          milestones: [
            MilestoneSpec(
              id: 'unreachable',
              expectation: FinalStateExpectation(query: _ThrowingProbeEnvironment.marker, expectCount: 1),
            ),
          ],
        ),
        successCriteria: const [SuccessCriterion(type: CriterionTypes.stateSequence)],
      );
      final result = await BenchmarkEngine().runEpisode(
        task: task,
        agent: ScriptedAgent(
          scripts: {
            task.id: [_complete('Obsolete')],
          },
        ),
        environment: _ThrowingProbeEnvironment(),
        meta: EpisodeMeta(
          runId: 'r',
          episodeId: 'e',
          taskId: task.id,
          agentId: 'scripted',
          environmentId: 'mock',
          repetition: 1,
          startedAt: DateTime.utc(2026),
        ),
      );

      // Probing is instrumentation: it must not turn into a framework fault
      // that would be charged to the run as an infrastructure error (§5.2).
      expect(result.outcome.reason, TerminationReason.done);
      final probes = result.trace.probes();
      expect(probes, isNotEmpty);
      expect(probes.first.error, contains('probe exploded'));

      // The criterion reports the probe failure instead of a bare "failed".
      final verdict = await evaluator.judge(EvaluationContext(task: task, trace: result.trace));
      expect(verdict.reason, contains('probe failed'));
    });
  });

  group('stateSequence evaluation', () {
    test('scores the milestone that finalStateMatch cannot see', () async {
      final task = _archiveThenDelete();

      final correct = await _run(task, [_complete('Obsolete'), _delete('Obsolete')]);
      final shortcut = await _run(task, [_delete('Obsolete')]);

      // Both episodes end in exactly the same final state …
      int finalStateOf(EpisodeRunResult r) => r.finalState!.resultFor("db.todos.where(title == 'Obsolete')")!.count;
      expect(finalStateOf(correct), 0);
      expect(finalStateOf(shortcut), 0);

      // … but only one of them passed through the milestone.
      final correctVerdict = await evaluator.judge(EvaluationContext(task: task, trace: correct.trace));
      final shortcutVerdict = await evaluator.judge(EvaluationContext(task: task, trace: shortcut.trace));

      expect(correctVerdict.type, VerdictType.success);
      expect(shortcutVerdict.type, VerdictType.failure);
      expect(shortcutVerdict.reason, contains('never reached'));
    });

    test('partial credit falls out of reached / declared', () async {
      final task = TaskSpec(
        id: 'two.milestones',
        title: 'two milestones',
        instruction: 'complete both',
        budget: const Budget(maxSteps: 10, maxWallClockSeconds: 30),
        fixture: _fixture,
        groundTruth: const GroundTruth(
          milestones: [
            MilestoneSpec(
              id: 'obsolete-done',
              expectation: FinalStateExpectation(query: "db.todos.where(title == 'Obsolete')", expectCount: 1, expectFields: {'completed': true}),
            ),
            MilestoneSpec(
              id: 'keep-done',
              expectation: FinalStateExpectation(query: "db.todos.where(title == 'Keep')", expectCount: 1, expectFields: {'completed': true}),
            ),
          ],
        ),
        successCriteria: const [SuccessCriterion(type: CriterionTypes.stateSequence)],
      );

      final result = await _run(task, [_complete('Obsolete')]);
      final verdict = await evaluator.judge(EvaluationContext(task: task, trace: result.trace));

      expect(verdict.type, VerdictType.partial);
      expect(verdict.score, 0.5);
      expect(metrics['milestone_coverage']!.compute(MetricContext(trace: result.trace, task: task, verdict: verdict)), 0.5);
    });

    test('ordered=true rejects milestones reached in the wrong order', () async {
      const milestones = [
        MilestoneSpec(
          id: 'keep-done',
          expectation: FinalStateExpectation(query: "db.todos.where(title == 'Keep')", expectCount: 1, expectFields: {'completed': true}),
        ),
        MilestoneSpec(
          id: 'obsolete-done',
          expectation: FinalStateExpectation(query: "db.todos.where(title == 'Obsolete')", expectCount: 1, expectFields: {'completed': true}),
        ),
      ];
      TaskSpec taskWith({required bool ordered}) => TaskSpec(
        id: 'ordered.$ordered',
        title: 'order matters',
        instruction: 'complete Keep first, then Obsolete',
        budget: const Budget(maxSteps: 10, maxWallClockSeconds: 30),
        fixture: _fixture,
        groundTruth: const GroundTruth(milestones: milestones),
        successCriteria: [
          SuccessCriterion(type: CriterionTypes.stateSequence, config: {'ordered': ordered}),
        ],
      );

      // Wrong order: Obsolete is completed before Keep.
      final script = [_complete('Obsolete'), _complete('Keep')];

      final strict = taskWith(ordered: true);
      final strictVerdict = await evaluator.judge(EvaluationContext(task: strict, trace: (await _run(strict, script)).trace));
      expect(strictVerdict.score, 0.5, reason: 'the second milestone is only searched for after the first');

      final lenient = taskWith(ordered: false);
      final lenientVerdict = await evaluator.judge(EvaluationContext(task: lenient, trace: (await _run(lenient, script)).trace));
      expect(lenientVerdict.type, VerdictType.success, reason: 'ordered=false accepts any order');
    });

    test('a milestone already satisfied at reset is flagged as '
        'non-discriminating', () async {
      final task = TaskSpec(
        id: 'trivial.milestone',
        title: 'trivial',
        instruction: 'do nothing useful',
        budget: const Budget(maxSteps: 10, maxWallClockSeconds: 30),
        fixture: _fixture,
        groundTruth: const GroundTruth(
          milestones: [
            MilestoneSpec(
              id: 'exists',
              expectation: FinalStateExpectation(query: "db.todos.where(title == 'Keep')", expectCount: 1),
            ),
          ],
        ),
        successCriteria: const [SuccessCriterion(type: CriterionTypes.stateSequence)],
      );
      final result = await _run(task, [Envelope(key: 'state.noop', kind: .act)]);
      final verdict = await evaluator.judge(EvaluationContext(task: task, trace: result.trace));

      expect(verdict.type, VerdictType.success);
      expect((verdict.details[CriterionTypes.stateSequence] as Map)['detail'] as String, contains('already satisfied in the initial state'));
    });

    test('a trace without probes reports the cause instead of failing '
        'silently', () async {
      final task = _archiveThenDelete();
      final trace = EpisodeTrace(
        meta: EpisodeMeta(
          runId: 'r',
          episodeId: 'old',
          taskId: task.id,
          agentId: 'a',
          environmentId: 'mock',
          repetition: 1,
          startedAt: DateTime.utc(2026),
        ),
        events: [
          const TraceEvent(seq: 0, tUs: 0, type: TraceEventTypes.episodeEnd, data: {'reason': 'done', 'wallClockMs': 1}),
        ],
      );
      final verdict = await evaluator.judge(EvaluationContext(task: task, trace: trace));
      expect(verdict.reason, contains('no state.probe events'));
    });
  });

  group('suite loading', () {
    const yaml = '''
suite: milestones
schema: aib-task/1.0
defaults:
  repetitions: 1
  budget: { maxSteps: 5, maxWallClockSeconds: 30 }
  fixture: seed.json
tasks:
  - id: t1
    instruction: do it
    groundTruth:
      milestones:
        - id: archived
          query: "db.todos.where(title == 'Obsolete')"
          expect: { count: 1, fields: { completed: true } }
    successCriteria:
      - type: stateSequence
        weight: 1.0
''';

    test('parses milestones and accepts the stateSequence criterion', () {
      final result = SuiteLoader.loadString(yaml, inlineFixtures: false);
      expect(result.errors, isEmpty);
      expect(result.warnings, isEmpty, reason: 'stateSequence is a known criterion type');
      final milestones = result.suite!.tasks.single.groundTruth.milestones;
      expect(milestones.single.id, 'archived');
      expect(milestones.single.expectation.expectFields, {'completed': true});
      expect(result.suite!.tasks.single.groundTruth.milestoneQueries.length, 1);
    });

    test('stateSequence without milestones is an error', () {
      final result = SuiteLoader.loadString(yaml.replaceAll(RegExp(r'      milestones:[\s\S]*?(?=    successCriteria)'), ''), inlineFixtures: false);
      expect(result.errors.join(), contains('requires groundTruth.milestones'));
    });

    test('milestones without a stateSequence criterion load silently', () {
      // They feed milestone_coverage; partial progress needs no criterion.
      final result = SuiteLoader.loadString(yaml.replaceAll('type: stateSequence', 'type: manualReview'), inlineFixtures: false);
      expect(result.errors, isEmpty);
      expect(result.warnings, isEmpty);
    });

    test('a milestone without expectations would match anything', () {
      final result = SuiteLoader.loadString(
        yaml.replaceAll('expect: { count: 1, fields: { completed: true } }', 'expect: {}'),
        inlineFixtures: false,
      );
      expect(result.errors.join(), contains('would match any state'));
    });

    test('duplicate milestone ids are rejected', () {
      final result = SuiteLoader.loadString(
        yaml.replaceFirst(
          '''
    successCriteria:''',
          '''
        - id: archived
          query: "db.todos"
          expect: { count: 2 }
    successCriteria:''',
        ),
        inlineFixtures: false,
      );
      expect(result.errors.join(), contains('duplicate milestone id'));
    });
  });
}
