import '../evaluation/verdict.dart';
import 'aggregator.dart';
import 'stats.dart';

/// One run of a baseline comparison, summarised with its intervals.
final class RunSummary {
  const RunSummary({
    required this.label,
    required this.episodes,
    required this.tasks,
    required this.verdicts,
    required this.wilson,
    required this.clustered,
    required this.score,
    required this.passK,
    required this.k,
    required this.ends,
    this.scoreWithout,
  });

  final String label;
  final int episodes;
  final int tasks;

  /// success / partial / failure counts.
  final Map<String, int> verdicts;
  final ({double low, double high}) wilson;

  /// Task-clustered interval, never narrower than [wilson].
  final ({double low, double high}) clustered;
  final double score;

  /// Score with one criterion set aside (e.g. a suite-wide rubric); null when
  /// none was named.
  final double? scoreWithout;

  /// Mean over tasks of pass^[k], [k] the smallest repetition count.
  final double passK;
  final int k;

  /// Episodes per ending: budget (incl. wall clock), no progress, agent abort,
  /// provider abort (rate limit, transport, context), framework fault.
  final Map<String, int> ends;

  double get successRate => episodes == 0 ? double.nan : (verdicts['success'] ?? 0) / episodes;
}

/// A run's difference to the baseline on one metric, over shared tasks.
final class BaselineDelta {
  const BaselineDelta({required this.label, required this.metric, required this.tasks, required this.ci, required this.adjusted});

  final String label;
  final String metric;
  final int tasks;
  final ({double meanDiff, double low, double high}) ci;

  /// The Bonferroni interval for all comparisons of the table.
  final ({double meanDiff, double low, double high}) adjusted;

  bool get significant => ci.low > 0 || ci.high < 0;
  bool get significantAdjusted => adjusted.low > 0 || adjusted.high < 0;
}

/// Every run against the first: per-run intervals, then paired task-level
/// differences with a Bonferroni correction for the number of comparisons.
/// [heldOut] tasks are left out of every per-task view and of the differences.
abstract final class BaselineComparison {
  static const endKinds = ['budget', 'no progress', 'agent abort', 'provider abort', 'framework fault'];

  static RunSummary summarise(String label, List<EpisodeRecord> records, {String? setAside}) {
    final scored = records.where((r) => r.verdict.type != .error).toList();
    final byTask = _byTask(scored, (r) => r.verdict.type == .success ? 1 : 0);
    final k = byTask.isEmpty ? 0 : byTask.values.map((v) => v.length).reduce((a, b) => a < b ? a : b);
    int count(bool Function(EpisodeRecord) test) => records.where(test).length;
    bool flag(EpisodeRecord r, String metric) => (r.metrics[metric] ?? 0) > 0;
    final withouts = [
      if (setAside != null)
        for (final r in scored) ?_scoreWithout(r.verdict, setAside),
    ];
    return RunSummary(
      label: label,
      episodes: scored.length,
      tasks: byTask.length,
      verdicts: {
        for (final type in ['success', 'partial', 'failure']) type: scored.where((r) => r.verdict.type.name == type).length,
      },
      wilson: Stats.wilson(scored.where((r) => r.verdict.type == .success).length, scored.length),
      clustered: Stats.clusteredRateCi([for (final r in scored) (cluster: r.taskId, value: r.verdict.type == .success ? 1 : 0)]),
      score: Stats.mean([for (final r in scored) r.verdict.score]),
      scoreWithout: withouts.isEmpty ? null : Stats.mean(withouts),
      k: k,
      passK: k < 1 ? double.nan : Stats.mean([for (final v in byTask.values) Stats.passHatK(v.where((x) => x >= 1).length, v.length, k)]),
      ends: {
        'budget': count((r) => flag(r, 'budget_exhaustion')),
        'no progress': count((r) => flag(r, 'no_progress')),
        'agent abort': count((r) => flag(r, 'abort_agent_decision')),
        'provider abort': count((r) => flag(r, 'abort_rate_limit') || flag(r, 'abort_transport') || flag(r, 'abort_context_length')),
        'framework fault': count((r) => flag(r, 'infrastructure_error')),
      },
    );
  }

