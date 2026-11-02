import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

/// Per-tag aggregation and comparison.
///
/// A suite that is mostly German with a small `lang:en` slice can otherwise
/// only be read as one number, and the language effect the slice exists to
/// measure stays invisible.
EpisodeRecord record({
  required String taskId,
  required String agentId,
  required bool success,
  List<String> tags = const [],
  int repetition = 1,
  double? score,
}) => EpisodeRecord(
  runId: 'r',
  episodeId: '$taskId-$agentId-$repetition',
  taskId: taskId,
  agentId: agentId,
  repetition: repetition,
  tags: tags,
  verdict: Verdict(type: success ? VerdictType.success : VerdictType.failure, score: score ?? (success ? 1 : 0)),
  metrics: {'success': success ? 1 : 0, 'weighted_score': score ?? (success ? 1 : 0)},
);

void main() {
  group('aggregation', () {
    test('emits a slice per tag alongside the task and suite rows', () {
      final rows = Aggregator().aggregate([
        record(taskId: 'forms.fill', agentId: 'hybrid', success: true, tags: ['forms', 'lang:de']),
        record(taskId: 'forms.fill.en', agentId: 'hybrid', success: false, tags: ['forms', 'lang:en']),
        record(taskId: 'data.count', agentId: 'hybrid', success: true, tags: ['data', 'lang:de']),
      ]);

      double rate(String scope) => rows.firstWhere((r) => r.taskId == scope && r.metric == 'success_rate').mean;

      expect(rate('*'), closeTo(2 / 3, 1e-9));
      expect(rate('tag:lang:de'), 1.0);
      // The one English task failed — invisible in the suite number alone.
      expect(rate('tag:lang:en'), 0.0);
      expect(rate('tag:forms'), closeTo(0.5, 1e-9));
    });

    test('tag rows are marked, so consumers can leave them out', () {
      final rows = Aggregator().aggregate([
        record(taskId: 't', agentId: 'a', success: true, tags: ['lang:en']),
      ]);

      final tagRow = rows.firstWhere((r) => r.tag != null);
      expect(tagRow.tag, 'lang:en');
      expect(tagRow.isAggregateRow, isTrue);
      // Every existing consumer filters on taskId == '*', so the new rows
      // cannot leak into a report that did not ask for them.
      expect(rows.where((r) => r.taskId == '*').every((r) => r.tag == null), isTrue);
    });

    test('an untagged suite produces no tag rows at all', () {
      final rows = Aggregator().aggregate([record(taskId: 't', agentId: 'a', success: true)]);
      expect(rows.where((r) => r.tag != null), isEmpty);
    });
  });

  group('comparison', () {
    test('compares a tag slice between two runs', () {
      final before = [
        record(taskId: 'de.1', agentId: 'hybrid', success: true, tags: ['lang:de']),
        record(taskId: 'en.1', agentId: 'hybrid', success: true, tags: ['lang:en']),
      ];
      final after = [
        record(taskId: 'de.1', agentId: 'hybrid', success: true, tags: ['lang:de']),
        record(taskId: 'en.1', agentId: 'hybrid', success: false, tags: ['lang:en']),
      ];

      final rows = RunComparator(metrics: const ['weighted_score'], bootstrapIterations: 200).compare(before, after);
      ComparisonRow row(String scope) => rows.firstWhere((r) => r.taskId == scope && r.metric == 'weighted_score');

      // The English slice regressed while the German one held — the whole
      // point of carrying the slice.
      expect(row('tag:lang:en').meanB, 0.0);
      expect(row('tag:lang:de').meanB, 1.0);
      expect(row('*').meanB, closeTo(0.5, 1e-9));
    });
  });
}
