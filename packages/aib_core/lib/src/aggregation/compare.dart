import 'aggregator.dart';
import 'stats.dart';

/// One compared cell: metric of agent×task in run A vs run B with a
/// bootstrap CI over the difference (spec §6.5: distribution-free pairwise
/// comparison; no normality assumption).
final class ComparisonRow {
  const ComparisonRow({
    required this.agentId,
    required this.taskId,
    required this.metric,
    required this.nA,
    required this.nB,
    required this.meanA,
    required this.meanB,
    required this.diff,
    required this.ciLow,
    required this.ciHigh,
    this.pairedTasks,
  });

  /// Tasks present in both runs, for `*` and `tag:` rows: the diff is the
  /// mean of per-task differences and the CI resamples tasks.
  final int? pairedTasks;

  final String agentId;
  final String taskId;
  final String metric;
  final int nA;
  final int nB;
  final double meanA;
  final double meanB;

  /// meanB − meanA.
  final double diff;
  final double ciLow;
  final double ciHigh;

  /// The 95% bootstrap CI of the difference excludes 0.
  bool get significant => ciLow > 0 || ciHigh < 0;
}

/// Compares two evaluated runs (aib compare, spec §9). Only episodes with
/// non-error verdicts and non-null metric values enter the comparison.
final class RunComparator {
  RunComparator({
    this.metrics = const ['weighted_score', 'wall_clock_ms', 'tokens_total', 'cost_usd'],
    this.bootstrapIterations = 10000,
    this.seed = 42,
  });

  final List<String> metrics;
  final int bootstrapIterations;
  final int seed;

  /// The agent id two runs are compared under when their own ids differ and
  /// each ran exactly one agent: the arms of a sweep, where the id names the
  /// thing being varied.
  static const pairedAgentId = 'paired';

  /// Whether [runA] and [runB] each ran one agent, under different ids.
  static bool needsPairing(List<EpisodeRecord> runA, List<EpisodeRecord> runB) {
    final a = {for (final r in runA) r.agentId};
    final b = {for (final r in runB) r.agentId};
    return a.length == 1 && b.length == 1 && a.single != b.single;
  }

  static List<EpisodeRecord> _underPairedId(List<EpisodeRecord> run) => [
    for (final record in run)
      EpisodeRecord(
        runId: record.runId,
        episodeId: record.episodeId,
        taskId: record.taskId,
        agentId: pairedAgentId,
        repetition: record.repetition,
        verdict: record.verdict,
        metrics: record.metrics,
        tags: record.tags,
        features: record.features,
      ),
  ];

  List<ComparisonRow> compare(List<EpisodeRecord> runA, List<EpisodeRecord> runB) {
    if (needsPairing(runA, runB)) {
      return compare(_underPairedId(runA), _underPairedId(runB));
    }
    final rows = <ComparisonRow>[];
    final keys = <(String agentId, String taskId)>{
      for (final record in [...runA, ...runB]) (record.agentId, record.taskId),
      for (final record in [...runA, ...runB]) (record.agentId, '*'),
      // Tag slices are compared like tasks: `lang:en` against `lang:de`, for
      // example.
      for (final record in [...runA, ...runB])
        for (final tag in record.tags) (record.agentId, '${AggregateRow.tagPrefix}$tag'),
    };
    for (final (agentId, taskId)
        in keys.toList()..sort((x, y) {
          final byAgent = x.$1.compareTo(y.$1);
          return byAgent != 0 ? byAgent : x.$2.compareTo(y.$2);
        })) {
      for (final metric in metrics) {
        if (taskId == '*' || taskId.startsWith(AggregateRow.tagPrefix)) {
          final row = _pairedRow(runA, runB, agentId, taskId, metric);
          if (row != null) rows.add(row);
          continue;
        }
        final a = _values(runA, agentId, taskId, metric);
        final b = _values(runB, agentId, taskId, metric);
        if (a.isEmpty || b.isEmpty) continue;
        final bootstrap = Stats.bootstrapMeanDiff(a, b, iterations: bootstrapIterations, seed: seed);
        rows.add(
          ComparisonRow(
            agentId: agentId,
            taskId: taskId,
            metric: metric,
            nA: a.length,
            nB: b.length,
            meanA: Stats.mean(a),
            meanB: Stats.mean(b),
            diff: bootstrap.meanDiff,
            ciLow: bootstrap.low,
            ciHigh: bootstrap.high,
          ),
        );
      }
    }
    return rows;
  }

