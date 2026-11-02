import 'dart:io';

import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:test/test.dart';

TaskSpec _task(String id, {int? repetitions}) => TaskSpec(
  id: id,
  title: id,
  instruction: 'do $id',
  budget: const Budget(maxSteps: 2, maxWallClockSeconds: 20),
  fixture: const FixtureRef(id: 'f', data: {}),
  repetitions: repetitions,
);

TaskSuite _suite() => TaskSuite(
  name: 'order',
  schema: TaskSuite.supportedSchema,
  defaultRepetitions: 2,
  sourceHash: 'h',
  tasks: [_task('a'), _task('b', repetitions: 3)],
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('aib_order'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<(List<String>, RunManifest)> run(RepetitionOrder? order) async {
    final agent = ScriptedAgent(agentId: 's');
    final episodes = <String>[];
    final runner = order == null
        ? BenchmarkRunner(
            suite: _suite(),
            agents: {'s': agent},
            environment: MockEnvironment(),
            store: RunStore(dir),
            seed: 1,
            onEpisode: (meta, _) => episodes.add(meta.episodeId),
          )
        : BenchmarkRunner(
            suite: _suite(),
            agents: {'s': agent},
            environment: MockEnvironment(),
            store: RunStore(dir),
            seed: 1,
            repetitionOrder: order,
            onEpisode: (meta, _) => episodes.add(meta.episodeId),
          );
    final manifest = await runner.run();
    return (episodes, manifest);
  }

  test('interleaved is the default: no task runs twice in a row, every repetition runs', () async {
    final (episodes, manifest) = await run(null);
    expect(episodes, hasLength(5));
    for (var i = 1; i < episodes.length; i++) {
      expect(episodes[i].split('__').first, isNot(episodes[i - 1].split('__').first), reason: '$episodes');
    }
    // A task with more repetitions than the rest finishes on its own.
    expect(episodes.last, 'b__s__rep3');
    expect(manifest.extra[RunManifest.repetitionOrderKey], 'interleaved');
  });

  test('blocked runs a task\'s repetitions back to back', () async {
    final (episodes, manifest) = await run(RepetitionOrder.blocked);
    final first = episodes.first.split('__').first;
    final reps = first == 'a' ? 2 : 3;
    expect(episodes.take(reps).every((id) => id.startsWith('${first}__')), isTrue, reason: '$episodes');
    expect(manifest.extra[RunManifest.repetitionOrderKey], 'blocked');
  });
}
