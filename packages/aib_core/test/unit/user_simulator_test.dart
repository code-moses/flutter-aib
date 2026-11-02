import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:test/test.dart';

final class _User implements UserSimulator {
  _User(this.replies);

  final List<String?> replies;
  final List<JsonMap> _log = [];
  TaskSpec? _task;
  var asked = 0;
  final goals = <bool?>[];

  @override
  JsonMap describe() => {'model': 'fake-user'};

  @override
  bool get isActive => _task?.userSimulator != null;

  @override
  void beginEpisode(TaskSpec task) => _task = task;

  @override
  Future<Object?> answer(JsonMap question) async => null;

  @override
  Future<String?> followUp(String? summary, {bool? goalMet}) async {
    asked++;
    goals.add(goalMet);
    final reply = replies.removeAt(0);
    _log.add({'role': 'followUp', 'text': reply ?? 'DONE', 'valid': true});
    return reply;
  }

  @override
  List<JsonMap> drain() {
    final drained = List.of(_log);
    _log.clear();
    return drained;
  }
}

TaskSpec _task({UserSimulatorSpec? simulator, GroundTruth groundTruth = const GroundTruth()}) => TaskSpec(
  id: 't',
  title: 't',
  instruction: 'Create a todo.',
  budget: Budget(maxSteps: 10, maxWallClockSeconds: 30),
  groundTruth: groundTruth,
  fixture: const FixtureRef(
    id: 'f',
    data: {
      'db': {'todos': <Object>[]},
    },
  ),
  userSimulator: simulator,
);

const _done = Envelope(key: 'meta.done', kind: .act, payload: {'summary': 'Done.'});

Future<EpisodeRunResult> _run(_User user, TaskSpec task) => BenchmarkEngine(userSimulator: user).runEpisode(
  task: task,
  agent: ScriptedAgent(
    scripts: {
      't': [_done, _done, _done],
    },
  ),
  environment: MockEnvironment(),
  meta: EpisodeMeta(
    runId: 'r',
    episodeId: 'e',
    taskId: 't',
    agentId: 'scripted',
    environmentId: 'mock',
    repetition: 1,
    startedAt: DateTime.utc(2026, 9, 14),
  ),
);

List<TraceEvent> _ofType(EpisodeRunResult result, String type) => result.trace.events.where((e) => e.type == type).toList();

void main() {
  test('the simulated user follows up until it is satisfied', () async {
    final task = _task(simulator: const UserSimulatorSpec(goal: 'A dated todo'));
    final result = await _run(_User(['Mit Datum, bitte.', null]), task);

    final turn = _ofType(result, TraceEventTypes.userTurn).single;
    expect(turn.data['instruction'], 'Mit Datum, bitte.');
    expect(turn.data['simulated'], isTrue);
    expect(_ofType(result, TraceEventTypes.userSimulated), hasLength(2));
    expect(result.outcome.reason, TerminationReason.done);

    final record = await RunEvaluation().evaluateEpisode(result.trace, task);
    expect(record.metrics['simulated_follow_up_count'], 1);
    expect(record.metrics['simulation_valid'], 1);
  });

  test('follow-ups stop at maxFollowUps', () async {
    final user = _User(['a', 'b', 'c']);
    final result = await _run(user, _task(simulator: const UserSimulatorSpec(goal: 'g', maxFollowUps: 1)));
    expect(_ofType(result, TraceEventTypes.userTurn), hasLength(1));
    expect(user.asked, 1);
  });

  test('a task without a simulated user is never followed up', () async {
    final user = _User([]);
    final task = _task();
    final result = await _run(user, task);
    expect(user.asked, 0);
    final record = await RunEvaluation().evaluateEpisode(result.trace, task);
    expect(record.metrics['simulation_valid'], isNull);
  });

  test('the simulator is told whether the goal holds', () async {
    Future<List<bool?>> goals(GroundTruth groundTruth) async {
      final user = _User([null]);
      await _run(
        user,
        _task(
          simulator: const UserSimulatorSpec(goal: 'g'),
          groundTruth: groundTruth,
        ),
      );
      return user.goals;
    }

    GroundTruth todos(int count) => GroundTruth(
      finalState: [FinalStateExpectation(query: 'db.todos', expectCount: count)],
    );
    expect(await goals(todos(1)), [false]);
    expect(await goals(todos(0)), [true]);
    expect(await goals(const GroundTruth()), [null]);
  });

  test('the spec survives the wire', () {
    final back = TaskSpec.fromJson(
      _task(
        simulator: const UserSimulatorSpec(goal: 'g', knows: {'pick': 'id-1'}, mustNotReveal: ['27'], mustNotAsk: ['absenden'], maxFollowUps: 3),
      ).toJson(),
    ).userSimulator!;
    expect(back.knows, {'pick': 'id-1'});
    expect(back.mustNotReveal, ['27']);
    expect(back.mustNotAsk, ['absenden']);
    expect(back.maxFollowUps, 3);
  });
}
