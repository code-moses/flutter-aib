import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:test/test.dart';

/// Inserts a todo on every turn and never says done.
final class _BusyAgent implements BenchmarkAgent {
  var inserted = 0;

  @override
  AgentManifest get manifest => const AgentManifest(agentId: 'busy');

  @override
  Future<void> startEpisode(TaskSpec task, EnvironmentDescriptor environment) async {}

  @override
  Future<Envelope> next(EnvelopeResult? lastResult, BudgetStatus budget) async => Envelope(
    key: 'state.insert',
    kind: .act,
    payload: {
      'path': 'db.todos',
      'item': {'title': 'todo ${++inserted}'},
    },
  );

  @override
  Future<void> endEpisode(EpisodeOutcome outcome) async {}
}

TaskSpec _task({int? cancelAtTurn = 2}) => TaskSpec(
  id: 't',
  title: 't',
  instruction: 'Leg Einträge an.',
  budget: const Budget(maxSteps: 9, maxWallClockSeconds: 30),
  fixture: const FixtureRef(
    id: 'f',
    data: {
      'db': {
        'todos': <Object?>[],
        'orders': [
          {'id': 1},
        ],
      },
    },
  ),
  cancelAtTurn: cancelAtTurn,
  groundTruth: const GroundTruth(
    finalState: [FinalStateExpectation(query: 'db.todos', expectCount: 2)],
    mustNotChange: ['db.orders'],
  ),
  successCriteria: const [SuccessCriterion(type: CriterionTypes.finalStateMatch)],
);

Future<EpisodeRunResult> _run(TaskSpec task, BenchmarkAgent agent) => BenchmarkEngine().runEpisode(
  task: task,
  agent: agent,
  environment: MockEnvironment(),
  meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'busy', environmentId: 'mock', repetition: 1, startedAt: DateTime(2026)),
);

void main() {
  test('the engine stops the agent at the scheduled turn', () async {
    final agent = _BusyAgent();
    final result = await _run(_task(), agent);

    expect(result.outcome.reason, TerminationReason.cancelled);
    expect(agent.inserted, 2);

    // Judged on what the stop left behind, not failed as defeat.
    final verdict = await EpisodeEvaluator().judge(EvaluationContext(task: _task(), trace: result.trace));
    expect(verdict.type, VerdictType.success);

    final metrics = MetricsRegistry.builtin().computeAll(MetricContext(trace: result.trace, task: _task(), verdict: verdict));
    expect(metrics['consistent_after_cancel'], 1);
  });

  test('consistent_after_cancel says nothing about an episode not stopped', () async {
    final result = await _run(_task(cancelAtTurn: null), _BusyAgent());

    final metrics = MetricsRegistry.builtin().computeAll(MetricContext(trace: result.trace));
    expect(result.outcome.reason, isNot(TerminationReason.cancelled));
    expect(metrics['consistent_after_cancel'], isNull);
  });

  test('cancelAtTurn survives serialisation and variants', () {
    final task = TaskSpec.fromJson(_task().toJson());
    expect(task.cancelAtTurn, 2);
    expect(task.asVariant(const InstructionVariant(id: 'v', instruction: 'Anders.')).cancelAtTurn, 2);
  });
}
