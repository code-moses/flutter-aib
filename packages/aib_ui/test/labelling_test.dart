import 'dart:convert';
import 'dart:io';

import 'package:aib_ui/src/labelling.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A checkout with one suite, a faithfulness rubric and one judged run whose
/// two episodes the rubric judge voted on — one of them a multi-turn episode.
void writeCheckout(String root) {
  Directory(p.join(root, 'suites', 'rubrics')).createSync(recursive: true);
  Directory(p.join(root, 'suites', 'fixtures')).createSync(recursive: true);
  File(p.join(root, 'suites', 'fixtures', 'seed.json')).writeAsStringSync('{}');
  File(p.join(root, 'suites', 'rubrics', 'faith.yaml')).writeAsStringSync('''
rubric: faith_v2
scope: Judge only whether the statement is true of the record.
criteria:
  - id: actions_happened
    question: Did the reported actions happen?
  - id: values_from_record
    question: Are the values from the record?
''');
  File(p.join(root, 'suites', 'demo.yaml')).writeAsStringSync('''
suite: demo
schema: aib-task/1.0
defaults:
  repetitions: 1
  budget:
    maxSteps: 10
    maxWallClockSeconds: 60
  fixture: fixtures/seed.json
  criteria:
    - type: artifactRubric
      rubric: rubrics/faith.yaml
      artifactKey: [meta.done, meta.abort]
      evidence: true
      skipWhenNoArtifact: true
      weight: 0.5
tasks:
  - id: t.subject
    title: Betreff korrigieren
    instruction: Lege eine Aktivität "Wartung Heizung" an.
    successCriteria:
      - type: traceAssertion
        weight: 1.0
        assertion: { kind: called, key: form.open }
''');
  final run = p.join(root, 'results', 'demo-run');
  Directory(p.join(run, 'traces')).createSync(recursive: true);
  File(p.join(run, 'run_manifest.json')).writeAsStringSync(
    jsonEncode({
      'aib': '1.0',
      'runId': 'run-1',
      'createdAt': '2026-10-21T10:00:00',
      'suite': {'name': 'demo', 'hash': 'stale', 'path': 'suites/demo.yaml'},
      'agents': {
        'hybrid': {
          'agentId': 'hybrid',
          'version': 'v',
          'metadata': {'model': 'gemma4:26b'},
        },
      },
      'environment': {'id': 'env', 'version': '1'},
      'repetitions': 2,
      'seed': 42,
      'taskOrder': ['t.subject'],
    }),
  );
  final verdicts = <String, Object?>{};
  for (final rep in [1, 2]) {
    final id = 't.subject__hybrid__rep$rep';
    var seq = 0;
    Map<String, Object?> e(String type, Map<String, Object?> data) => {'seq': seq++, 'tUs': seq, 'type': type, 'data': data};
    final events = [
      {
        'type': 'episode.meta',
        'data': {
          'runId': 'run-1',
          'episodeId': id,
          'taskId': 't.subject',
          'agentId': 'hybrid',
          'environmentId': 'env',
          'repetition': rep,
          'startedAt': '2026-10-21T10:00:00',
        },
      },
      e('episode.start', {
        'task': {'id': 't.subject', 'title': 'Betreff korrigieren'},
      }),
      e('agent.envelope', {
        'seq': 0,
        'key': 'form.open',
        'kind': 'act',
        'payload': {'mask': 7},
      }),
      e('env.result', {
        'seq': 0,
        'status': 'ok',
        'payload': {'draftId': 'd1'},
      }),
      e('agent.envelope', {
        'seq': 1,
        'key': 'meta.done',
        'kind': 'act',
        'payload': {'summary': 'Betreff "Wartung Heizung" gesetzt.'},
      }),
      if (rep == 1)
        e('user.turn', {
          'seq': 1,
          'id': 'korrektur',
          'instruction': 'Nein, der Betreff soll "Wartung Lüftung" heißen.',
          'after': 'Betreff "Wartung Heizung" gesetzt.',
        }),
      if (rep == 1)
        e('agent.envelope', {
          'seq': 2,
          'key': 'meta.done',
          'kind': 'act',
          'payload': {'summary': 'Betreff auf "Wartung Lüftung" geändert.'},
        }),
      e('episode.end', {'reason': 'done', 'message': 'ok', 'wallClockMs': 5}),
    ];
    File(p.join(run, 'traces', '$id.jsonl')).writeAsStringSync(events.map(jsonEncode).join('\n'));
    verdicts[id] = {
      'type': 'partial',
      'score': 0.5,
      'details': {
        'artifactRubric:faith_v2': {
          'score': 0.5,
          'weight': 0.5,
          'detail': 'x',
          'rubric': 'faith_v2',
          'judgeId': 'gpt-oss:20b (judge_v4)',
          'k': 3,
          'votes': {'actions_happened': 3, 'values_from_record': rep == 1 ? 0 : 3},
          'answers': [
            for (var i = 0; i < 3; i++) {'actions_happened': true, 'values_from_record': rep != 1},
          ],
          'rationales': ['because', 'because', 'because'],
        },
      },
    };
  }
  File(p.join(run, 'verdicts.json')).writeAsStringSync(
    jsonEncode({
      'judge': {'judgeId': 'gpt-oss:20b (judge_v4)', 'k': 3, 'pinnedModel': 'gpt-oss:20b'},
      'verdicts': verdicts,
    }),
  );
}