  /// Differences of every run in [others] to [baseline] on success and score.
  static List<BaselineDelta> deltas(List<EpisodeRecord> baseline, Map<String, List<EpisodeRecord>> others, {Set<String> heldOut = const {}}) {
    final comparisons = others.length;
    final alpha = 0.05 / (comparisons == 0 ? 1 : comparisons);
    return [
      for (final entry in others.entries)
        for (final metric in ['success', 'weighted_score'])
          if (_clusters(baseline, entry.value, metric, heldOut) case final clusters when clusters.isNotEmpty)
            BaselineDelta(
              label: entry.key,
              metric: metric,
              tasks: clusters.length,
              ci: Stats.pairedClusterBootstrap(clusters),
              adjusted: Stats.pairedClusterBootstrap(clusters, alpha: alpha),
            ),
    ];
  }

  /// Tasks to read before trusting their numbers: never a success, the same
  /// partial score on every run, or episodes that ended on a budget, a
  /// provider failure or a framework fault.
  static Map<String, List<String>> suspects(Map<String, List<EpisodeRecord>> runs, {Set<String> heldOut = const {}}) {
    final all = [
      for (final records in runs.values)
        for (final r in records)
          if (!heldOut.contains(r.taskId)) r,
    ];
    final notes = <String, List<String>>{};
    for (final task in {for (final r in all) r.taskId}.toList()..sort()) {
      final episodes = all.where((r) => r.taskId == task).toList();
      final means = [
        for (final records in runs.values)
          if (records.where((r) => r.taskId == task).toList() case final own when own.isNotEmpty) Stats.mean([for (final r in own) r.verdict.score]),
      ];
      int count(String metric) => episodes.where((r) => (r.metrics[metric] ?? 0) > 0).length;
      final list = [
        if (!episodes.any((r) => r.verdict.type == .success)) 'never a success',
        if (means.length > 1 && means.every((m) => (m - means.first).abs() < 1e-9) && means.first > 0 && means.first < 1)
          'every run scores ${means.first.toStringAsFixed(2)}: suspect the oracle',
        if (count('budget_exhaustion') case final n when n > 0) '$n budget or timeout',
        if (count('abort_rate_limit') + count('abort_transport') case final n when n > 0) '$n provider failure(s)',
        if (count('infrastructure_error') case final n when n > 0) '$n framework fault(s)',
        if (count('unanswered_ask_count') case final n when n > 0) '$n unanswered question(s)',
      ];
      if (list.isNotEmpty) notes[task] = list;
    }
    return notes;
  }

