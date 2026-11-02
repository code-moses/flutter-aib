import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

EpisodeRecord _record(String agentId, String taskId, int rep, double score, {double wallClock = 100}) => EpisodeRecord(
  runId: 'r',
  episodeId: '$taskId-$agentId-$rep',
  taskId: taskId,
  agentId: agentId,
  repetition: rep,
  verdict: score >= 1 ? Verdict.success() : Verdict.failure('f'),
  metrics: {'weighted_score': score, 'wall_clock_ms': wallClock, 'tokens_total': 500},
);

void main() {
  group('Stats.cohensKappa', () {
    test('perfect agreement -> 1, reference value for mixed labels', () {
      expect(Stats.cohensKappa([true, false, true], [true, false, true]), 1);
      // Both raters constant: agreement is guaranteed, so κ says nothing.
      expect(Stats.cohensKappa([true, true], [true, true]), isNaN);
      // Classic textbook contingency (yy=20, yn=5, ny=10, nn=15, n=50):
      // po=0.7, pe=0.5 -> κ=0.4
      final rater1 = [...List.filled(20, 'y'), ...List.filled(5, 'y'), ...List.filled(10, 'n'), ...List.filled(15, 'n')];
      final rater2 = [...List.filled(20, 'y'), ...List.filled(5, 'n'), ...List.filled(10, 'y'), ...List.filled(15, 'n')];
      expect(Stats.cohensKappa(rater1, rater2), closeTo(0.4, 1e-9));
    });

    test('rejects mismatched input', () {
      expect(() => Stats.cohensKappa([true], []), throwsArgumentError);
    });
  });

  group('Stats.bootstrapMeanDiff', () {
    test('is seeded/reproducible and detects a clear difference', () {
      final a = List<num>.generate(20, (i) => 10 + (i % 5));
      final b = List<num>.generate(20, (i) => 20 + (i % 5));
      final first = Stats.bootstrapMeanDiff(a, b, iterations: 2000);
      final second = Stats.bootstrapMeanDiff(a, b, iterations: 2000);
      expect(first.meanDiff, 10);
      expect(first.low, second.low, reason: 'seeded -> reproducible');
      expect(first.low, greaterThan(0), reason: 'CI excludes 0');
    });

    test('overlapping samples -> CI includes 0', () {
      final a = [1, 2, 3, 4, 5];
      final b = [2, 3, 1, 5, 4];
      final result = Stats.bootstrapMeanDiff(a, b, iterations: 2000);
      expect(result.low, lessThanOrEqualTo(0));
      expect(result.high, greaterThanOrEqualTo(0));
    });
  });

  group('RunComparator', () {
    test('the * row pairs by task, which a constant shift needs', () {
      // Tasks differ hugely in cost; B is 100 ms slower on every one.
      EpisodeRecord at(String task, int rep, double ms) => _record('a', task, rep, 1, wallClock: ms);
      final base = {'t1': 1000.0, 't2': 20000.0, 't3': 60000.0, 't4': 5000.0};
      final runA = [
        for (final e in base.entries)
          for (var rep = 1; rep <= 2; rep++) at(e.key, rep, e.value),
      ];
      final runB = [
        for (final e in base.entries)
          for (var rep = 1; rep <= 2; rep++) at(e.key, rep, e.value + 100),
        at('only-in-b', 1, 1e6),
      ];
      final row = RunComparator(bootstrapIterations: 1000).compare(runA, runB).firstWhere((r) => r.taskId == '*' && r.metric == 'wall_clock_ms');
      expect(row.pairedTasks, 4);
      expect(row.diff, closeTo(100, 1e-9));
      expect(row.significant, isTrue);
      // Unpaired, the between-task spread swamps the shift.
      final unpaired = Stats.bootstrapMeanDiff(
        [for (final r in runA) r.metrics['wall_clock_ms']!],
        [for (final r in runB.where((r) => r.taskId != 'only-in-b')) r.metrics['wall_clock_ms']!],
        iterations: 1000,
      );
      expect(unpaired.low < 0 && unpaired.high > 0, isTrue);
    });

    test('aligns runs per agent×task and flags significant differences', () {
      final runA = [for (var rep = 1; rep <= 5; rep++) _record('semantics', 't1', rep, 0.2)];
      final runB = [for (var rep = 1; rep <= 5; rep++) _record('semantics', 't1', rep, 1.0)];
      final rows = RunComparator(bootstrapIterations: 1000).compare(runA, runB);

      final scoreRow = rows.firstWhere((r) => r.agentId == 'semantics' && r.taskId == 't1' && r.metric == 'weighted_score');
      expect(scoreRow.meanA, closeTo(0.2, 1e-9));
      expect(scoreRow.meanB, 1.0);
      expect(scoreRow.diff, closeTo(0.8, 1e-9));
      expect(scoreRow.significant, isTrue);

      // Identical wall clocks -> no significant difference.
      final wallRow = rows.firstWhere((r) => r.taskId == 't1' && r.metric == 'wall_clock_ms');
      expect(wallRow.significant, isFalse);

      // Overall rows exist too.
      expect(rows.any((r) => r.taskId == '*'), isTrue);

      final markdown = RunComparator.toMarkdown(rows, labelA: 'before', labelB: 'after');
      expect(markdown, contains('before'));
      expect(markdown, contains('**0.80'));
    });

    test('error verdicts are excluded from comparison', () {
      final runA = [_record('a', 't', 1, 1.0)];
      final runB = [
        EpisodeRecord(
          runId: 'r',
          episodeId: 'x',
          taskId: 't',
          agentId: 'a',
          repetition: 1,
          verdict: Verdict.frameworkError('boom'),
          metrics: const {'weighted_score': null},
        ),
      ];
      final rows = RunComparator(bootstrapIterations: 100).compare(runA, runB);
      expect(rows.where((r) => r.metric == 'weighted_score'), isEmpty);
    });
  });

  group('HtmlReporter', () {
    test('renders a self-contained page with tables and pareto plot', () {
      final records = [
        for (var rep = 1; rep <= 3; rep++) ...[_record('semantics', 'todo.create', rep, 1.0), _record('intent', 'todo.create', rep, 0.5)],
      ];
      final html = HtmlReporter().render(RunReportData(records: records, aggregates: Aggregator().aggregate(records)));
      expect(html, contains('<!doctype html>'));
      expect(html, contains('semantics'));
      expect(html, anyOf(contains('success_rate'), contains('weighted_score')));
      expect(html, contains('<svg'), reason: 'pareto plot inline');
      expect(html, isNot(contains('<script src')), reason: 'self-contained');
      expect(ReporterRegistry().formats, contains('html'));
    });
  });
}