  ComparisonRow? _pairedRow(List<EpisodeRecord> runA, List<EpisodeRecord> runB, String agentId, String scope, String metric) {
    final taskIds = {
      for (final r in [...runA, ...runB])
        if (r.agentId == agentId && _matchesScope(r, scope)) r.taskId,
    }.toList()..sort();
    final clusters = [
      for (final taskId in taskIds) (a: _values(runA, agentId, taskId, metric), b: _values(runB, agentId, taskId, metric)),
    ].where((c) => c.a.isNotEmpty && c.b.isNotEmpty).toList();
    if (clusters.isEmpty) return null;
    final result = Stats.pairedClusterBootstrap(clusters, iterations: bootstrapIterations, seed: seed);
    return ComparisonRow(
      agentId: agentId,
      taskId: scope,
      metric: metric,
      nA: clusters.fold(0, (n, c) => n + c.a.length),
      nB: clusters.fold(0, (n, c) => n + c.b.length),
      meanA: Stats.mean([for (final c in clusters) Stats.mean(c.a)]),
      meanB: Stats.mean([for (final c in clusters) Stats.mean(c.b)]),
      diff: result.meanDiff,
      ciLow: result.low,
      ciHigh: result.high,
      pairedTasks: clusters.length,
    );
  }

  static List<num> _values(List<EpisodeRecord> records, String agentId, String taskId, String metric) => [
    for (final record in records)
      if (record.agentId == agentId && _matchesScope(record, taskId) && record.verdict.type.name != 'error' && record.metrics[metric] != null)
        record.metrics[metric]!,
  ];

  /// Whether an episode belongs to the scope named by [taskId]: every
  /// episode for `*`, the tagged ones for a `tag:` scope, otherwise the one
  /// task.
  static bool _matchesScope(EpisodeRecord record, String taskId) {
    if (taskId == '*') return true;
    if (taskId.startsWith(AggregateRow.tagPrefix)) {
      return record.tags.contains(taskId.substring(AggregateRow.tagPrefix.length));
    }
    return record.taskId == taskId;
  }

  /// The §6.4 cross-run deltas are *named readings* of a comparison, not
  /// separate arithmetic: `semantics_degradation_delta` is the Δ of
  /// `weighted_score` between the good- and bad-semantics runs of the same
  /// suite, with the bootstrap CI that already comes with every row.
  ///
  /// [rows] must come from `compare(good, bad)`; the returned row is the
  /// suite-level (`taskId == '*'`) one for [agentId].
  static ComparisonRow? semanticsDegradation(List<ComparisonRow> rows, String agentId, {String metric = 'weighted_score'}) {
    for (final row in rows) {
      if (row.agentId == agentId && row.taskId == '*' && row.metric == metric) {
        return row;
      }
    }
    return null;
  }

