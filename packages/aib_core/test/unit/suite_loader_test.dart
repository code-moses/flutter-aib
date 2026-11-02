import 'dart:convert';

import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

const validSuite = '''
suite: demo_v1
schema: aib-task/1.0
defaults:
  repetitions: 5
  budget:
    maxSteps: 25
    maxWallClockSeconds: 180
    maxTokens: 60000
  fixture: fixtures/demo_seed.json

tasks:
  - id: demo.create
    title: "Create entry"
    instruction: Create an entry titled "X".
    tags: [crud, difficulty:easy]
    optimalSteps: 1
    groundTruth:
      finalState:
        - query: "db.items.where(title == 'X')"
          expect:
            count: 1
            fields: { done: false }
    successCriteria:
      - type: finalStateMatch
        weight: 1.0
    partialCredit:
      - condition: "count == 1 && fields.done != false"
        credit: 0.5
        label: "created but wrong state"
  - id: demo.assert
    instruction: Do nothing harmful.
    budget:
      maxSteps: 3
    repetitions: 2
    successCriteria:
      - type: traceAssertion
        assertions:
          - {kind: neverKey, key: state.delete}
''';

void main() {
  inlineRubricTests();
  test('valid suite loads with merged defaults', () {
    final result = SuiteLoader.loadString(validSuite, inlineFixtures: false);
    expect(result.errors, isEmpty);
    final suite = result.suite!;
    expect(suite.name, 'demo_v1');
    expect(suite.defaultRepetitions, 5);
    expect(suite.tasks, hasLength(2));

    final first = suite.taskById('demo.create')!;
    expect(first.budget.maxSteps, 25);
    expect(first.budget.maxTokens, 60000);
    expect(first.optimalSteps, 1);
    expect(first.groundTruth.finalState.single.expectCount, 1);
    expect(first.groundTruth.finalState.single.expectFields['done'], false);
    expect(first.partialCredit.single.credit, 0.5);

    final second = suite.taskById('demo.assert')!;
    expect(second.budget.maxSteps, 3, reason: 'task override wins');
    expect(second.budget.maxWallClockSeconds, 180, reason: 'default merged');
    expect(suite.repetitionsFor(second), 2);
    expect(second.successCriteria.single.config['assertions'], isNotEmpty);

    expect(suite.sourceHash, isNotEmpty);
  });

  test('tasks are self-contained and serializable (wire transfer)', () {
    final suite = SuiteLoader.loadString(validSuite, inlineFixtures: false).suite!;
    final task = suite.taskById('demo.create')!;
    final roundTripped = TaskSpec.fromJson(asJsonMap(jsonDecode(jsonEncode(task.toJson()))));
    expect(roundTripped.id, task.id);
    expect(roundTripped.budget.maxSteps, task.budget.maxSteps);
    expect(roundTripped.successCriteria.single.type, CriterionTypes.finalStateMatch);
  });

  test('validation collects all errors', () {
    const broken = '''
suite: broken
schema: aib-task/0.9
tasks:
  - id: a
    successCriteria: []
  - id: a
    instruction: dup id, no budget
''';
    final result = SuiteLoader.loadString(broken, inlineFixtures: false);
    expect(result.isValid, isFalse);
    expect(result.errors, hasLength(greaterThanOrEqualTo(5)));
    expect(result.errors.join('\n'), contains('schema'));
    expect(result.errors.join('\n'), contains('duplicate'));
    expect(result.errors.join('\n'), contains('instruction'));
    expect(result.errors.join('\n'), contains('budget'));
  });

  test('missing fixture file is an error', () {
    const withFixture = '''
suite: fx
schema: aib-task/1.0
defaults:
  budget: {maxSteps: 5, maxWallClockSeconds: 10}
  fixture: does/not/exist.json
tasks:
  - id: t
    instruction: x
    successCriteria: [{type: finalStateMatch}]
''';
    final result = SuiteLoader.loadString(withFixture, basePath: '/tmp');
    expect(result.isValid, isFalse);
    expect(result.errors.join(), contains('Fixture file not found'));
  });

  test('unknown criterion type is a warning, not an error (P7)', () {
    const custom = '''
suite: custom
schema: aib-task/1.0
defaults:
  budget: {maxSteps: 5, maxWallClockSeconds: 10}
tasks:
  - id: t
    instruction: x
    fixture: fx.json
    successCriteria: [{type: myCustomOracle}]
''';
    final result = SuiteLoader.loadString(custom, inlineFixtures: false);
    expect(result.isValid, isTrue);
    expect(result.warnings.join(), contains('myCustomOracle'));
  });

  test('a task keeps its inline rubric while a default names a file', () {
    // E7's shape: the task's own artifactRubric takes groundTruth, the
    // suite-wide faithfulness one brings its own file. Checking the conflict
    // per *task* rejected every rubric task in sysco_v1.
    const suite = '''
suite: both
schema: aib-task/1.0
defaults:
  budget: {maxSteps: 5, maxWallClockSeconds: 10}
  criteria:
    - type: artifactRubric
      rubric: rubrics/faithfulness_v1.yaml
      artifactKey: [meta.done, meta.abort]
      judgeModel: gpt-oss:20b
      weight: 0.5
tasks:
  - id: t
    instruction: x
    fixture: fx.json
    groundTruth:
      artifactRubric:
        criteria:
          - {id: says_30, question: "Does it say 30?"}
    successCriteria:
      - {type: artifactRubric, artifactKey: meta.done, judgeModel: gpt-oss:20b}
''';
    final result = SuiteLoader.loadString(suite, inlineFixtures: false);
    expect(result.errors, isEmpty);
    expect(result.suite!.taskById('t')!.successCriteria, hasLength(2));
  });

  test('two criteria cannot both claim the same inline rubric', () {
    const suite = '''
suite: ambiguous
schema: aib-task/1.0
defaults:
  budget: {maxSteps: 5, maxWallClockSeconds: 10}
tasks:
  - id: t
    instruction: x
    fixture: fx.json
    groundTruth:
      artifactRubric:
        criteria:
          - {id: a, question: "?"}
    successCriteria:
      - {type: artifactRubric, artifactKey: meta.done, judgeModel: m}
      - {type: artifactRubric, artifactKey: meta.done, judgeModel: m}
''';
    final result = SuiteLoader.loadString(suite, inlineFixtures: false);
    expect(result.isValid, isFalse);
    expect(result.errors.join(), contains('rely on the same'));
  });

  test('defaults.criteria reach every task (E7)', () {
    const shared = '''
suite: shared
schema: aib-task/1.0
defaults:
  budget: {maxSteps: 5, maxWallClockSeconds: 10}
  criteria:
    - type: traceAssertion
      weight: 0.5
      assertions:
        - {kind: noFailedEnvelopes}
tasks:
  - id: t
    instruction: x
    fixture: fx.json
    groundTruth:
      finalState: [{query: db.todos, expect: {count: 1}}]
    successCriteria: [{type: finalStateMatch}]
''';
    final result = SuiteLoader.loadString(shared, inlineFixtures: false);
    expect(result.isValid, isTrue);
    final criteria = result.suite!.taskById('t')!.successCriteria;
    expect(criteria, hasLength(2));
    expect(criteria.first.type, CriterionTypes.finalStateMatch, reason: 'the task declares its own first');
    expect(criteria.last.type, CriterionTypes.traceAssertion);
    expect(criteria.last.weight, 0.5);
  });
}