  static String toMarkdown(
    List<RunSummary> summaries,
    List<BaselineDelta> deltas,
    Map<String, List<String>> suspects, {
    String? setAside,
    int heldOut = 0,
  }) {
    String f(double v) => v.isNaN ? '—' : v.toStringAsFixed(2);
    String ci(({double low, double high}) c) => '[${f(c.low)}, ${f(c.high)}]';
    String d(double v) => v.isNaN ? '—' : '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}';
    final buffer = StringBuffer()
      ..writeln('## Runs')
      ..writeln()
      ..writeln(
        '| run | episodes | tasks | success | partial | failure | rate | Wilson 95 % | task-clustered 95 % | score '
        '${setAside == null ? '' : '| score without $setAside '}| pass^k | ${endKinds.join(' | ')} |',
      )
      ..writeln('|---|${'---:|' * (11 + endKinds.length - (setAside == null ? 1 : 0))}');
    for (final s in summaries) {
      buffer.writeln(
        '| `${s.label}` | ${s.episodes} | ${s.tasks} | ${s.verdicts['success']} | ${s.verdicts['partial']} | '
        '${s.verdicts['failure']} | ${f(s.successRate)} | ${ci(s.wilson)} | ${ci(s.clustered)} | ${f(s.score)} | '
        '${setAside == null ? '' : '${f(s.scoreWithout ?? double.nan)} | '}'
        '${s.k < 2 ? '—' : '${f(s.passK)} (k=${s.k})'} | ${[for (final kind in endKinds) s.ends[kind]].join(' | ')} |',
      );
    }
    final comparisons = deltas.map((x) => x.label).toSet().length;
    buffer
      ..writeln()
      ..writeln('## Against `${summaries.first.label}`')
      ..writeln()
      ..writeln(
        'Paired over shared tasks, task-level bootstrap. `*` the 95 % interval excludes 0; `**` so does the Bonferroni '
        'interval for $comparisons comparison(s).',
      )
      ..writeln()
      ..writeln('| run | tasks | Δ success [95 %] | Bonferroni | Δ score [95 %] | Bonferroni |')
      ..writeln('|---|---:|---|---|---|---|');
    for (final label in deltas.map((x) => x.label).toSet()) {
      final cells = <String>[];
      var tasks = 0;
      for (final metric in ['success', 'weighted_score']) {
        final delta = deltas.where((x) => x.label == label && x.metric == metric).firstOrNull;
        if (delta == null) {
          cells.addAll(['—', '—']);
          continue;
        }
        tasks = delta.tasks;
        final mark = delta.significantAdjusted ? ' **' : (delta.significant ? ' *' : '');
        cells
          ..add('${d(delta.ci.meanDiff)} [${d(delta.ci.low)}, ${d(delta.ci.high)}]$mark')
          ..add('[${d(delta.adjusted.low)}, ${d(delta.adjusted.high)}]');
      }
      buffer.writeln('| `$label` | $tasks | ${cells.join(' | ')} |');
    }
    buffer
      ..writeln()
      ..writeln('## Tasks to read before trusting their numbers')
      ..writeln();
    if (suspects.isEmpty) buffer.writeln('None.');
    for (final entry in suspects.entries) {
      buffer.writeln('- `${entry.key}`: ${entry.value.join('; ')}');
    }
    if (heldOut > 0) {
      buffer
        ..writeln()
        ..writeln('$heldOut held-out task(s) are counted in the run table only.');
    }
    return buffer.toString();
  }

  static Map<String, List<num>> _byTask(List<EpisodeRecord> records, num Function(EpisodeRecord) value) {
    final map = <String, List<num>>{};
    for (final r in records) {
      map.putIfAbsent(r.taskId, () => []).add(value(r));
    }
    return map;
  }

  static List<({List<num> a, List<num> b})> _clusters(List<EpisodeRecord> a, List<EpisodeRecord> b, String metric, Set<String> heldOut) {
    num value(EpisodeRecord r) => metric == 'success' ? (r.verdict.type == .success ? 1 : 0) : r.verdict.score;
    bool counts(EpisodeRecord r) => r.verdict.type != .error && !heldOut.contains(r.taskId);
    final left = _byTask(a.where(counts).toList(), value);
    final right = _byTask(b.where(counts).toList(), value);
    return [
      for (final task in left.keys.toList()..sort())
        if (right[task] case final other?) (a: left[task]!, b: other),
    ];
  }

  /// The verdict's score without the criteria whose detail key contains
  /// [setAside], reweighted over the rest; null without such criteria.
  static double? _scoreWithout(Verdict verdict, String setAside) {
    final kept = [
      for (final entry in verdict.details.entries)
        if (!entry.key.contains(setAside) && entry.value is Map && (entry.value as Map)['weight'] is num) entry.value as Map,
    ];
    final weight = kept.fold<num>(0, (sum, d) => sum + (d['weight'] as num));
    if (weight <= 0) return null;
    return kept.fold<num>(0, (sum, d) => sum + ((d['score'] as num?) ?? 0) * (d['weight'] as num)) / weight;
  }
}