  /// `prompt_robustness`: what a rewording of the same task cost.
  ///
  /// Read from **one** run: the base episodes of each task against the episodes
  /// asked with [variant], paired by task (variant − base). Null when no task
  /// has both.
  static ComparisonRow? promptRobustness(
    List<EpisodeRecord> records,
    String agentId, {
    required String variant,
    String metric = 'weighted_score',
    int iterations = 10000,
    int seed = 42,
  }) {
    num? valueOf(EpisodeRecord r) => r.agentId == agentId && r.verdict.type != .error ? r.metrics[metric] : null;
    final byTask = <String, ({List<num> a, List<num> b})>{};
    for (final record in records) {
      final value = valueOf(record);
      if (value == null) continue;
      final cell = byTask.putIfAbsent(record.taskId, () => (a: <num>[], b: <num>[]));
      if (record.variant == null) {
        cell.a.add(value);
      } else if (record.variant == variant) {
        cell.b.add(value);
      }
    }
    final clusters = [
      for (final cell in byTask.values)
        if (cell.a.isNotEmpty && cell.b.isNotEmpty) cell,
    ];
    if (clusters.isEmpty) return null;
    final result = Stats.pairedClusterBootstrap(clusters, iterations: iterations, seed: seed);
    return ComparisonRow(
      agentId: agentId,
      taskId: '${AggregateRow.tagPrefix}variant:$variant',
      metric: metric,
      nA: clusters.fold(0, (n, c) => n + c.a.length),
      nB: clusters.fold(0, (n, c) => n + c.b.length),
      meanA: Stats.mean([for (final c in clusters) Stats.mean(c.a)]),
      meanB: Stats.mean([for (final c in clusters) Stats.mean(c.b)]),
      diff: result.meanDiff,
      ciLow: result.low,
      ciHigh: result.high,
      pairedTasks: clusters.length,
    );
  }

  /// `cross_model_variance` (§6.4): spread of one agent's [metric] across
  /// ≥2 runs of the *same* suite with different models. Unlike
  /// [compare] this is not a pairwise question, so it takes N runs.
  ///
  /// Reported as the standard deviation and the range of the per-run means —
  /// a strategy whose score swings with the model is less portable than one
  /// that does not, which is what the metric exists to expose.
  static ({double stdDev, double min, double max, int runs})? crossRunVariance(
    List<List<EpisodeRecord>> runs,
    String agentId, {
    String metric = 'weighted_score',
  }) {
    final means = <num>[
      for (final run in runs)
        if (_values(run, agentId, '*', metric).isNotEmpty) Stats.mean(_values(run, agentId, '*', metric)),
    ];
    if (means.length < 2) return null;
    return (
      stdDev: Stats.stdDev(means),
      min: means.reduce((a, b) => a < b ? a : b).toDouble(),
      max: means.reduce((a, b) => a > b ? a : b).toDouble(),
      runs: means.length,
    );
  }

  /// Markdown rendering (comparison.md).
  static String toMarkdown(
    List<ComparisonRow> rows, {
    String labelA = 'A',
    String labelB = 'B',

    /// The two runs' own agent ids, when they differ and the rows were
    /// therefore paired under [pairedAgentId].
    (String, String)? pairedAgents,
  }) {
    final buffer = StringBuffer()
      ..writeln('# Run comparison — $labelA vs $labelB')
      ..writeln()
      ..writeln(
        'Δ = mean($labelB) − mean($labelA); 95% bootstrap CI; **bold** = CI '
        'excludes 0. `*` and `tag:` rows pair the runs by task (means of task '
        'means, tasks resampled); n there reads episodes (tasks).',
      )
      ..writeln()
      ..writeln(
        pairedAgents == null
            ? ''
            : '> The runs name their agent differently '
                  '(`${pairedAgents.$1}` vs `${pairedAgents.$2}`) and each ran '
                  'one; the rows below pair them as `$pairedAgentId`. That is '
                  'the arm being varied, so read every row as A-agent vs '
                  'B-agent.\n',
      )
      ..writeln(
        '> ${rows.length} intervals are shown at 95% each, so about '
        '${(rows.length * 0.05).ceil()} of them are expected to exclude 0 by '
        'chance. Read a single bold row as a finding only when it was the '
        'question the run was designed to answer.',
      )
      ..writeln()
      ..writeln(
        '| Agent | Task | Metric | n | mean $labelA | mean $labelB '
        '| Δ [95% CI] |',
      )
      ..writeln('|---|---|---|---|---|---|---|');
    String fmt(double v) => v.isNaN ? '—' : v.toStringAsFixed(2);
    for (final row in rows) {
      final delta = '${fmt(row.diff)} [${fmt(row.ciLow)}, ${fmt(row.ciHigh)}]';
      buffer.writeln(
        '| ${row.agentId} | ${row.taskId} | ${row.metric} '
        '| ${row.nA}/${row.nB}'
        '${row.pairedTasks == null ? '' : ' (${row.pairedTasks})'} '
        '| ${fmt(row.meanA)} | ${fmt(row.meanB)} '
        '| ${row.significant ? '**$delta**' : delta} |',
      );
    }
    return buffer.toString();
  }
}

