import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:test/test.dart';

const _fixture = FixtureRef(
  id: 'seed',
  data: {
    'db': {
      'todos': [
        {'title': 'Existing', 'completed': false},
      ],
    },
  },
);

TaskSpec _task(String id, FinalStateExpectation expectation) => TaskSpec(
  id: id,
  title: id,
  instruction: 'complete "Existing"',
  budget: const Budget(maxSteps: 5, maxWallClockSeconds: 30),
  fixture: _fixture,
  groundTruth: GroundTruth(finalState: [expectation]),
  successCriteria: const [SuccessCriterion(type: CriterionTypes.finalStateMatch)],
);

const _query = "db.todos.where(title == 'Existing')";

final _complete = Envelope(
  key: 'state.update',
  kind: .act,
  payload: {
    'path': 'db.todos',
    'where': {'title': 'Existing'},
    'set': {'completed': true},
  },
);

void main() {
  final references = ScriptedAgent(
    agentId: 'reference',
    scripts: {
      for (final id in ['sound', 'blind', 'lax']) id: [_complete],
    },
  );
  final selftest = OracleSelfTest(environment: MockEnvironment(), references: references);

  test('a sound oracle passes its reference and fails doing nothing', () async {
    final check = await selftest.check(_task('sound', const FinalStateExpectation(query: _query, expectCount: 1, expectFields: {'completed': true})));
    expect(check.problems, isEmpty);
    expect(check.probe('reference')!.verdict.type, VerdictType.success);
  });

  test('a milestone the reference never reaches is a problem', () async {
    final task = _task('sound', const FinalStateExpectation(query: _query, expectFields: {'completed': true}));
    final withMilestone = TaskSpec(
      id: task.id,
      title: task.title,
      instruction: task.instruction,
      budget: task.budget,
      fixture: task.fixture,
      successCriteria: task.successCriteria,
      groundTruth: GroundTruth(
        finalState: task.groundTruth.finalState,
        milestones: const [
          MilestoneSpec(
            id: 'never',
            expectation: FinalStateExpectation(query: _query, expectCount: 2),
          ),
        ],
      ),
    );
    final check = await selftest.check(withMilestone);
    expect(check.problems.single, contains('0% of the milestones'));
  });

  test('an oracle that cannot see the answer fails its reference', () async {
    final check = await selftest.check(_task('blind', const FinalStateExpectation(query: _query, expectFields: {'entries.completed': true})));
    expect(check.problems.single, startsWith('reference scores 0.00'));
  });

  test('an oracle the initial state satisfies credits doing nothing', () async {
    final check = await selftest.check(_task('lax', const FinalStateExpectation(query: _query, expectCount: 1)));
    expect(check.problems, contains('null.done succeeds — the oracle credits doing nothing'));
  });

  test('a task without a reference is still probed with doing nothing', () async {
    final check = await selftest.check(_task('unreferenced', const FinalStateExpectation(query: _query, expectCount: 1)));
    expect(check.hasReference, isFalse);
    expect(check.problems, isNotEmpty);
  });
}