void main() {
  late Directory tmp;
  late Labelling labelling;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('aib_label_test');
    writeCheckout(tmp.path);
    labelling = Labelling(root: tmp.path);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a new set is the sheet aib labelsheet writes, and the library lists it', () {
    final made = labelling.create(runs: ['results/demo-run'], out: 'results/cal-1', sample: 10);
    expect(made['episodes'], 2);
    expect(
      File(p.join(tmp.path, 'results', 'cal-1', 'labels.csv')).readAsStringSync(),
      contains('t.subject__hybrid__rep1,faith_v2:actions_happened,?'),
    );
    final sets = labelling.listSets(p.join(tmp.path, 'results'));
    expect(sets.single['name'], 'cal-1');
    expect(sets.single['answered'], 0);
    expect(sets.single['answers'], 4);
  });

  test('an item carries the task, the later user turn, the scope, the record and the judge', () {
    labelling.create(runs: ['results/demo-run'], out: 'results/cal-1');
    final set = labelling.load(p.join(tmp.path, 'results', 'cal-1'));
    final items = (set['items']! as List).cast<Map<String, Object?>>();
    final first = items.firstWhere((i) => i['labelId'] == 't.subject__hybrid__rep1');
    expect(first['instruction'], contains('Wartung Heizung'));
    expect((first['turns']! as List).single, containsPair('text', contains('Wartung Lüftung')));
    final rubric = (first['rubrics']! as List).single as Map<String, Object?>;
    expect(rubric['scope'], contains('true of the record'));
    expect(rubric['artifact'], {'summary': 'Betreff auf "Wartung Lüftung" geändert.'});
    expect(jsonEncode(rubric['evidence']), contains('Wartung Lüftung'));
    final judge = rubric['judge']! as Map<String, Object?>;
    expect(judge['votes'], {'actions_happened': 3, 'values_from_record': 0});
    expect(judge['rationales'], hasLength(3));
    expect(set['warnings'], contains(contains('suite changed')));
  });

  test('answers and notes are written in place, in the format aib calibrate reads', () {
    labelling.create(runs: ['results/demo-run'], out: 'results/cal-1');
    final dir = p.join(tmp.path, 'results', 'cal-1');
    var counts = labelling.save(dir, labelId: 't.subject__hybrid__rep1', criterion: 'faith_v2:actions_happened', label: 'yes');
    expect(counts, {'answers': 4, 'answered': 1});
    counts = labelling.save(dir, labelId: 't.subject__hybrid__rep1', criterion: 'faith_v2:actions_happened', label: 'no');
    expect(counts['answered'], 1, reason: 'a changed answer replaces its row');
    labelling.save(dir, labelId: 't.subject__hybrid__rep1', note: 'the correction, not the instruction, is the question');
    final csv = File(p.join(dir, 'labels.csv')).readAsStringSync();
    expect(csv, contains('t.subject__hybrid__rep1,faith_v2:actions_happened,no'));
    expect(csv.split('\n').where((l) => l.startsWith('t.subject__hybrid__rep1,faith_v2:actions_happened')), hasLength(1));
    expect(csv, startsWith('# episode_id'), reason: 'the header comment survives');
    final set = labelling.load(dir);
    final first = (set['items']! as List).cast<Map<String, Object?>>().firstWhere((i) => i['labelId'] == 't.subject__hybrid__rep1');
    expect(first['note'], contains('correction'));
    expect(() => labelling.save(dir, labelId: 'x', criterion: 'faith_v2:a', label: 'maybe'), throwsArgumentError);
  });

  test('calibrate refuses while answers are open, and runs aib calibrate once all are given', () async {
    labelling.create(runs: ['results/demo-run'], out: 'results/cal-1');
    final dir = p.join(tmp.path, 'results', 'cal-1');
    await expectLater(labelling.calibrate(dir), throwsA(anything));
    for (final rep in [1, 2]) {
      for (final c in ['actions_happened', 'values_from_record']) {
        labelling.save(dir, labelId: 't.subject__hybrid__rep$rep', criterion: 'faith_v2:$c', label: 'yes');
      }
    }
    final result = await labelling.calibrate(dir);
    expect(result['markdown'], contains('calibration'));
    expect(File(p.join(dir, 'calibration.json')).existsSync(), isTrue);
  });
}
