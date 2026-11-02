import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

/// P3 — termination-quality signals (SPA-Bench's completion metrics).
///
/// `success_rate` says whether an episode worked. These say *how* it ended,
/// which is what separates the strategies: an agent that declares done off a
/// stale observation fails differently from one that never stops.

EpisodeTrace _trace({required String reason}) => EpisodeTrace(
  meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'a', environmentId: 'mock', repetition: 1, startedAt: DateTime.utc(2026)),
  events: [
    const TraceEvent(seq: 0, tUs: 0, type: TraceEventTypes.episodeStart, data: {}),
    TraceEvent(seq: 1, tUs: 1, type: TraceEventTypes.episodeEnd, data: {'reason': reason, 'wallClockMs': 10}),
  ],
);

num? _metric(String name, {required String reason, required Verdict? verdict}) => MetricsRegistry.builtin()[name]!.compute(
  MetricContext(
    trace: _trace(reason: reason),
    verdict: verdict,
  ),
);

void main() {
  final success = Verdict.success();
  final failure = Verdict.failure('goal state not reached');
  final partial = Verdict.partial(0.5, label: 'half');
  final frameworkFault = Verdict.frameworkError('env crashed');

  group('premature_termination', () {
    test('the agent said done and was wrong', () {
      expect(_metric('premature_termination', reason: 'done', verdict: failure), 1);
      expect(
        _metric('premature_termination', reason: 'done', verdict: partial),
        1,
        reason: 'partial credit is not a solved task either',
      );
    });

    test('a correct done is not premature', () {
      expect(_metric('premature_termination', reason: 'done', verdict: success), 0);
    });

    test('running out of budget is a different failure', () {
      expect(_metric('premature_termination', reason: 'budgetSteps', verdict: failure), 0);
    });

    test('an abort is an admission, not a misjudgement', () {
      expect(
        _metric('premature_termination', reason: 'abort', verdict: failure),
        0,
        reason:
            'the agent said it could not do it — it did not claim '
            'success',
      );
    });
  });

  group('overdue_termination', () {
    test('solved but never declared, on every budget kind', () {
      for (final reason in ['budgetSteps', 'budgetTokens', 'timeout']) {
        expect(
          _metric('overdue_termination', reason: reason, verdict: success),
          1,
          reason: reason,
        );
      }
    });

    test('a budget-exhausted failure is not overdue', () {
      expect(_metric('overdue_termination', reason: 'budgetSteps', verdict: failure), 0);
    });

    test('a clean done is not overdue', () {
      expect(_metric('overdue_termination', reason: 'done', verdict: success), 0);
    });
  });

  group('budget_exhaustion', () {
    test('separates budget ends from the agent\'s own decisions', () {
      expect(_metric('budget_exhaustion', reason: 'timeout', verdict: failure), 1);
      expect(_metric('budget_exhaustion', reason: 'done', verdict: success), 0);
      expect(_metric('budget_exhaustion', reason: 'abort', verdict: failure), 0);
    });
  });

  test('framework faults are not attributed to the agent (§5.2)', () {
    for (final name in ['premature_termination', 'overdue_termination']) {
      expect(
        _metric(name, reason: 'frameworkFault', verdict: frameworkFault),
        isNull,
        reason: '$name must stay null so the aggregator skips it entirely',
      );
    }
  });

  test('the rates aggregate with Wilson CIs and reach the report', () {
    EpisodeRecord record(int i, {required String reason, required Verdict v}) => EpisodeRecord(
      runId: 'r',
      episodeId: 'e$i',
      taskId: 't',
      agentId: 'agent',
      repetition: i,
      verdict: v,
      metrics: MetricsRegistry.builtin().computeAll(
        MetricContext(
          trace: _trace(reason: reason),
          verdict: v,
        ),
      ),
    );

    final records = [
      record(1, reason: 'done', v: failure), // premature
      record(2, reason: 'done', v: success),
      record(3, reason: 'budgetSteps', v: success), // overdue
      record(4, reason: 'timeout', v: failure),
    ];
    final rows = Aggregator().aggregate(records);

    AggregateRow row(String metric) => rows.firstWhere((r) => r.taskId == '*' && r.metric == metric);

    expect(row('premature_termination_rate').mean, 0.25);
    expect(row('overdue_termination_rate').mean, 0.25);
    expect(row('budget_exhaustion_rate').mean, 0.5);
    expect(row('premature_termination_rate').ciLow, isNotNull, reason: 'rates always carry a CI (§6.5)');

    final report = MarkdownReporter().render(RunReportData(records: records, aggregates: rows));
    expect(report, contains('## Termination quality'));
    expect(report, contains('| agent | 0.25 | 0.25 | 0.50 |'));
  });
}
