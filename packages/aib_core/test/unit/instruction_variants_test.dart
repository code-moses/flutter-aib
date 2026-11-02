import 'dart:io';

import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:test/test.dart';

/// Records what each episode was actually asked.
final class _RecordingAgent implements BenchmarkAgent {
  final _inner = ScriptedAgent(agentId: 'recording');
  final asked = <String>[];
  final tags = <List<String>>[];

  @override
  AgentManifest get manifest => _inner.manifest;
  @override
  Future<void> startEpisode(TaskSpec task, EnvironmentDescriptor environment) {
    asked.add(task.instruction);
    tags.add(task.tags);
    return _inner.startEpisode(task, environment);
  }

  @override
  Future<Envelope> next(EnvelopeResult? last, BudgetStatus budget) => _inner.next(last, budget);
  @override
  Future<void> endEpisode(EpisodeOutcome outcome) => _inner.endEpisode(outcome);
}

TaskSuite _suite() => const TaskSuite(
  name: 'variants',
  schema: TaskSuite.supportedSchema,
  defaultRepetitions: 1,
  sourceHash: 'h',
  tasks: [
    TaskSpec(
      id: 't1',
      title: 't1',
      instruction: 'Lege eine neue Anforderung an.',
      budget: Budget(maxSteps: 2, maxWallClockSeconds: 20),
      fixture: FixtureRef(id: 'f', data: {}),
      tags: ['forms'],
      variants: [
        InstructionVariant(id: 'polite', instruction: 'Könntest du bitte eine Anforderung anlegen?'),
        InstructionVariant(id: 'typo', instruction: 'lege eine nee Anforderng an'),
      ],
    ),
  ],
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('aib_variants'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('each rewording is its own episode, tagged and otherwise identical', () async {
    final agent = _RecordingAgent();
    final episodes = <String>[];
    await BenchmarkRunner(
      suite: _suite(),
      agents: {agent.manifest.agentId: agent},
      environment: MockEnvironment(),
      store: RunStore(dir),
      onEpisode: (meta, _) => episodes.add(meta.episodeId),
    ).run();

    expect(episodes, ['t1__recording__rep1', 't1__recording__rep1__polite', 't1__recording__rep1__typo']);
    expect(agent.asked, ['Lege eine neue Anforderung an.', 'Könntest du bitte eine Anforderung anlegen?', 'lege eine nee Anforderng an']);
    // The slice a comparison reads; the base keeps the task's own tags.
    expect(agent.tags, [
      ['forms'],
      ['forms', 'variant:polite'],
      ['forms', 'variant:typo'],
    ]);
  });

  test('the loader reads variants and refuses a broken one', () {
    SuiteLoadResult load(String variants) => SuiteLoader.loadString('''
suite: s
schema: aib-task/1.0
defaults:
  budget: {maxSteps: 3, maxWallClockSeconds: 10}
  fixture: none.json
tasks:
  - id: t
    instruction: base
    successCriteria: [{type: traceAssertion, assertions: [{kind: everKey, key: x}]}]
$variants
''', inlineFixtures: false);

    final ok = load('''
    variants:
      - {id: polite, instruction: "Bitte?"}
''');
    expect(ok.errors, isEmpty, reason: '${ok.errors}');
    expect(ok.suite!.tasks.single.variants.single.id, 'polite');

    expect(load('    variants: [{id: a, instruction: "x"}, {id: a, instruction: "y"}]').errors.single, contains('duplicate variant id'));
    expect(load('    variants: [{id: a}]').errors.single, contains('needs an "id" and an "instruction"'));
  });
}
