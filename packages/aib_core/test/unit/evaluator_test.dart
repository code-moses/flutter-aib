import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

/// Builds a minimal synthetic trace with a final.state event — evaluators
/// operate on traces only (P6), so no engine is needed here.
EpisodeTrace traceWith({required List<StateQueryResult> results, String endReason = 'done', List<TraceEvent> extraEvents = const []}) {
  var seq = 0;
  TraceEvent event(String type, JsonMap data) => TraceEvent(seq: seq++, tUs: seq * 1000, type: type, data: data);
  return EpisodeTrace(
    meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'a', environmentId: 'env', repetition: 1, startedAt: DateTime.utc(2026)),
    events: [
      event(TraceEventTypes.episodeStart, {}),
      ...extraEvents.map((e) => event(e.type, e.data)),
      event(TraceEventTypes.finalState, FinalStateSnapshot(results: results).toJson()),
      event(TraceEventTypes.episodeEnd, {'reason': endReason, 'wallClockMs': 10}),
    ],
  );
}

TaskSpec task({
  List<SuccessCriterion> criteria = const [SuccessCriterion(type: CriterionTypes.finalStateMatch)],
  List<PartialCreditRule> partialCredit = const [],
  List<FinalStateExpectation> expectations = const [
    FinalStateExpectation(query: 'db.items', expectCount: 1, expectFields: {'title': 'X'}),
  ],
  bool abortIsAnAnswer = false,
}) => TaskSpec(
  id: 't',
  title: 't',
  instruction: 'do',
  budget: const Budget(maxSteps: 10, maxWallClockSeconds: 10),
  fixture: const FixtureRef(id: 'f', data: {}),
  groundTruth: GroundTruth(finalState: expectations),
  successCriteria: criteria,
  partialCredit: partialCredit,
  abortIsAnAnswer: abortIsAnAnswer,
);

void main() {
  _nestedFieldExpectations();
  _countExpectations();

  final evaluator = EpisodeEvaluator();

  Future<Verdict> judge(TaskSpec t, EpisodeTrace trace) => evaluator.judge(EvaluationContext(task: t, trace: trace));

  group('finalStateMatch', () {
    test('count and fields match -> success', () async {
      final verdict = await judge(
        task(),
        traceWith(
          results: const [
            StateQueryResult(
              query: 'db.items',
              count: 1,
              items: [
                {'title': 'X', 'other': 1},
              ],
            ),
          ],
        ),
      );
      expect(verdict.type, VerdictType.success);
    });

    test('wrong count -> failure with reason', () async {
      final verdict = await judge(task(), traceWith(results: const [StateQueryResult(query: 'db.items', count: 0)]));
      expect(verdict.type, VerdictType.failure);
      expect(verdict.reason, contains('expected count 1'));
    });

    test('field mismatch -> failure; partial rule can upgrade', () async {
      final withRule = task(
        partialCredit: const [PartialCreditRule(condition: "count == 1 && fields.title != 'X'", credit: 0.5, label: 'wrong title')],
      );
      final trace = traceWith(
        results: const [
          StateQueryResult(
            query: 'db.items',
            count: 1,
            items: [
              {'title': 'Y'},
            ],
          ),
        ],
      );
      expect((await judge(task(), trace)).type, VerdictType.failure);
      final upgraded = await judge(withRule, trace);
      expect(upgraded.type, VerdictType.partial);
      expect(upgraded.score, 0.5);
      expect(upgraded.label, 'wrong title');
    });

    test('multiple expectations -> fractional criterion score -> partial', () async {
      final multi = task(
        expectations: const [
          FinalStateExpectation(query: 'a', expectCount: 1),
          FinalStateExpectation(query: 'b', expectCount: 1),
        ],
      );
      final verdict = await judge(
        multi,
        traceWith(
          results: const [
            StateQueryResult(query: 'a', count: 1),
            StateQueryResult(query: 'b', count: 0),
          ],
        ),
      );
      expect(verdict.type, VerdictType.partial);
      expect(verdict.score, 0.5);
    });
  });

  group('traceAssertion', () {
    final assertingTask = task(
      criteria: const [
        SuccessCriterion(type: CriterionTypes.finalStateMatch, weight: 0.8),
        SuccessCriterion(
          type: CriterionTypes.traceAssertion,
          weight: 0.2,
          config: {
            'assertions': [
              {'kind': 'neverKey', 'key': 'state.delete'},
              {'kind': 'noFailedEnvelopes'},
            ],
          },
        ),
      ],
    );

    TraceEvent envelope(String key, {String kind = 'act', int seq = 0}) =>
        TraceEvent(seq: 0, tUs: 0, type: TraceEventTypes.agentEnvelope, data: {'seq': seq, 'key': key, 'kind': kind, 'payload': {}});
    TraceEvent result(String status, {int seq = 0}) =>
        TraceEvent(seq: 0, tUs: 0, type: TraceEventTypes.envResult, data: {'seq': seq, 'status': status, 'payload': {}});

    const okState = [
      StateQueryResult(
        query: 'db.items',
        count: 1,
        items: [
          {'title': 'X'},
        ],
      ),
    ];

    test('assertions hold -> success', () async {
      final verdict = await judge(assertingTask, traceWith(results: okState, extraEvents: [envelope('state.insert'), result('ok')]));
      expect(verdict.type, VerdictType.success);
    });

    test('violated assertion -> weighted partial', () async {
      final verdict = await judge(assertingTask, traceWith(results: okState, extraEvents: [envelope('state.delete'), result('ok')]));
      expect(verdict.type, VerdictType.partial);
      expect(verdict.score, closeTo(0.8, 1e-9));
    });
  });

  group('termination semantics (ADR 0003)', () {
    const okState = [
      StateQueryResult(
        query: 'db.items',
        count: 1,
        items: [
          {'title': 'X'},
        ],
      ),
    ];

    test('abort -> failure even with correct state', () async {
      final verdict = await judge(task(), traceWith(results: okState, endReason: 'abort'));
      expect(verdict.type, VerdictType.failure);
    });

    test('abort scores its criteria when the task says a refusal is an answer', () async {
      final verdict = await judge(task(abortIsAnAnswer: true), traceWith(results: okState, endReason: 'abort'));
      expect(verdict.type, VerdictType.success);
    });

    test('abortIsAnAnswer does not excuse a wrong final state', () async {
      final verdict = await judge(task(abortIsAnAnswer: true), traceWith(results: const [], endReason: 'abort'));
      expect(verdict.type, VerdictType.failure);
    });

    test('budget exhaustion still evaluates state', () async {
      final verdict = await judge(task(), traceWith(results: okState, endReason: 'budgetSteps'));
      expect(verdict.type, VerdictType.success);
    });

    test('framework fault -> error verdict', () async {
      final verdict = await judge(task(), traceWith(results: const [], endReason: 'frameworkFault'));
      expect(verdict.type, VerdictType.error);
    });
  });
}