/// A rubric written into its task, rather than kept in `rubrics/`.
///
/// Both forms have to arrive at the evaluator as `rubricSpec`, because that is
/// the only thing it reads — a run has to be re-evaluable from its trace, with
/// no checkout in reach.
const inlineRubricSuite = '''
suite: rubric_v1
schema: aib-task/1.0
defaults:
  repetitions: 1
  budget: {maxSteps: 5, maxWallClockSeconds: 60, maxTokens: 1000}
  fixture: fixtures/demo_seed.json

tasks:
  - id: answer.count
    instruction: How many articles are there?
    groundTruth:
      artifactRubric:
        criteria:
          - id: states_30
            question: Does the answer state the number 30?
          - id: nothing_invented
            question: Does the answer avoid inventing articles?
            weight: 2
    successCriteria:
      - type: artifactRubric
        artifactKey: meta.done
        judgeModel: gpt-oss:20b
        weight: 1.0
''';

String _withoutRubric(String suite) => suite.replaceFirst(RegExp(r'    groundTruth:\n(      .*\n|          .*\n|        .*\n)+'), '');

void _expectError(SuiteLoadResult result, Pattern needle) {
  expect(result.isValid, isFalse);
  expect(result.errors.join('\n'), contains(needle));
}

void inlineRubricTests() {
  group('inline artifactRubric', () {
    test('is inlined as a rubricSpec named after its task', () {
      final result = SuiteLoader.loadString(inlineRubricSuite, inlineFixtures: false);

      expect(result.errors, isEmpty);
      final criterion = result.suite!.tasks.single.successCriteria.single;
      final spec = RubricSpec.fromJson(asJsonMap(criterion.config['rubricSpec']));
      expect(spec.name, 'answer.count');
      expect(spec.criteria.map((c) => c.id), ['states_30', 'nothing_invented']);
      expect(spec.criteria.last.weight, 2);
    });

    test('an artifactRubric with no rubric at all is an error', () {
      // Left to itself this criterion scores 0 for every agent forever, and
      // says so only in a verdict detail nobody reads until the numbers look
      // wrong. It is a suite mistake, so the suite must not load.
      _expectError(SuiteLoader.loadString(_withoutRubric(inlineRubricSuite), inlineFixtures: false), 'artifactRubric without a rubric');
    });

    test('an inline rubric no criterion reads is an error', () {
      // The criterion names a file, so the task's own rubric is never used.
      // Silently ignoring it is how a declaration becomes a failing task.
      final both = inlineRubricSuite.replaceFirst(
        '      - type: artifactRubric\n',
        '      - type: artifactRubric\n        rubric: rubrics/answer_v1.yaml\n',
      );

      _expectError(SuiteLoader.loadString(both, inlineFixtures: false), 'not used by any criterion');
    });

    test('a criterion without an id cannot be voted on', () {
      final noId = inlineRubricSuite.replaceFirst('          - id: states_30\n            question:', '          - question:');

      _expectError(SuiteLoader.loadString(noId, inlineFixtures: false), 'has no "id"');
    });
  });

  group('a declaration the loader ignores is a declaration that does nothing', () {
    const refusalSuite = '''
suite: refusal_v1
schema: aib-task/1.0
defaults:
  budget:
    maxSteps: 5
    maxWallClockSeconds: 60
  fixture: fixtures/demo_seed.json
tasks:
  - id: refuse.it
    instruction: Delete everything.
    abortIsAnAnswer: true
    typoedKey: 3
    groundTruth:
      finalState:
        - query: db.todos
          expect: {count: 0}
    successCriteria:
      - type: finalStateMatch
        weight: 1.0
''';

    test('abortIsAnAnswer reaches the TaskSpec', () {
      final result = SuiteLoader.loadString(refusalSuite, inlineFixtures: false);
      expect(result.isValid, isTrue, reason: result.errors.join('\n'));
      expect(result.suite!.tasks.single.abortIsAnAnswer, isTrue);
    });

    test('a key nothing reads is warned about, not swallowed', () {
      final result = SuiteLoader.loadString(refusalSuite, inlineFixtures: false);
      expect(result.warnings.join(' '), contains('typoedKey'));
      expect(result.warnings.join(' '), isNot(contains('abortIsAnAnswer')));
    });
  });

  test('budget.targetSeconds is read, inherited, and refused above the hard cap', () {
    SuiteLoadResult load(String budget) => SuiteLoader.loadString('''
suite: s
schema: aib-task/1.0
defaults:
  budget: {maxSteps: 3, maxWallClockSeconds: 60, targetSeconds: 10}
  fixture: f.json
tasks:
  - id: t1
    instruction: open the list
    groundTruth: {finalState: [{query: q, expect: {count: 1}}]}
    successCriteria: [{type: finalStateMatch}]
  - id: t2
    instruction: open the list
    budget: $budget
    groundTruth: {finalState: [{query: q, expect: {count: 1}}]}
    successCriteria: [{type: finalStateMatch}]
''', inlineFixtures: false);

    final ok = load('{targetSeconds: 20}');
    expect(ok.errors, isEmpty);
    expect(ok.warnings.where((w) => w.contains('targetSeconds')), isEmpty);
    expect(ok.suite!.tasks.map((t) => t.budget.targetSeconds), [10, 20]);
    expect(load('{targetSeconds: 90}').errors.single, contains('targetSeconds'));
  });
}
