import 'dart:math' as math;

/// Statistical helpers for aggregation (spec §6.5): distribution-free
/// summaries plus Wilson confidence intervals for rates.
abstract final class Stats {
  static double mean(List<num> values) => values.isEmpty ? double.nan : values.fold(0.0, (a, b) => a + b) / values.length;

  static double median(List<num> values) => percentile(values, 50);

  /// Percentile with linear interpolation between closest ranks.
  static double percentile(List<num> values, double p) {
    if (values.isEmpty) return double.nan;
    final sorted = List<num>.of(values)..sort();
    if (sorted.length == 1) return sorted.first.toDouble();
    final rank = (p / 100) * (sorted.length - 1);
    final lower = rank.floor();
    final upper = rank.ceil();
    if (lower == upper) return sorted[lower].toDouble();
    final weight = rank - lower;
    return sorted[lower] * (1 - weight) + sorted[upper] * weight;
  }

  static double stdDev(List<num> values) {
    if (values.length < 2) return 0;
    final m = mean(values);
    final sumSquares = values.fold(0.0, (a, b) => a + (b - m) * (b - m));
    return math.sqrt(sumSquares / (values.length - 1));
  }

  /// Cohen's κ for two raters over paired categorical labels — used for the
  /// judge calibration against manually labelled samples (spec §5.2; κ is
  /// reported in the thesis).
  static double cohensKappa<T>(List<T> rater1, List<T> rater2) {
    if (rater1.length != rater2.length || rater1.isEmpty) {
      throw ArgumentError('ratings must be non-empty and of equal length');
    }
    final n = rater1.length;
    final categories = {...rater1, ...rater2};
    var agreement = 0;
    for (var i = 0; i < n; i++) {
      if (rater1[i] == rater2[i]) agreement++;
    }
    final po = agreement / n;
    var pe = 0.0;
    for (final category in categories) {
      final p1 = rater1.where((r) => r == category).length / n;
      final p2 = rater2.where((r) => r == category).length / n;
      pe += p1 * p2;
    }
    // pe == 1 means both raters used a single category: κ = 0/0, so undefined,
    // not perfect. Callers render it as "—" and serialize it as null.
    if (pe == 1) return double.nan;
    return (po - pe) / (1 - pe);
  }

  /// Unbiased pass^k estimator: probability that *all* k of k independently
  /// drawn episodes of the same task succeed, given [successes] successes in
  /// [n] repetitions — `C(c, k) / C(n, k)` (τ-bench, arXiv 2406.12045).
  ///
  /// Repetitions are drawn without replacement from the n episodes actually
  /// run, so this is not `success_rate^k`. pass^1 equals the plain success
  /// rate; the decay towards pass^n is the consistency of the agent.
  static double passHatK(int successes, int n, int k) {
    if (n <= 0) return double.nan;
    if (k < 1 || k > n) {
      throw ArgumentError('k must be in [1, n] (k=$k, n=$n)');
    }
    if (successes < k) return 0;
    // Multiplicative form of C(c, k) / C(n, k) — no factorial overflow.
    var p = 1.0;
    for (var i = 0; i < k; i++) {
      p *= (successes - i) / (n - i);
    }
    return p;
  }

  /// Percentile-bootstrap 95% CI for the difference of means (b − a) —
  /// distribution-free pairwise agent comparison (spec §6.5). Seeded for
  /// reproducibility.
  static ({double meanDiff, double low, double high}) bootstrapMeanDiff(List<num> a, List<num> b, {int iterations = 10000, int seed = 42}) {
    if (a.isEmpty || b.isEmpty) {
      return (meanDiff: double.nan, low: double.nan, high: double.nan);
    }
    final random = math.Random(seed);
    List<num> resample(List<num> source) => [for (var i = 0; i < source.length; i++) source[random.nextInt(source.length)]];
    final diffs = <double>[for (var i = 0; i < iterations; i++) mean(resample(b)) - mean(resample(a))];
    return (meanDiff: mean(b) - mean(a), low: percentile(diffs, 2.5), high: percentile(diffs, 97.5));
  }

  /// Smallest difference in a rate that [n] episodes per arm could detect
  /// at 95% confidence and 80% power, taken at the worst case p=0.5:
  /// `(1.96 + 0.84) * sqrt(2 * 0.25 / n)`.
  ///
  /// Reported so that two agents inside each other's intervals are not read
  /// as different. It assumes independent episodes, which repetitions of one
  /// task are not, so the true figure is larger — this is a floor.
  static double minimumDetectableDifference(int n) => n <= 0 ? double.nan : 2.8 * math.sqrt(0.5 / n);

  /// Paired, clustered bootstrap (Miller 2024): each cluster (a task) gives
  /// one difference `mean(b) − mean(a)`; clusters are resampled, not
  /// episodes, since episodes of one task are not independent.
  static ({double meanDiff, double low, double high}) pairedClusterBootstrap(
    List<({List<num> a, List<num> b})> clusters, {
    int iterations = 10000,
    int seed = 42,
  }) {
    final diffs = [
      for (final c in clusters)
        if (c.a.isNotEmpty && c.b.isNotEmpty) mean(c.b) - mean(c.a),
    ];
    if (diffs.isEmpty) {
      return (meanDiff: double.nan, low: double.nan, high: double.nan);
    }
    final random = math.Random(seed);
    final means = <double>[
      for (var i = 0; i < iterations; i++) mean([for (var j = 0; j < diffs.length; j++) diffs[random.nextInt(diffs.length)]]),
    ];
    return (meanDiff: mean(diffs), low: percentile(means, 2.5), high: percentile(means, 97.5));
  }

  /// 95% interval for a rate pooled over clusters (tasks), after Miller 2024,
  /// "Adding Error Bars to Evals": the cluster-robust standard error `sqrt(Σ_c
  /// (Σ_{i∈c} (x_i − x̄))²) / n`.
  ///
  /// Never narrower than the Wilson interval, which also covers 0 and 1, where
  /// the clustered SE vanishes. With fewer than two clusters it *is* the Wilson
  /// interval.
  static ({double low, double high}) clusteredRateCi(List<({String cluster, num value})> observations, {double z = 1.96}) {
    final n = observations.length;
    final successes = observations.where((o) => o.value >= 1).length;
    final wilsonCi = wilson(successes, n, z: z);
    final clusters = {for (final o in observations) o.cluster};
    if (clusters.length < 2) return wilsonCi;
    final mean = successes / n;
    final residuals = <String, double>{};
    for (final o in observations) {
      final x = o.value >= 1 ? 1.0 : 0.0;
      residuals.update(o.cluster, (r) => r + x - mean, ifAbsent: () => x - mean);
    }
    final se = math.sqrt(residuals.values.fold(0.0, (sum, r) => sum + r * r)) / n;
    return (
      low: math.min(wilsonCi.low, (mean - z * se).clamp(0, 1).toDouble()),
      high: math.max(wilsonCi.high, (mean + z * se).clamp(0, 1).toDouble()),
    );
  }

  /// 95% Wilson score interval for a proportion (spec §6.1: success_rate CI).
  static ({double low, double high}) wilson(int successes, int n, {double z = 1.96}) {
    if (n == 0) return (low: 0, high: 1);
    final pHat = successes / n;
    final z2 = z * z;
    final denominator = 1 + z2 / n;
    final center = pHat + z2 / (2 * n);
    final margin = z * math.sqrt(pHat * (1 - pHat) / n + z2 / (4 * n * n));
    return (low: ((center - margin) / denominator).clamp(0, 1), high: ((center + margin) / denominator).clamp(0, 1));
  }
}