void _nestedFieldExpectations() {
  group('a ground-truth field path reaches into the row', () {
    StateQueryResult draft({Object? subject}) => StateQueryResult(
      query: 'drafts.where(maskId == 7)',
      count: 1,
      items: [
        {
          'id': 117230477835737840,
          'maskId': 7,
          'entries': {'Subject': subject, 'AllDay': false},
        },
      ],
    );

    const expectation = FinalStateExpectation(
      query: 'drafts.where(maskId == 7)',
      expectCount: 1,
      expectFields: {'entries.Subject': 'Wartung Heizung'},
    );

    test('a nested value satisfies it', () {
      // Before this resolved paths, `item['entries.Subject']` was null and the
      // oracle said "got null" — which reads exactly like the app never having
      // set the value. form.fill.activity and its English twin could not have
      // passed in any run ever recorded.
      expect(expectation.mismatch(draft(subject: 'Wartung Heizung')), isNull);
    });

    test('a nested value that is wrong still fails, and says what it found', () {
      expect(expectation.mismatch(draft(subject: 'Etwas anderes')), contains('expected Wartung Heizung, got Etwas anderes'));
    });

    test('a missing nested value fails', () {
      expect(expectation.mismatch(draft()), contains('got null'));
    });

    test('a literal key containing a dot wins over the path', () {
      const literal = FinalStateExpectation(query: 'q', expectFields: {'a.b': 'flat'});
      final result = StateQueryResult(
        query: 'q',
        count: 1,
        items: [
          {
            'a.b': 'flat',
            'a': {'b': 'nested'},
          },
        ],
      );
      expect(literal.mismatch(result), isNull);
    });
  });
}

void _countExpectations() {
  group('a count expectation can be exact or a lower bound', () {
    test('minCount is a lower bound, count stays exact', () {
      StateQueryResult asked(int n) => StateQueryResult(
        query: 'clarifications',
        count: n,
        items: [
          for (var i = 0; i < n; i++) const {'type': 'pick'},
        ],
      );

      const atLeastOne = FinalStateExpectation(query: 'clarifications', expectMinCount: 1);
      expect(atLeastOne.mismatch(asked(1)), isNull);
      expect(atLeastOne.mismatch(asked(2)), isNull);
      expect(atLeastOne.mismatch(asked(0)), contains('expected count >= 1, got 0'));

      const exactlyOne = FinalStateExpectation(query: 'clarifications', expectCount: 1);
      expect(exactlyOne.mismatch(asked(2)), contains('expected count 1, got 2'));
    });

    test('minCount survives a round trip through JSON', () {
      const expectation = FinalStateExpectation(query: 'clarifications', expectMinCount: 1);
      final restored = FinalStateExpectation.fromJson(expectation.toJson());
      expect(restored.expectMinCount, 1);
      expect(restored.expectCount, isNull);
    });
  });
}
