import 'dart:io';

import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:test/test.dart';

TaskSuite _suite() => const TaskSuite(
  name: 'provenance_demo',
  schema: TaskSuite.supportedSchema,
  defaultRepetitions: 1,
  sourceHash: 'hash-1',
  tasks: [
    TaskSpec(
      id: 't1',
      title: 't1',
      instruction: 'finish',
      budget: Budget(maxSteps: 3, maxWallClockSeconds: 30),
      fixture: FixtureRef(id: 'seed', data: {'db': {}}),
    ),
  ],
);

final class _IdentifiedAgent implements BenchmarkAgent, AgentModelIdentity {
  final _inner = ScriptedAgent(agentId: 'identified');

  @override
  AgentManifest get manifest => _inner.manifest;
  @override
  Future<void> startEpisode(TaskSpec task, EnvironmentDescriptor env) => _inner.startEpisode(task, env);
  @override
  Future<Envelope> next(EnvelopeResult? last, BudgetStatus budget) => _inner.next(last, budget);
  @override
  Future<void> endEpisode(EpisodeOutcome outcome) => _inner.endEpisode(outcome);

  @override
  Future<JsonMap> modelIdentity() async => {'model': 'm', 'digest': 'sha256:abc'};
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('aib_provenance'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<RunManifest> run({Map<String, SourceRevision> revisions = const {}, BenchmarkAgent? agent}) {
    final a = agent ?? ScriptedAgent(agentId: 'scripted');
    return BenchmarkRunner(
      suite: _suite(),
      agents: {a.manifest.agentId: a},
      environment: MockEnvironment(),
      store: RunStore(dir),
      revisions: revisions,
    ).run();
  }

  group('SourceRevision', () {
    test('a pub-cache git checkout names its commit', () {
      const sha = 'c46be9f9c5389b077c0f5c5914339c37ad753532';
      final revision = SourceRevision.ofPubCachePath('/Users/x/.pub-cache/git/flutter-aib-$sha/packages/aib_core/lib/');
      expect(revision?.revision, sha);
      expect(SourceRevision.ofPubCachePath('/src/packages/aib_core/lib/'), isNull);
    });

    test('a package from a pub server names its version', () {
      final revision = SourceRevision.ofPubCachePath('/Users/x/.pub-cache/hosted/pub.dev/aib_core-1.0.0/lib/');
      expect(revision?.revision, '1.0.0');
      expect(revision?.source, 'hosted');
      expect(revision?.label, '1.0.0');
      final windows = SourceRevision.ofPubCachePath(r'C:\Users\x\AppData\Local\Pub\Cache\hosted\pub.dev\aib_core-1.2.0-dev.1+3\lib\');
      expect(windows?.revision, '1.2.0-dev.1+3');
    });

    test('package versions are the same only when equal', () {
      const v1 = SourceRevision(revision: '1.0.0', source: 'hosted');
      expect(v1.sameCommitAs(const SourceRevision(revision: '1.0.0', dirty: true)), isTrue);
      expect(v1.sameCommitAs(const SourceRevision(revision: '1.0.1')), isFalse);
      expect(v1.sameCommitAs(const SourceRevision(revision: 'c46be9f9c5')), isFalse);
    });

    test('this checkout resolves to a git revision', () async {
      final revision = await SourceRevision.ofPackage('aib_core');
      expect(revision, isNotNull);
      expect(revision!.revision, matches(RegExp(r'^[0-9a-f]{40}$')));
      expect(revision.source, 'git');
    });

    test('short and long forms of one commit are the same commit', () {
      const long = SourceRevision(revision: 'c46be9f9c5389b077c0f5c5914339c37ad753532');
      const short = SourceRevision(revision: 'c46be9f9c5', dirty: true);
      expect(long.sameCommitAs(short), isTrue);
      expect(short.label, 'c46be9f9c5+dirty');
      expect(long.sameCommitAs(const SourceRevision(revision: '1d3909c7b8')), isFalse);
    });
  });

  test('a run records the framework revision without being told', () async {
    final manifest = await run();
    expect(manifest.frameworkVersion, isNot(anyOf('0.1.0', 'unknown')));
    expect(manifest.revisions['framework'], isNotNull);
    expect(RunStore(dir).readManifest().revisions['framework']?.revision, manifest.revisions['framework']!.revision);
  });

  test('passed revisions win and travel with the manifest', () async {
    const app = SourceRevision(revision: 'abcdef1234', dirty: true, source: 'app');
    const framework = SourceRevision(revision: '1d3909c7b8', source: 'pubspec.lock');
    final manifest = await run(revisions: {'app': app, 'framework': framework});
    expect(manifest.frameworkVersion, '1d3909c7b8');
    expect(manifest.revisions['app']?.label, 'abcdef1234+dirty');
  });

  test('resuming across a framework commit is refused', () async {
    await run(revisions: {'framework': const SourceRevision(revision: '1d3909c7b8')});
    expect(() => run(revisions: {'framework': const SourceRevision(revision: 'c46be9f9c5')}), throwsA(isA<ResumeConflict>()));
  });

  test('a dirty tree at the same commit still resumes', () async {
    await run(revisions: {'framework': const SourceRevision(revision: 'c46be9f9c5')});
    await run(revisions: {'framework': const SourceRevision(revision: 'c46be9f9c5', dirty: true)});
  });

  test('the model an agent resolved to is recorded', () async {
    final manifest = await run(agent: _IdentifiedAgent());
    expect(asJsonMap(manifest.extra[RunManifest.modelsKey])['identified'], {'model': 'm', 'digest': 'sha256:abc'});
  });
}
