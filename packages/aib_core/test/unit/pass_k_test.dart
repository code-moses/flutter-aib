import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

/// P2 — pass^k reliability (τ-bench, arXiv 2406.12045).
///
/// P3 promises that non-determinism is *quantified* rather than averaged
/// away. pass^k is what makes that promise checkable: it separates an agent
/// that solves a task reliably from one that hits the same mean by chance.

EpisodeRecord _episode(String taskId, int repetition, {required VerdictType type}) => EpisodeRecord(
  runId: 'r',
  episodeId: '$taskId-$repetition',
  taskId: taskId,
  agentId: 'agent',
  repetition: repetition,
  verdict: switch (type) {
    .success => const Verdict(type: .success, score: 1),
    .failure => Verdict.failure('nope'),
    .partial => const Verdict(type: .partial, score: 0.5),
    .error => Verdict.frameworkError('env crashed'),
  },
  metrics: const {},
);

/// n episodes of [taskId], the first [successes] of which succeed.
List<EpisodeRecord> _task(String taskId, {required int successes, required int n}) => [
  for (var i = 0; i < n; i++) _episode(taskId, i + 1, type: i < successes ? VerdictType.success : VerdictType.failure),
];

AggregateRow? _row(List<AggregateRow> rows, String taskId, String metric) {
  for (final row in rows) {
    if (row.agentId == 'agent' && row.taskId == taskId && row.metric == metric) {
      return row;
    }
  }
  return null;
}

void main() {
  group('Stats.passHatK', () {
    test('pass^1 is the plain success rate', () {
      expect(Stats.passHatK(3, 5, 1), closeTo(0.6, 1e-12));
      expect(Stats.passHatK(0, 5, 1), 0);
      expect(Stats.passHatK(5, 5, 1), 1);
    });

    test('C(c,k)/C(n,k) matches hand-computed reference values', () {
      // 3 of 5 succeed: C(3,2)/C(5,2) = 3/10; C(3,3)/C(5,3) = 1/10.
      expect(Stats.passHatK(3, 5, 2), closeTo(0.3, 1e-12));
      expect(Stats.passHatK(3, 5, 3), closeTo(0.1, 1e-12));
      // 4 of 5: C(4,2)/C(5,2) = 6/10.
      expect(Stats.passHatK(4, 5, 2), closeTo(0.6, 1e-12));
    });

    test('fewer successes than draws is impossible', () {
      expect(Stats.passHatK(3, 5, 4), 0);
      expect(Stats.passHatK(0, 5, 2), 0);
    });

    test('a deterministic agent does not decay', () {
      for (var k = 1; k <= 5; k++) {
        expect(Stats.passHatK(5, 5, k), 1, reason: 'consistent success stays 1 for every k');
      }
    });

    test('is not success_rate^k — the estimator draws without replacement', () {
      // 0.6^2 = 0.36, but the unbiased estimator over 5 episodes is 0.3.
      expect(Stats.passHatK(3, 5, 2), isNot(closeTo(0.36, 1e-6)));
      expect(Stats.passHatK(3, 5, 2), closeTo(0.3, 1e-12));
    });

    test('rejects k outside [1, n]', () {
      expect(() => Stats.passHatK(3, 5, 0), throwsArgumentError);
      expect(() => Stats.passHatK(3, 5, 6), throwsArgumentError);
      expect(Stats.passHatK(0, 0, 1), isNaN);
    });
  });

  group('Aggregator pass_k rows', () {
    test('emits pass_1..pass_n per task and averages them per agent', () {
      // Two tasks, both with success_rate 0.5 over 4 repetitions, but the
      // aggregate is what matters here.
      final rows = Aggregator().aggregate([..._task('t1', successes: 2, n: 4), ..._task('t2', successes: 4, n: 4)]);

      expect(_row(rows, 't1', 'pass_1')!.mean, closeTo(0.5, 1e-12));
      // C(2,2)/C(4,2) = 1/6.
      expect(_row(rows, 't1', 'pass_2')!.mean, closeTo(1 / 6, 1e-12));
      expect(_row(rows, 't1', 'pass_3')!.mean, 0);
      expect(_row(rows, 't2', 'pass_4')!.mean, 1);
      expect(_row(rows, 't1', 'pass_5'), isNull, reason: 'k is bounded by n');

      // Suite level: mean of the per-task pass^k, never pooled episodes.
      expect(_row(rows, '*', 'pass_1')!.mean, closeTo(0.75, 1e-12));
      expect(_row(rows, '*', 'pass_2')!.mean, closeTo((1 / 6 + 1) / 2, 1e-12));
      expect(_row(rows, '*', 'pass_2')!.n, 2, reason: 'n = number of tasks');
      expect(_row(rows, 't1', 'pass_2')!.n, 4, reason: 'per task, n = repetitions');
    });

    test('a flaky and a reliable agent are indistinguishable by mean but not '
        'by pass^k', () {
      // Both agents: 2 of 4 successes on each of two tasks -> same
      // success_rate, but "flaky" spreads its successes while "reliable"
      // solves one task always and the other never.
      final flaky = Aggregator().aggregate([..._task('t1', successes: 2, n: 4), ..._task('t2', successes: 2, n: 4)]);
      final reliable = Aggregator().aggregate([..._task('t1', successes: 4, n: 4), ..._task('t2', successes: 0, n: 4)]);

      double at(List<AggregateRow> rows, int k) => _row(rows, '*', 'pass_$k')!.mean;

      expect(at(flaky, 1), closeTo(at(reliable, 1), 1e-12), reason: 'the mean cannot tell them apart');
      expect(at(flaky, 4), 0);
      expect(at(reliable, 4), closeTo(0.5, 1e-12), reason: 'half of the tasks are solved every single time');
    });

    test('framework faults are excluded, not counted as failures', () {
      final rows = Aggregator().aggregate([_episode('t1', 1, type: .success), _episode('t1', 2, type: .success), _episode('t1', 3, type: .error)]);
      expect(_row(rows, 't1', 'pass_1')!.mean, 1, reason: 'two of two scored episodes succeeded (§5.2)');
      expect(_row(rows, 't1', 'pass_2')!.mean, 1);
      expect(_row(rows, 't1', 'pass_3'), isNull);
    });

    test('partial credit is not a pass', () {
      final rows = Aggregator().aggregate([_episode('t1', 1, type: .success), _episode('t1', 2, type: .partial)]);
      expect(_row(rows, 't1', 'pass_1')!.mean, closeTo(0.5, 1e-12));
      expect(_row(rows, 't1', 'pass_2')!.mean, 0);
    });

    test('k is bounded by the smallest repetition count across tasks', () {
      final rows = Aggregator().aggregate([..._task('t1', successes: 2, n: 2), ..._task('t2', successes: 5, n: 5)]);
      expect(_row(rows, '*', 'pass_2'), isNotNull);
      expect(
        _row(rows, '*', 'pass_3'),
        isNull,
        reason:
            't1 has only 2 repetitions, so every task contributes to '
            'every reported k',
      );
      expect(_row(rows, 't2', 'pass_5'), isNotNull, reason: 'per-task rows still use the full repetition count');
    });
  });

  test('the markdown report renders the pass^k decay', () {
    final records = [..._task('t1', successes: 2, n: 4), ..._task('t2', successes: 4, n: 4)];
    final report = MarkdownReporter().render(RunReportData(records: records, aggregates: Aggregator().aggregate(records)));
    expect(report, contains('pass^1'));
    expect(report, contains('pass^4'));
    expect(report, contains('| agent | 0.75 |'));
  });
}
