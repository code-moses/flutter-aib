import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:test/test.dart';

/// Completes each turn with one insert, then says done — so a task with two
/// follow-ups ends with three todos if the episode really continued.
final class _TurnTakingAgent implements BenchmarkAgent {
  final received = <String>[];
  var _inserted = 0;
  var _saidDone = 0;

  @override
  AgentManifest get manifest => const AgentManifest(agentId: 'turn-taking');

  @override
  Future<void> startEpisode(TaskSpec task, EnvironmentDescriptor environment) async {
    received.add(task.instruction);
  }

  @override
  Future<Envelope> next(EnvelopeResult? lastResult, BudgetStatus budget) async {
    final user = lastResult?.payload['user'];
    if (user is String) received.add(user);
    if (_inserted > _saidDone) {
      _saidDone++;
      return Envelope.done(summary: 'turn $_saidDone');
    }
    _inserted++;
    return Envelope(
      key: 'state.insert',
      kind: .act,
      payload: {
        'path': 'db.todos',
        'item': {'title': 'todo $_inserted'},
      },
    );
  }

  @override
  Future<void> endEpisode(EpisodeOutcome outcome) async {}
}

TaskSpec _task() => const TaskSpec(
  id: 't',
  title: 't',
  instruction: 'Leg einen Eintrag an.',
  budget: Budget(maxSteps: 9, maxWallClockSeconds: 30),
  fixture: FixtureRef(
    id: 'f',
    data: {
      'db': {'todos': <Object?>[]},
    },
  ),
  turns: [
    FollowUp(id: 'second', instruction: 'Und noch einen.'),
    FollowUp(id: 'third', instruction: 'Und noch einen dritten.'),
  ],
  groundTruth: GroundTruth(finalState: [FinalStateExpectation(query: 'db.todos', expectCount: 3)]),
  successCriteria: [SuccessCriterion(type: CriterionTypes.finalStateMatch)],
);

void main() {
  test('a follow-up continues the episode instead of ending it', () async {
    final agent = _TurnTakingAgent();
    final result = await BenchmarkEngine().runEpisode(
      task: _task(),
      agent: agent,
      environment: MockEnvironment(),
      meta: EpisodeMeta(
        runId: 'r',
        episodeId: 'e',
        taskId: 't',
        agentId: 'turn-taking',
        environmentId: 'mock',
        repetition: 1,
        startedAt: DateTime(2026),
      ),
    );

    // The agent heard the task and then each follow-up, in order.
    expect(agent.received, ['Leg einen Eintrag an.', 'Und noch einen.', 'Und noch einen dritten.']);
    expect(result.outcome.reason, TerminationReason.done);

    // Nothing was reset in between: all three inserts are in the same state.
    final verdict = await EpisodeEvaluator().judge(EvaluationContext(task: _task(), trace: result.trace));
    expect(verdict.type, VerdictType.success);

    final metrics = MetricsRegistry.builtin().computeAll(MetricContext(trace: result.trace, task: _task(), verdict: verdict));
    expect(metrics['turns_answered'], 2);
    expect(
      MetricsRegistry.builtin().computeAll(
        MetricContext(
          trace: result.trace,
          task: const TaskSpec(
            id: 't',
            title: 't',
            instruction: 'x',
            budget: Budget(maxSteps: 1, maxWallClockSeconds: 1),
            fixture: FixtureRef(id: 'f'),
          ),
        ),
      )['turns_answered'],
      isNull,
      reason: 'a single-turn task is not scored on turns it never had',
    );
  });

  test('the loader reads turns and refuses a broken one', () {
    SuiteLoadResult load(String turns) => SuiteLoader.loadString('''
suite: s
schema: aib-task/1.0
defaults:
  budget: {maxSteps: 3, maxWallClockSeconds: 10}
  fixture: none.json
tasks:
  - id: t
    instruction: base
    successCriteria: [{type: traceAssertion, assertions: [{kind: everKey, key: x}]}]
$turns
''', inlineFixtures: false);

    final ok = load('''
    turns:
      - {id: second, instruction: "Und noch einen."}
''');
    expect(ok.errors, isEmpty, reason: '${ok.errors}');
    expect(ok.suite!.tasks.single.turns.single.id, 'second');
    expect(load('    turns: [{id: a, instruction: "x"}, {id: a, instruction: "y"}]').errors.single, contains('duplicate turn id'));
    expect(load('    turns: [{id: a, instruction: "  "}]').errors.single, contains('needs an "instruction"'));
  });
}
