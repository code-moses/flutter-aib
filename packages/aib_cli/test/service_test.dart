import 'dart:convert';
import 'dart:io';

import 'package:aib_cli/aib_cli.dart';
import 'package:aib_core/aib_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// [AibService] returns what the CLI prints and the MCP server serves: typed
/// values, every one of which encodes as JSON.
void main() {
  final repoRoot = Directory.current.path.endsWith('aib_cli') ? p.normalize(p.join(Directory.current.path, '..', '..')) : Directory.current.path;
  final suitePath = p.join(repoRoot, 'suites', 'mock_v1.yaml');
  final scriptPath = p.join(repoRoot, 'suites', 'scripts', 'mock_scripted.yaml');
  const service = AibService();

  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('aib_service_'));
  tearDown(() => tmp.delete(recursive: true));

  Future<String> run(String name, {int seed = 42}) async {
    final out = p.join(tmp.path, name);
    await service.run(suite: suitePath, agents: ['scripted=$scriptPath'], outDir: out, reps: 1, seed: seed);
    return out;
  }

  /// JSON has no NaN, no Dart objects: the round trip proves both.
  Object? roundTrip(Object? json) => jsonDecode(jsonEncode(json));

  group('validateSuite', () {
    test('summarises a valid suite without ground truth', () {
      final result = service.validateSuite(suitePath);
      expect(result.isValid, isTrue);
      final json = roundTrip(result.toJson()) as Map;
      expect(json['name'], 'mock_v1');
      expect(json['tasks'], result.suite!.tasks.length);
      expect(json['criterionKinds'], contains('finalStateMatch'));
      expect(jsonEncode(json), isNot(contains('groundTruth')));
    });

    test('returns the errors of a broken suite', () {
      final broken = File(p.join(tmp.path, 'broken.yaml'))..writeAsStringSync('suite: x\nschema: wrong\ntasks: []\n');
      final result = service.validateSuite(broken.path);
      expect(result.isValid, isFalse);
      expect(result.errors, isNotEmpty);
    });
  });

  group('validateAgentConfig', () {
    test('builds a shipped arm and reports its block hashes', () {
      final check = service.validateAgentConfig(agent: 'prepared', path: p.join(repoRoot, 'suites', 'agents', 'routed_v2_jev3.yaml'));
      expect(check.error, isNull);
      final json = roundTrip(check.toJson()) as Map;
      expect(json['built'], isTrue);
      expect((json['blocks'] as Map).keys, containsAll(['modelRouter', 'preparation']));
      expect(json['agentConfigHash'], isA<String>());
    });

    test('an inline config the builder refuses comes back with the error', () {
      final check = service.validateAgentConfig(
        agent: 'hybrid',
        config: {
          'llm': {'provider': 'ollama', 'model': 'qwen3:8b'},
          'decisions': {'nonsense': true},
        },
      );
      expect(check.built, isFalse);
      expect(check.error, isNotEmpty);
    });

    test('an unknown agent kind is a usage error', () {
      expect(
        () => service.validateAgentConfig(agent: 'nope', config: const {}),
        throwsA(isA<AibError>().having((e) => e.isUsage, 'isUsage', isTrue)),
      );
    });
  });

  test('run -> evaluate -> report', () async {
    final dir = await run('a');
    final summary = await service.evaluate(dir);
    expect(summary.byVerdict, {'success': summary.run.suite.tasks.length});
    final json = roundTrip(summary.toJson()) as Map;
    expect(json['aggregates'], everyElement(containsPair('taskId', anyOf('*', startsWith('tag:')))));
    expect(summary.written.map((f) => File(f).existsSync()), [isTrue, isTrue]);

    final report = await service.report(dir, formats: ['json']);
    expect(report.written, [p.join(dir, 'report.json')]);
    expect(report.markdown, contains('success_rate'));
    expect(() => service.report(dir, formats: ['pdf']), throwsA(isA<AibError>()));
  });

  test('run refuses two agents with the same id', () async {
    await expectLater(
      service.run(suite: suitePath, agents: ['scripted=$scriptPath', 'scripted=$scriptPath'], outDir: p.join(tmp.path, 'x')),
      throwsA(isA<AibError>().having((e) => e.exitCode, 'exitCode', 64)),
    );
  });

  test('evaluate of a directory without a manifest is refused, not a crash', () async {
    await expectLater(service.evaluate(tmp.path), throwsA(isA<AibError>()));
  });

  group('compare', () {
    test('refuses unintended differences with the differences typed', () async {
      final a = await run('seed1', seed: 1);
      final b = await run('seed2', seed: 2);
      await expectLater(
        service.compare([a, b]),
        throwsA(isA<UnintendedDifferences>().having((e) => e.differences['seed2']!.map((d) => d.path), 'paths', contains('seed'))),
      );
      final pair = await service.compare([a, b], vary: ['seed']) as PairComparison;
      final json = roundTrip(pair.toJson()) as Map;
      expect(json['differences'], [
        equals({'path': 'seed', 'a': 1, 'b': 2, 'intended': true}),
      ]);
      // Timing metrics are real measurements, so only the deterministic ones are asserted.
      expect(pair.rows.where((r) => r.significant && r.metric == 'weighted_score'), isEmpty);
    });

    test('three runs are a sweep', () async {
      final dirs = [
        for (final name in ['a', 'b', 'c']) await run(name),
      ];
      final sweep = await service.compare(dirs);
      expect(sweep, isA<SweepComparison>());
      expect(((roundTrip(sweep.toJson()) as Map)['points'] as List).map((pt) => (pt as Map)['label']), ['a', 'b', 'c']);
    });
  });

  test('route scores the oracle and refuses without the routing provider', () async {
    final local = await run('local');
    final cloud = await run('cloud');
    await expectLater(service.route(local: local, cloud: cloud, options: const ScoringOptions()), throwsA(isA<AibError>()));
    final outcome = await service.route(local: local, cloud: cloud, routed: [cloud]);
    final json = roundTrip(outcome.toJson()) as Map;
    expect(json['tasks'], greaterThan(0));
    expect((json['arms'] as List).single, containsPair('label', 'cloud'));
  });

  test('selftest passes the demo suite against its references', () async {
    final outcome = await service.selftest(suite: suitePath, reference: scriptPath, requireReferences: true);
    expect(outcome.failures, 0);
    expect((roundTrip(outcome.toJson()) as Map)['checks'], hasLength(outcome.checks.length));
  });

  test('metrics lists builtin and provider metrics', () {
    final metrics = service.metrics();
    expect(metrics.map((m) => m.source), containsAll(['builtin', '--metrics routing']));
    roundTrip([for (final m in metrics) m.toJson()]);
  });

  test('doctor reports a loading suite as ok', () async {
    final report = await service.doctor(suite: suitePath);
    expect(report.failed, isFalse);
    expect((roundTrip(report.toJson()) as Map)['checks'], isNotEmpty);
  });

  test('provenance lists what moved between two runs', () async {
    final a = await run('p1', seed: 1);
    final b = await run('p2', seed: 2);
    final outcome = service.provenance(a, against: b);
    expect(outcome.differences.map((d) => d.path), contains('seed'));
    roundTrip(outcome.toJson());
  });

  test('intents and catalog read a run', () async {
    final dir = await run('i');
    final intents = service.intents(dir);
    expect(intents.episodes, greaterThan(0));
    expect(intents.markdown, contains('`state.update`'));
    // The mock environment publishes no intents.catalog.
    expect(() => service.lintCatalog(dir), throwsA(isA<AibError>()));
  });

  test('evaluateField scores trace files without a suite', () async {
    final dir = await run('f');
    final field = service.evaluateField(p.join(dir, RunStore.tracesDir));
    expect(field.rows, greaterThan(0));
    expect(File(field.outPath).existsSync(), isTrue);
  });

  test('an unknown metric provider is a usage error', () async {
    final dir = await run('m');
    await expectLater(
      service.evaluate(dir, options: const ScoringOptions(metrics: ['nope'])),
      throwsA(isA<AibError>().having((e) => e.isUsage, 'isUsage', isTrue)),
    );
  });

  test('a suite path an app recorded inside its sandbox falls back to suites/ above the run', () {
    final root = Directory.systemTemp.createTempSync('aib_locate');
    addTearDown(() => root.deleteSync(recursive: true));
    final suite = File('${root.path}/suites/sysco_v1.yaml')..createSync(recursive: true);
    final run = Directory('${root.path}/results/run-a')..createSync(recursive: true);
    // Exists, but this process may not read it — what a macOS sandbox does.
    final sandboxed = File('${root.path}/sandbox/inputs/suites/sysco_v1.yaml')..createSync(recursive: true);
    Process.runSync('chmod', ['000', sandboxed.path]);
    addTearDown(() => Process.runSync('chmod', ['644', sandboxed.path]));

    expect(AibService.locateSuite(sandboxed.path, run.path), suite.path);
    expect(AibService.locateSuite('/nowhere/suites/sysco_v1.yaml', run.path), suite.path);
    expect(AibService.locateSuite('/nowhere/suites/other.yaml', run.path), isNull);
  });

  test('of two readable suites, the one whose rubrics the judge was asked wins', () {
    final root = Directory.systemTemp.createTempSync('aib_locate');
    addTearDown(() => root.deleteSync(recursive: true));
    // The sandbox copy a later run replaced, and the checkout's suite the
    // run was re-judged with: same file name, other rubric.
    String writeSuite(String dir, String rubric) {
      File(p.join(dir, 'fixtures', 'seed.json')).createSync(recursive: true);
      File(p.join(dir, 'fixtures', 'seed.json')).writeAsStringSync('{}');
      File(p.join(dir, 'rubrics', 'faith.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('rubric: $rubric\ncriteria:\n  - id: a\n    question: Did it happen?\n');
      final file = File(p.join(dir, 'demo.yaml'))
        ..writeAsStringSync('''
suite: demo
schema: aib-task/1.0
defaults:
  budget: { maxSteps: 5, maxWallClockSeconds: 10 }
  fixture: fixtures/seed.json
  criteria:
    - { type: artifactRubric, rubric: rubrics/faith.yaml, artifactKey: meta.done, skipWhenNoArtifact: true }
tasks:
  - id: t
    title: t
    instruction: do it
    successCriteria:
      - { type: traceAssertion, assertion: { kind: called, key: x } }
''');
      return file.path;
    }

    final sandboxed = writeSuite(p.join(root.path, 'sandbox', 'inputs', 'suites'), 'faith_v1');
    final checkout = writeSuite(p.join(root.path, 'suites'), 'faith_v2');
    final run = Directory(p.join(root.path, 'results', 'run-a'))..createSync(recursive: true);
    final judged = JudgeProvenance.forSuite(SuiteLoader.loadFile(checkout).suite!, judgeId: 'j', k: 1).rubrics;

    expect(AibService.locateSuite(sandboxed, run.path), sandboxed, reason: 'without provenance the recorded path stays first');
    expect(AibService.locateSuite(sandboxed, run.path, judgedRubrics: judged), checkout);
    expect(AibService.rubricsMissingFrom(SuiteLoader.loadFile(sandboxed).suite!, JudgeProvenance(judgeId: 'j', k: 1, rubrics: judged)), ['faith_v2']);
  });
}
