import 'dart:io';

import 'package:aib_core/aib_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _suite = '''
# A suite.
suite: demo
schema: aib-task/1.0
defaults:
  budget: {maxSteps: 5, maxWallClockSeconds: 30}
  fixture: seed.json
tasks:
  - id: a.public
    title: Public task
    instruction: Do the public thing.
    groundTruth:
      finalState:
        - {query: "db.todos", expect: {count: 1}}
    successCriteria:
      - type: finalStateMatch

  # A comment that belongs to the next task.
  - id: b.held
    title: Held task
    instruction: >
      Do the held thing,
      on two lines.
    tags: [form]
    groundTruth:
      finalState:
        - {query: "db.secret", expect: {count: 42}}
    successCriteria:
      - type: finalStateMatch

  - id: c.public
    instruction: Do the last thing.
    groundTruth:
      finalState:
        - {query: "db.todos", expect: {count: 1}}
    successCriteria:
      - type: finalStateMatch
''';

WithheldSplit _split() => splitWithheld(_suite, {'b.held'}, privateHeader: '# private', stubComment: 'held out');

void main() {
  test('the split keeps title, instruction and tags, and nothing expected', () {
    final split = _split();
    expect(split.withheld, ['b.held']);
    expect(split.public, contains('withheld: true # held out'));
    expect(split.public, contains('on two lines.'));
    expect(split.public, contains('tags: [form]'));
    expect(split.public, isNot(contains('secret')));
    expect(split.public, contains('# A comment that belongs to the next task.'));
    expect(split.private, contains('db.secret'));
    expect(withheldStubs(split.public), ['b.held']);
  });

  test('a merge restores the text byte for byte', () {
    final split = _split();
    final (merged, problems) = mergeWithheld(split.public, split.private);
    expect(problems, isEmpty);
    expect(merged, _suite);
  });

  test('a merge reports a stub without a block and a block without a stub', () {
    final split = _split();
    final (_, missing) = mergeWithheld(split.public, '# private\ntasks:\n');
    expect(missing, [contains('"b.held" has no block')]);
    final (_, orphan) = mergeWithheld(_suite, split.private);
    expect(orphan, [contains('"b.held" has no withheld stub')]);
  });

  test('splitting an unknown or already withheld task throws', () {
    expect(() => splitWithheld(_suite, {'nope'}, privateHeader: '#', stubComment: ''), throwsArgumentError);
    expect(() => splitWithheld(_split().public, {'b.held'}, privateHeader: '#', stubComment: ''), throwsArgumentError);
  });

  group('SuiteLoader', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('aib_withheld');
      for (final sub in ['', 'original']) {
        File(p.join(dir.path, sub, 'seed.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync('{}');
      }
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('with the private file the suite loads and hashes as before the split', () {
      final original = File(p.join(dir.path, 'original', 'demo.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync(_suite);
      final before = SuiteLoader.loadFile(original.path).suite!;

      final split = _split();
      final public = File(p.join(dir.path, 'demo.yaml'))..writeAsStringSync(split.public);
      File(SuiteLoader.privatePath(public.path)).writeAsStringSync(split.private);
      final after = SuiteLoader.loadFile(public.path).suite!;

      expect(after.sourceHash, before.sourceHash);
      expect(after.contentHash, before.contentHash);
      expect(after.tasks.map((t) => t.id), ['a.public', 'b.held', 'c.public']);
    });

    test('without it the withheld task is left out with a warning', () {
      final public = File(p.join(dir.path, 'demo.yaml'))..writeAsStringSync(_split().public);
      final result = SuiteLoader.loadFile(public.path);
      expect(result.isValid, isTrue, reason: result.errors.join('\n'));
      expect(result.suite!.tasks.map((t) => t.id), ['a.public', 'c.public']);
      expect(result.warnings, [contains('1 withheld task(s) left out (b.held)')]);
    });

    test('a stale private file is an error, not a silent partial suite', () {
      final public = File(p.join(dir.path, 'demo.yaml'))..writeAsStringSync(_split().public);
      File(SuiteLoader.privatePath(public.path)).writeAsStringSync('# private\ntasks:\n');
      expect(SuiteLoader.loadFile(public.path).errors, [contains('has no block in the private file')]);
    });

    test('references add the scripts of their private sibling', () {
      final refs = File(p.join(dir.path, 'refs.yaml'))..writeAsStringSync('agentId: ref\nscripts:\n  a.public: []\n');
      File(SuiteLoader.privatePath(refs.path)).writeAsStringSync('scripts:\n  b.held: [{key: x, kind: act}]\n');
      final json = SuiteLoader.loadReferences(refs.path);
      expect((json['scripts'] as Map).keys, ['a.public', 'b.held']);
      expect(json['agentId'], 'ref');

      File(SuiteLoader.privatePath(refs.path)).writeAsStringSync('scripts:\n  a.public: []\n');
      expect(() => SuiteLoader.loadReferences(refs.path), throwsFormatException);
    });
  });
}