/// One run reduced to its headline numbers, for a table that has more than
/// two columns.
final class RunPoint {
  const RunPoint({required this.label, required this.metrics, required this.episodes, this.nominallyPriced = const {}});

  final String label;

  /// Mean over the run's episodes; absent where every episode was null.
  final Map<String, double> metrics;
  final int episodes;

  /// Models whose `cost_usd` is zero because no API money changed hands, not
  /// because they were free.
  final Set<String> nominallyPriced;
}

/// Compares N runs at once and reports **no CIs**: it ranks, it does not test.
/// `aib compare` is the pairwise test.
abstract final class RunSweep {
  static const defaultMetrics = ['weighted_score', 'success_rate', 'tokens_total', 'cost_usd', 'wall_clock_ms'];

  static RunPoint summarise(
    String label,
    List<EpisodeRecord> records, {
    List<String> metrics = defaultMetrics,
    Set<String> nominallyPriced = const {},
  }) {
    final scored = records.where((r) => r.verdict.type != .error).toList();
    return RunPoint(
      label: label,
      episodes: scored.length,
      nominallyPriced: nominallyPriced,
      metrics: {
        for (final metric in metrics)
          if (scored.any((r) => r.metrics[metric] != null))
            metric: Stats.mean([
              for (final record in scored)
                if (record.metrics[metric] != null) record.metrics[metric]!,
            ]),
        // Not an episode metric: an episode is a verdict, and the rate is
        // over the run. Left out, the column read `—` on every row.
        if (scored.isNotEmpty && metrics.contains('success_rate'))
          'success_rate': scored.where((r) => r.verdict.type == .success).length / scored.length,
      },
    );
  }

  /// The runs no other run beats on both axes: at least as good on
  /// [objective] and no dearer on [cost] (HAL's cost–accuracy frontier).
  ///
  /// A run missing either axis cannot be placed and is never on the frontier;
  /// a local model priced at zero dominates everything on cost, which is why
  /// the sweep is worth reading on tokens as well as on money.
  static Set<String> paretoFrontier(List<RunPoint> points, {String objective = 'weighted_score', String cost = 'tokens_total'}) {
    final placed = [
      for (final point in points)
        if (point.metrics[objective] != null && point.metrics[cost] != null) point,
    ];
    return {
      for (final point in placed)
        if (!placed.any(
          (other) =>
              other.label != point.label &&
              other.metrics[objective]! >= point.metrics[objective]! &&
              other.metrics[cost]! <= point.metrics[cost]! &&
              (other.metrics[objective]! > point.metrics[objective]! || other.metrics[cost]! < point.metrics[cost]!),
        ))
          point.label,
    };
  }

  static String toMarkdown(
    List<RunPoint> points, {
    List<String> metrics = defaultMetrics,
    String objective = 'weighted_score',
    String cost = 'tokens_total',
  }) {
    final frontier = paretoFrontier(points, objective: objective, cost: cost);
    final buffer = StringBuffer()
      ..writeln('| run | n | ${metrics.join(' | ')} | on frontier |')
      ..writeln('|---|---|${'---|' * (metrics.length + 1)}');
    for (final point in points) {
      final cells = [for (final metric in metrics) point.metrics[metric] == null ? '—' : _format(point.metrics[metric]!)];
      buffer.writeln(
        '| `${point.label}` | ${point.episodes} | ${cells.join(' | ')} '
        '| ${frontier.contains(point.label) ? '✓' : ''} |',
      );
    }
    buffer
      ..writeln()
      ..writeln(
        'Frontier is $objective against $cost: a run is on it when no other '
        'run is at least as good and no dearer. **No confidence intervals** — '
        'this table ranks conditions, it does not test them. Use '
        '`aib compare` on the two that matter.',
      );
    final nominal = {for (final point in points) ...point.nominallyPriced};
    if (nominal.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(
          '**`cost_usd` is API spend only.** '
          '${nominal.map((m) => '`$m`').join(', ')} run locally and are priced '
          'at zero, which is a statement about billing and not about cost: the '
          'machine, its power and the wall clock are not in that column. Rank '
          'those on tokens or wall clock.',
        );
    }
    return buffer.toString();
  }

