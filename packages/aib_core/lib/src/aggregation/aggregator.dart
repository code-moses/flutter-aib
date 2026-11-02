import 'dart:math' as math;

import '../evaluation/verdict.dart';
import '../metrics/metrics.dart';
import 'stats.dart';

/// One evaluated episode, ready for aggregation and CSV export.
final class EpisodeRecord {
  const EpisodeRecord({
    required this.runId,
    required this.episodeId,
    required this.taskId,
    required this.agentId,
    required this.repetition,
    required this.verdict,
    required this.metrics,
    this.tags = const [],
    this.features = const {},
  });

  final String runId;
  final String episodeId;
  final String taskId;
  final String agentId;
  final int repetition;
  final Verdict verdict;
  final Map<String, num?> metrics;

  /// The task's tags, carried so results can be sliced by them.
  final List<String> tags;

  /// Non-numeric per-episode values for group-level metrics; not persisted.
  final Map<String, Object?> features;

  /// The rewording this episode was asked in, or null for the base task.
  String? get variant {
    for (final tag in tags) {
      if (tag.startsWith('variant:')) return tag.substring('variant:'.length);
    }
    return null;
  }

  /// Episodes that repeat the same question: one task asked one way.
  ///
  /// Repetitions of a task and of its rewording are different questions, so
  /// pass^k and the consistency family must not pool them — a variant that
  /// fails would otherwise read as an inconsistent agent.
  String get cluster => variant == null ? taskId : '$taskId#variant:$variant';
}

/// Aggregated row: agent × task × metric.
///
/// [taskId] carries two pseudo-values besides a real task id: `*` for "across
/// all tasks", and `tag:<name>` for "across the tasks carrying that tag". A
/// caller that does not want the slices filters them out by prefix.
///
/// For the `pass_k` reliability metrics the row is a point estimate: per task,
/// mean = median = p95 = pass^k and [n] is the number of repetitions; on the
/// `*` row the three summarize the pass^k values *across tasks* and [n] is the
/// number of tasks.
final class AggregateRow {
  const AggregateRow({
    required this.agentId,
    required this.taskId,
    required this.metric,
    required this.n,
    required this.mean,
    required this.median,
    required this.p95,
    this.ciLow,
    this.ciHigh,
  });

  final String agentId;
  final String taskId;
  final String metric;
  final int n;
  final double mean;
  final double median;
  final double p95;

  /// Wilson 95% CI — only for rate metrics.
  final double? ciLow;
  final double? ciHigh;

  /// Marks a [taskId] that is a tag slice rather than a real task.
  static const tagPrefix = 'tag:';

  /// True for the `*` and `tag:` pseudo-rows.
  bool get isAggregateRow => taskId == '*' || taskId.startsWith(tagPrefix);

  /// The tag this row summarises, or null when it is a task or `*` row.
  String? get tag => taskId.startsWith(tagPrefix) ? taskId.substring(tagPrefix.length) : null;
}

/// Aggregates per-episode metrics over repetitions and tasks (spec §6.5).
/// Episodes with framework-fault verdicts are excluded from agent scoring
/// and surfaced via `infrastructure_error_rate` instead (§5.2).
final class Aggregator {
  Aggregator({this.aggregates = const [], Map<String, String>? rates}) : rates = rates ?? builtinRates;

  /// Group-level metrics, computed per task and for `*`, over scored episodes.
  final List<AggregateMetricDefinition> aggregates;

  /// 0/1 metric -> the rate it is reported as ([MetricDefinition.rateName]).
  /// Pass `MetricsRegistry.rates` so a provider's rates are included.
  final Map<String, String> rates;

  static final Map<String, String> builtinRates = {for (final metric in builtinMetrics) metric.name: ?metric.rateName};

  List<AggregateRow> aggregate(List<EpisodeRecord> records) {
    final rows = <AggregateRow>[];
    final byAgent = _groupBy(records, (r) => r.agentId);
    for (final agentEntry in byAgent.entries) {
      final byTask = _groupBy(agentEntry.value, (r) => r.taskId);
      for (final taskEntry in byTask.entries) {
        rows.addAll(_rowsFor(agentEntry.key, taskEntry.key, taskEntry.value));
      }
      rows.addAll(_rowsFor(agentEntry.key, '*', agentEntry.value, clustered: true));

      // Per-tag slices. Without these a suite that is mostly German with a
      // small `lang:en` slice can only be read as one number, and the
      // language effect the slice exists to measure stays invisible.
      final byTag = <String, List<EpisodeRecord>>{};
      for (final record in agentEntry.value) {
        for (final tag in record.tags) {
          byTag.putIfAbsent(tag, () => []).add(record);
        }
      }
      for (final tagEntry in byTag.entries) {
        rows.addAll(_rowsFor(agentEntry.key, '${AggregateRow.tagPrefix}${tagEntry.key}', tagEntry.value, clustered: true));
      }

      final byCluster = _groupBy(agentEntry.value, (r) => r.cluster);
      rows.addAll(_passKRows(agentEntry.key, byCluster));
      rows.addAll(_aggregateRows(agentEntry.key, byTask, agentEntry.value));
    }
    return rows;
  }

