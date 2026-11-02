import '../aggregation/aggregator.dart';
import '../aggregation/stats.dart';
import 'metrics.dart';

/// Consistency across repetitions (Rabanser et al. 2026). Each metric is
/// computed within a task asked one way (a variant is its own group); the `*` row is the mean over tasks. Needs ≥2
/// repetitions of a task, otherwise null.
final consistencyMetrics = MetricProvider(
  name: 'consistency',
  description: 'Outcome, trajectory and resource consistency across repetitions',
  features: [
    FeatureDefinition(
      name: 'trajectory',
      compute: (ctx) => [
        for (final x in ctx.exchanges)
          if (!x.isMeta) ctx.label(x),
      ],
    ),
  ],
  aggregates: [
    AggregateMetricDefinition(
      name: 'outcome_consistency',
      unit: 'ratio',
      description: '1 − Var(success) / 0.25: 1 when every repetition agrees',
      compute: (group) => _perTask(group, (records) {
        final p = Stats.mean([for (final r in records) r.verdict.type == .success ? 1 : 0]);
        return 1 - 4 * p * (1 - p);
      }),
    ),
    AggregateMetricDefinition(
      name: 'trajectory_consistency',
      unit: 'ratio',
      description:
          'Mean pairwise similarity of the envelope sequences '
          '(1 − normalised edit distance)',
      compute: (group) => _perTask(group, (records) {
        final paths = [
          for (final r in records)
            if (r.features['trajectory'] case final List path) path.cast<String>(),
        ];
        final similarities = [
          for (var i = 0; i < paths.length; i++)
            for (var j = i + 1; j < paths.length; j++) _similarity(paths[i], paths[j]),
        ];
        return similarities.isEmpty ? null : Stats.mean(similarities);
      }),
    ),
    AggregateMetricDefinition(
      name: 'tokens_cv',
      unit: 'ratio',
      description: 'Coefficient of variation of tokens_total across repetitions',
      compute: (group) => _perTask(group, (records) {
        final tokens = [for (final r in records) ?r.metrics['tokens_total']];
        final mean = Stats.mean(tokens);
        return tokens.length < 2 || mean == 0 ? null : Stats.stdDev(tokens) / mean;
      }),
    ),
  ],
);

num? _perTask(List<EpisodeRecord> group, num? Function(List<EpisodeRecord> records) compute) {
  final byTask = <String, List<EpisodeRecord>>{};
  for (final record in group) {
    byTask.putIfAbsent(record.cluster, () => []).add(record);
  }
  final values = [
    for (final records in byTask.values)
      if (records.length >= 2) ?compute(records),
  ];
  return values.isEmpty ? null : Stats.mean(values);
}

double _similarity(List<String> a, List<String> b) {
  final longest = a.length > b.length ? a.length : b.length;
  if (longest == 0) return 1;
  var previous = List<int>.generate(b.length + 1, (j) => j);
  for (var i = 1; i <= a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1);
      final deletion = previous[j] + 1;
      final insertion = current[j - 1] + 1;
      current[j] = [substitution, deletion, insertion].reduce((x, y) => x < y ? x : y);
    }
    previous = current;
  }
  return 1 - previous[b.length] / longest;
}
