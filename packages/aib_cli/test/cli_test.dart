import 'dart:convert';
import 'dart:io';

import 'package:aib_cli/aib_cli.dart';
import 'package:args/command_runner.dart';
import 'package:aib_core/aib_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// End-to-end smoke test of the CLI pipeline against the demo suite:
/// validate -> run -> evaluate -> report (spec §9). Runs in-process so it works
/// as a plain `dart test`.
void main() {
  // Repo root = two levels above this package.
  final repoRoot = Directory.current.path.endsWith('aib_cli') ? p.normalize(p.join(Directory.current.path, '..', '..')) : Directory.current.path;
  final suitePath = p.join(repoRoot, 'suites', 'mock_v1.yaml');
  final scriptPath = p.join(repoRoot, 'suites', 'scripts', 'mock_scripted.yaml');

  late Directory outDir;

  setUp(() async {
    outDir = await Directory.systemTemp.createTemp('aib_cli_');
  });

  tearDown(() => outDir.delete(recursive: true));

  test('evaluate --field scores a shipped trace without a suite', () async {
    final meta = EpisodeMeta(
      runId: 'field',
      episodeId: 'live-1',
      taskId: 'live',
      agentId: 'hybrid',
      environmentId: 'sysco_mobile',
      repetition: 0,
      startedAt: DateTime.utc(2026, 9, 14),
    );
    // The shape the app's runtime records: no payloadBytes, no handleMs.
    final events = [
      const TraceEvent(seq: 0, tUs: 0, type: 'episode.start', data: {}),
      const TraceEvent(seq: 1, tUs: 10, type: 'agent.envelope', data: {'seq': 0, 'key': 'intents.invoke', 'kind': 'act', 'payload': {}}),
      const TraceEvent(seq: 2, tUs: 20, type: 'env.result', data: {'seq': 0, 'status': 'ok', 'payload': {}}),
      const TraceEvent(seq: 3, tUs: 30, type: 'agent.envelope', data: {'seq': 1, 'key': 'meta.done', 'kind': 'act', 'payload': {}}),
      const TraceEvent(seq: 4, tUs: 40, type: 'episode.end', data: {'reason': 'done'}),
    ];
    File(p.join(outDir.path, 'live-1.jsonl')).writeAsStringSync(TraceCodec.encode(EpisodeTrace(meta: meta, events: events)));
    File(p.join(outDir.path, 'notes.jsonl')).writeAsStringSync('not a trace');

    expect(await buildRunner().run(['evaluate', '--field', '--run', outDir.path]), 0);

    final lines = File(p.join(outDir.path, 'field_metrics.csv')).readAsLinesSync();
    final header = lines.first.split(',');
    expect(header.take(3), ['episodeId', 'agentId', 'endReason']);
    final row = lines[1].split(',');
    expect(row.take(3), ['live-1', 'hybrid', 'done']);
    expect(row[header.indexOf('success')], isEmpty);
  });

  test('run refuses two agents that share an id (R10)', () async {
    // Traces are keyed by agent id: the second silently replaced the first.
    expect(
      await buildRunner().run([
        'run',
        '--suite',
        suitePath,
        '--agents',
        'scripted=$scriptPath,scripted=$scriptPath',
        '--env',
        'mock',
        '--out',
        outDir.path,
      ]),
      64,
    );
    expect(File(p.join(outDir.path, RunStore.manifestFile)).existsSync(), isFalse);
  });

  test('compare as a sweep creates its --out directory (R22)', () async {
    for (final name in ['a', 'b', 'c']) {
      expect(
        await buildRunner().run([
          'run',
          '--suite',
          suitePath,
          '--agents',
          'scripted=$scriptPath',
          '--env',
          'mock',
          '--reps',
          '1',
          '--out',
          p.join(outDir.path, name),
        ]),
        0,
      );
      expect(await buildRunner().run(['evaluate', '--run', p.join(outDir.path, name)]), 0);
    }
    final out = p.join(outDir.path, 'not', 'yet', 'there');
    expect(
      await buildRunner().run([
        'compare',
        '--runs',
        p.join(outDir.path, 'a'),
        '--runs',
        p.join(outDir.path, 'b'),
        '--runs',
        p.join(outDir.path, 'c'),
        '--allow-any-diff',
        '--out',
        out,
      ]),
      0,
    );
    expect(File(p.join(out, 'sweep.md')).existsSync(), isTrue);
  });

  test('validate accepts the demo suite', () async {
    expect(await buildRunner().run(['validate', '--suite', suitePath]), 0);
  });

  test('run -> evaluate -> report pipeline produces all artifacts', () async {
    final runner = buildRunner();
    expect(
      await runner.run(['run', '--suite', suitePath, '--agents', 'scripted=$scriptPath', '--env', 'mock', '--reps', '2', '--out', outDir.path]),
      0,
    );
    expect(File(p.join(outDir.path, 'run_manifest.json')).existsSync(), isTrue);
    // Derived from the suite rather than hard-coded, so adding a task to the
    // demo suite does not break the pipeline test.
    final taskCount = SuiteLoader.loadFile(suitePath).suite!.tasks.length;
    final expectedEpisodes = taskCount * 2; // 1 agent × 2 reps
    final traces = Directory(p.join(outDir.path, 'traces')).listSync().where((f) => f.path.endsWith('.jsonl'));
    expect(traces, hasLength(expectedEpisodes), reason: '$taskCount tasks × 1 agent × 2 reps');

    expect(await runner.run(['evaluate', '--run', outDir.path]), 0);
    final store = RunStore(outDir);
    final verdicts = store.readVerdicts();
    expect(verdicts, hasLength(expectedEpisodes));
    expect(
      verdicts.values.every((v) => v.type == .success),
      isTrue,
      reason:
          'the scripted reference episodes must all succeed: '
          '${verdicts.map((k, v) => MapEntry(k, '${v.type.name}:${v.reason}'))}',
    );
    expect(File(p.join(outDir.path, 'metrics.csv')).existsSync(), isTrue);

    expect(await runner.run(['report', '--run', outDir.path, '--format', 'md,json,csv']), 0);
    final markdown = File(p.join(outDir.path, 'report.md')).readAsStringSync();
    expect(markdown, contains('scripted-mock'));
    expect(markdown, contains('success_rate'));
  });

  test('evaluate finds the suite when the manifest path is relative to '
      'another working directory (P6)', () async {
    // Live runs execute from the app package, so the manifest records a path
    // like `../../suites/todo_v1.yaml`, which must not depend on the current
    // directory.
    final runner = buildRunner();
    final runDir = Directory(p.join(repoRoot, 'results', p.basename(outDir.path)));
    addTearDown(() => runDir.delete(recursive: true));
    expect(
      await runner.run(['run', '--suite', suitePath, '--agents', 'scripted=$scriptPath', '--env', 'mock', '--reps', '1', '--out', runDir.path]),
      0,
    );
    // Rewrite the recorded path exactly as a run from apps/todo_app leaves it.
    final manifestFile = File(p.join(runDir.path, RunStore.manifestFile));
    manifestFile.writeAsStringSync(manifestFile.readAsStringSync().replaceAll(suitePath, p.join('..', '..', 'suites', 'mock_v1.yaml')));

    expect(await buildRunner().run(['evaluate', '--run', runDir.path]), 0);
    expect(RunStore(runDir).readVerdicts(), isNotEmpty);
  });

  test('compare aligns two runs and writes comparison.md', () async {
    final runner = buildRunner();
    final dirA = Directory(p.join(outDir.path, 'runA'));
    final dirB = Directory(p.join(outDir.path, 'runB'));
    for (final dir in [dirA, dirB]) {
      expect(
        await runner.run(['run', '--suite', suitePath, '--agents', 'scripted=$scriptPath', '--env', 'mock', '--reps', '2', '--out', dir.path]),
        0,
      );
    }
    expect(await buildRunner().run(['compare', '--runs', dirA.path, '--runs', dirB.path, '--out', outDir.path]), 0);
    final markdown = File(p.join(outDir.path, 'comparison.md')).readAsStringSync();
    expect(markdown, contains('Run comparison'));
    expect(markdown, contains('weighted_score'));
    // Identical deterministic runs -> no significant score differences
    // (no bolded delta cells; the legend line legitimately contains **).
    final scoreRows = markdown.split('\n').where((l) => l.startsWith('|') && l.contains('weighted_score'));
    expect(scoreRows, isNotEmpty);
    expect(scoreRows.any((l) => l.contains('**')), isFalse);
  });

  test('compare refuses runs that differ in more than --vary names', () async {
    final dirs = [
      for (final seed in ['1', '2']) p.join(outDir.path, 'seed$seed'),
    ];
    for (final (i, dir) in dirs.indexed) {
      expect(
        await buildRunner().run([
          'run',
          '--suite',
          suitePath,
          '--agents',
          'scripted=$scriptPath',
          '--env',
          'mock',
          '--reps',
          '1',
          '--seed',
          '${i + 1}',
          '--out',
          dir,
        ]),
        0,
      );
    }
    final compare = ['compare', '--runs', dirs[0], '--runs', dirs[1], '--out', outDir.path];
    expect(await buildRunner().run(compare), 1);
    expect(await buildRunner().run([...compare, '--vary', 'seed']), 0);
    expect(File(p.join(outDir.path, 'comparison.md')).readAsStringSync(), contains('| `seed` | 1 | 2 | yes |'));
  });

  test('report renders html alongside md', () async {
    final runner = buildRunner();
    expect(
      await runner.run(['run', '--suite', suitePath, '--agents', 'scripted=$scriptPath', '--env', 'mock', '--reps', '1', '--out', outDir.path]),
      0,
    );
    expect(await runner.run(['report', '--run', outDir.path, '--format', 'html']), 0);
    final html = File(p.join(outDir.path, 'report.html')).readAsStringSync();
    expect(html, contains('<!doctype html>'));
    expect(html, contains('scripted-mock'));
  });

  group('a suite that needs a judge, run without one', () {
    late File suite;
    late String runDir;

    setUp(() async {
      // Beside the original so the relative fixture path still resolves.
      suite = File(p.join(repoRoot, 'suites', '.cli_rubric_${p.basename(outDir.path)}.yaml'))
        ..writeAsStringSync(
          File(suitePath).readAsStringSync().replaceFirst(
            '      - type: finalStateMatch\n        weight: 1.0\n',
            '      - type: finalStateMatch\n        weight: 1.0\n'
                '      - type: artifactRubric\n        weight: 0.1\n'
                '        rubric: rubrics/dashboard_v1.yaml\n'
                '        artifactKey: meta.done\n',
          ),
        );
      runDir = outDir.path;
      expect(
        await buildRunner().run(['run', '--suite', suite.path, '--agents', 'scripted=$scriptPath', '--env', 'mock', '--reps', '1', '--out', runDir]),
        0,
      );
    });

    tearDown(() => suite.delete());

    test('evaluate refuses instead of zeroing the rubrics', () async {
      expect(await buildRunner().run(['evaluate', '--run', runDir]), 1);
      expect(File(p.join(runDir, RunStore.verdictsFile)).existsSync(), isFalse);
    });

    test('evaluate --allow-missing-judge scores rubrics as 0', () async {
      expect(await buildRunner().run(['evaluate', '--run', runDir, '--allow-missing-judge']), 0);
      expect(RunStore(Directory(runDir)).readVerdicts(), isNotEmpty);
    });

    test('report reuses verdicts.json and leaves it untouched', () async {
      final store = RunStore(Directory(runDir));
      final ids = store.readTraces().map((t) => t.meta.episodeId);
      store.writeVerdicts({for (final id in ids) id: Verdict.success()});
      final before = File(p.join(runDir, RunStore.verdictsFile)).readAsStringSync();

      expect(await buildRunner().run(['report', '--run', runDir, '--format', 'json']), 0);
      expect(File(p.join(runDir, RunStore.verdictsFile)).readAsStringSync(), before);
      final records = (jsonDecode(File(p.join(runDir, 'report.json')).readAsStringSync()) as Map)['episodes'] as List;
      expect(records.map((r) => (r as Map)['verdict']['type']), everyElement('success'));
    });

    test('report without verdicts.json refuses', () async {
      expect(await buildRunner().run(['report', '--run', runDir]), 1);
    });

    test('labelsheet samples judged episodes; calibrate pools the runs by '
        'name', () async {
      // Two runs of one suite, judged by the same (recorded) judge.
      final second = p.join(outDir.path, 'second');
      expect(
        await buildRunner().run(['run', '--suite', suite.path, '--agents', 'scripted=$scriptPath', '--env', 'mock', '--reps', '1', '--out', second]),
        0,
      );
      final first = p.join(outDir.path, 'first');
      Directory(first).createSync();
      for (final entity in Directory(runDir).listSync()) {
        if (p.basename(entity.path) case 'first' || 'second') continue;
        entity.renameSync(p.join(first, p.basename(entity.path)));
      }
      final voted = Verdict(
        type: .partial,
        score: 0.75,
        details: const {
          'artifactRubric:dashboard_v1': {
            'rubric': 'dashboard_v1',
            'k': 1,
            'votes': {'all_open_tasks': 1, 'no_completed_tasks': 0, 'grouped_by_due': 1, 'nothing_invented': 1},
          },
        },
      );
      for (final dir in [first, second]) {
        final store = RunStore(Directory(dir));
        store.writeVerdicts({for (final t in store.readTraces()) t.meta.episodeId: voted});
      }

      final sheet = p.join(outDir.path, 'sheet');
      final labelsheet = ['labelsheet', '--run', first, '--run', second, '--out', sheet];
      expect(await buildRunner().run(labelsheet), 0);
      final csv = File(p.join(sheet, 'labels.csv'));
      final rows = csv.readAsLinesSync().where((l) => !l.startsWith('#')).toList();
      expect(rows, isNotEmpty);
      expect(rows, everyElement(endsWith(',?')));
      expect(rows.first, startsWith('first/'));
      expect(rows.any((r) => r.startsWith('second/')), isTrue);
      expect(rows.first, contains(',dashboard_v1:'));
      // The sheet never shows the judge's answer.
      expect(File(p.join(sheet, 'labels.md')).readAsStringSync(), isNot(contains('votes')));

      final calibrate = ['calibrate', '--run', first, '--run', second, '--labels', csv.path, '--out', sheet];
      // An unlabelled row is refused, not counted as a no.
      expect(await buildRunner().run(calibrate), 1);

      csv.writeAsStringSync(csv.readAsStringSync().replaceAll(RegExp(r',\?$', multiLine: true), ',yes'));
      // Labels exist now: a second sheet must not overwrite them.
      expect(await buildRunner().run(labelsheet), 1);

      expect(await buildRunner().run(calibrate), 0);
      final result = jsonDecode(File(p.join(sheet, 'calibration.json')).readAsStringSync()) as Map;
      final perCriterion = result['perCriterion'] as Map;
      expect(perCriterion['n'], rows.length);
      // The judge said no to no_completed_tasks everywhere; the labels say yes.
      expect(perCriterion['disagreements'] as List, everyElement(endsWith('dashboard_v1:no_completed_tasks')));
      expect((perCriterion['disagreements'] as List).length, rows.length ~/ 4);
    });
  });

  test('selftest passes the demo suite against its references', () async {
    expect(await buildRunner().run(['selftest', '--suite', suitePath, '--reference', scriptPath, '--require-references']), 0);
  });

  test('--metrics adds a provider and records it; an unknown one is refused', () async {
    expect(
      await buildRunner().run([
        'run',
        '--suite',
        suitePath,
        '--agents',
        'scripted=$scriptPath',
        '--env',
        'mock',
        '--reps',
        '2',
        '--out',
        outDir.path,
      ]),
      0,
    );
    expect(await buildRunner().run(['evaluate', '--run', outDir.path, '--metrics', 'consistency']), 0);
    expect(File(p.join(outDir.path, RunStore.verdictsFile)).readAsStringSync(), contains('"metricProviders"'));
    await expectLater(buildRunner().run(['evaluate', '--run', outDir.path, '--metrics', 'nope']), throwsA(isA<UsageException>()));
  });

  test('metrics and intents print their tables', () async {
    expect(await buildRunner().run(['metrics']), 0);
    expect(
      await buildRunner().run([
        'run',
        '--suite',
        suitePath,
        '--agents',
        'scripted=$scriptPath',
        '--env',
        'mock',
        '--reps',
        '1',
        '--out',
        outDir.path,
      ]),
      0,
    );
    expect(await buildRunner().run(['intents', '--run', outDir.path, '--out', outDir.path]), 0);
    expect(File(p.join(outDir.path, 'intents.md')).readAsStringSync(), contains('`state.update`'));
  });

  test('validate rejects a broken suite with exit code 1', () async {
    final broken = File(p.join(outDir.path, 'broken.yaml'))..writeAsStringSync('suite: x\nschema: wrong\ntasks: []\n');
    expect(await buildRunner().run(['validate', '--suite', broken.path]), 1);
  });
}
