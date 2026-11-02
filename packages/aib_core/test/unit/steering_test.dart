import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:test/test.dart';

/// Inserts a todo a turn, three times, then says done; remembers when it was
/// steered.
final class _Steerable implements BenchmarkAgent, SteerableAgent {
  final heard = <(int, String, String)>[];
  var _inserted = 0;

  @override
  AgentManifest get manifest => const AgentManifest(agentId: 'steerable');

  @override
  Future<void> startEpisode(TaskSpec task, EnvironmentDescriptor environment) async {}

  @override
  void steer(String message, {required String id}) => heard.add((_inserted, id, message));

  @override
  Future<Envelope> next(EnvelopeResult? lastResult, BudgetStatus budget) async {
    if (_inserted == 3) return Envelope.done(summary: 'done');
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

const _task = TaskSpec(
  id: 't',
  title: 't',
  instruction: 'Leg drei Einträge an.',
  budget: Budget(maxSteps: 9, maxWallClockSeconds: 30),
  fixture: FixtureRef(
    id: 'f',
    data: {
      'db': {'todos': <Object?>[]},
    },
  ),
  steering: [
    SteeringMessage(id: 'urgent', afterActions: 2, message: 'Mach den letzten dringend.'),
    SteeringMessage(id: 'late', afterActions: 7, message: 'Never due.'),
  ],
);

EpisodeMeta _meta() =>
    EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'a', environmentId: 'mock', repetition: 1, startedAt: DateTime(2026));

void main() {
  test('a steering message reaches a steerable agent once enough actions happened, and is traced', () async {
    final agent = _Steerable();
    final result = await BenchmarkEngine().runEpisode(task: _task, agent: agent, environment: MockEnvironment(), meta: _meta());
    expect(agent.heard, [(2, 'urgent', 'Mach den letzten dringend.')]);
    final steers = result.trace.events.where((e) => e.type == TraceEventTypes.userSteer).toList();
    expect(steers.single.data['delivered'], isTrue);
    expect(MetricsRegistry.builtin().computeAll(MetricContext(trace: result.trace, task: _task))['steering_delivered_share'], 0.5);
  });

  test('an agent that cannot be steered is recorded as not having heard it', () async {
    final agent = ScriptedAgent(
      defaultScript: [
        for (var i = 0; i < 3; i++)
          Envelope(
            key: 'state.insert',
            kind: .act,
            payload: {
              'path': 'db.todos',
              'item': {'title': '$i'},
            },
          ),
      ],
    );
    final result = await BenchmarkEngine().runEpisode(task: _task, agent: agent, environment: MockEnvironment(), meta: _meta());
    final steer = result.trace.events.firstWhere((e) => e.type == TraceEventTypes.userSteer);
    expect(steer.data['delivered'], isFalse);
    expect(MetricsRegistry.builtin().computeAll(MetricContext(trace: result.trace, task: _task))['steering_delivered_share'], 0);
  });

  test('the loader reads steering and refuses a broken entry', () {
    SuiteLoadResult load(String steering) => SuiteLoader.loadString('''
suite: s
schema: aib-task/1.0
defaults:
  budget: {maxSteps: 3, maxWallClockSeconds: 10}
  fixture: f.json
tasks:
  - id: t
    instruction: x
    groundTruth: {finalState: [{query: q, expect: {count: 1}}]}
    successCriteria: [{type: finalStateMatch}]
    steering: $steering
''', inlineFixtures: false);
    final ok = load('[{id: a, afterActions: 1, message: "Doch lieber morgen."}]');
    expect(ok.errors, isEmpty);
    expect(ok.suite!.tasks.single.steering.single.afterActions, 1);
    expect(load('[{id: a, afterActions: 1}]').errors.single, contains('message'));
  });
}