  /// [objective] against [cost] as an SVG scatter; frontier runs are filled
  /// and joined.
  static String toSvg(List<RunPoint> points, {String objective = 'weighted_score', String cost = 'tokens_total'}) {
    const width = 560.0, height = 300.0, pad = 50.0;
    final placed = [
      for (final point in points)
        if (point.metrics[objective] != null && point.metrics[cost] != null) point,
    ];
    if (placed.isEmpty) {
      return '<p>No run has both $objective and $cost.</p>';
    }
    final frontier = paretoFrontier(points, objective: objective, cost: cost);
    double maxOf(String metric, double floor) => placed.map((p) => p.metrics[metric]!).fold(floor, (a, b) => a > b ? a : b);
    final maxCost = maxOf(cost, 0);
    final maxObjective = maxOf(objective, 1);
    double x(RunPoint p) => pad + (maxCost == 0 ? 0 : p.metrics[cost]! / maxCost) * (width - 2 * pad);
    double y(RunPoint p) => height - pad - p.metrics[objective]! / maxObjective * (height - 2 * pad);

    final line = placed.where((p) => frontier.contains(p.label)).toList()..sort((a, b) => a.metrics[cost]!.compareTo(b.metrics[cost]!));
    final svg = StringBuffer()
      ..writeln(
        '<svg xmlns="http://www.w3.org/2000/svg" width="$width" '
        'height="$height" role="img" font-family="sans-serif" font-size="11">',
      )
      ..writeln(
        '<line x1="$pad" y1="${height - pad}" x2="${width - pad}" '
        'y2="${height - pad}" stroke="#4a5568"/>',
      )
      ..writeln(
        '<line x1="$pad" y1="$pad" x2="$pad" y2="${height - pad}" '
        'stroke="#4a5568"/>',
      )
      ..writeln(
        '<text x="${width / 2}" y="${height - 12}" text-anchor="middle" '
        'fill="#4a5568">$cost (0 – ${_format(maxCost)})</text>',
      )
      ..writeln(
        '<text x="14" y="${height / 2}" text-anchor="middle" fill="#4a5568" '
        'transform="rotate(-90 14 ${height / 2})">$objective</text>',
      );
    if (line.length > 1) {
      svg.writeln(
        '<polyline fill="none" stroke="#3182ce" stroke-dasharray="4 3" '
        'points="${line.map((p) => '${x(p)},${y(p)}').join(' ')}"/>',
      );
    }
    for (final point in placed) {
      final on = frontier.contains(point.label);
      svg
        ..writeln(
          '<circle cx="${x(point)}" cy="${y(point)}" r="5" '
          'fill="${on ? '#3182ce' : 'white'}" stroke="#3182ce"/>',
        )
        ..writeln(
          '<text x="${x(point) + 8}" y="${y(point) + 4}">'
          '${_escape(point.label)}</text>',
        );
    }
    svg.writeln('</svg>');
    return svg.toString();
  }

  /// The plot above the table, as one page.
  static String toHtml(List<RunPoint> points) =>
      '<!doctype html><meta charset="utf-8"><title>Sweep</title>'
      '<body style="font-family:sans-serif;max-width:60em;margin:2em auto">'
      '${toSvg(points)}<pre>${_escape(toMarkdown(points))}</pre></body>';

  static String _escape(String text) => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  static String _format(double value) => value.abs() >= 100 ? value.toStringAsFixed(0) : value.toStringAsFixed(3);
}