  List<AggregateRow> _aggregateRows(String agentId, Map<String, List<EpisodeRecord>> byTask, List<EpisodeRecord> all) {
    List<EpisodeRecord> scored(List<EpisodeRecord> records) => records.where((r) => r.verdict.type != .error).toList();
    return [
      for (final definition in aggregates)
        for (final (taskId, group) in [for (final entry in byTask.entries) (entry.key, scored(entry.value)), ('*', scored(all))])
          if (group.isNotEmpty)
            if (definition.compute(group) case final num value)
              AggregateRow(
                agentId: agentId,
                taskId: taskId,
                metric: definition.name,
                n: group.length,
                mean: value.toDouble(),
                median: value.toDouble(),
                p95: value.toDouble(),
              ),
    ];
  }

  /// `pass_1 … pass_k` per agent (spec §6.1/§6.4, after τ-bench): the
  /// probability that k independently drawn repetitions of the same task all
  /// succeed. pass^1 is the success rate; the decay is the agent's
  /// consistency, which the mean alone cannot show.
  ///
  /// Pooling episodes across tasks would be meaningless here, so the suite
  /// level averages the per-task pass^k instead — and k is bounded by the
  /// smallest repetition count so every task contributes to every k.
  List<AggregateRow> _passKRows(String agentId, Map<String, List<EpisodeRecord>> byTask) {
    final trials = <({String taskId, int successes, int n})>[];
    for (final entry in byTask.entries) {
      // Framework faults are not the agent's failures (§5.2) — they are
      // excluded here exactly as in the rest of the aggregation.
      final scored = entry.value.where((r) => r.verdict.type != .error).toList();
      if (scored.isEmpty) continue;
      trials.add((taskId: entry.key, successes: scored.where((r) => r.verdict.type == .success).length, n: scored.length));
    }
    if (trials.isEmpty) return const [];

    final rows = <AggregateRow>[];
    for (final trial in trials) {
      for (var k = 1; k <= trial.n; k++) {
        final value = Stats.passHatK(trial.successes, trial.n, k);
        rows.add(AggregateRow(agentId: agentId, taskId: trial.taskId, metric: 'pass_$k', n: trial.n, mean: value, median: value, p95: value));
      }
    }
    final kMax = trials.map((t) => t.n).reduce(math.min);
    for (var k = 1; k <= kMax; k++) {
      final values = <num>[for (final trial in trials) Stats.passHatK(trial.successes, trial.n, k)];
      rows.add(
        AggregateRow(
          agentId: agentId,
          taskId: '*',
          metric: 'pass_$k',
          n: values.length,
          mean: Stats.mean(values),
          median: Stats.median(values),
          p95: Stats.percentile(values, 95),
        ),
      );
    }
    return rows;
  }

  /// [clustered] rows pool several tasks: their rate intervals account for
  /// episodes of one task not being independent.
  List<AggregateRow> _rowsFor(String agentId, String taskId, List<EpisodeRecord> records, {bool clustered = false}) {
    // infrastructure_error_rate is computed over *all* episodes; every other
    // metric only over episodes that are not framework faults.
    final scored = records.where((r) => r.verdict.type != .error).toList();

    final metricNames = <String>{for (final record in records) ...record.metrics.keys};
    final rows = <AggregateRow>[];
    for (final metric in metricNames) {
      final source = metric == 'infrastructure_error' ? records : scored;
      final measured = [
        for (final record in source)
          if (record.metrics[metric] case final num value) (cluster: record.cluster, value: value),
      ];
      final values = [for (final m in measured) m.value];
      if (values.isEmpty) continue;

      double? ciLow;
      double? ciHigh;
      final rateName = rates[metric];
      if (rateName != null) {
        final ci = clustered ? Stats.clusteredRateCi(measured) : Stats.wilson(values.where((v) => v >= 1).length, values.length);
        ciLow = ci.low;
        ciHigh = ci.high;
      }
      rows.add(
        AggregateRow(
          agentId: agentId,
          taskId: taskId,
          metric: rateName ?? metric,
          n: values.length,
          mean: Stats.mean(values),
          median: Stats.median(values),
          p95: Stats.percentile(values, 95),
          ciLow: ciLow,
          ciHigh: ciHigh,
        ),
      );
    }
    rows.sort((a, b) {
      final byTask = a.taskId.compareTo(b.taskId);
      return byTask != 0 ? byTask : a.metric.compareTo(b.metric);
    });
    return rows;
  }

  static Map<K, List<V>> _groupBy<K, V>(List<V> items, K Function(V) key) {
    final result = <K, List<V>>{};
    for (final item in items) {
      result.putIfAbsent(key(item), () => []).add(item);
    }
    return result;
  }
}
