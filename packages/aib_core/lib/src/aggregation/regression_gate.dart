import 'aggregator.dart';

/// What [RegressionGate] holds against a candidate run.
enum RegressionKind {
  /// Passed at least once in the baseline, never in the candidate.
  newlyFailing,

  /// The mean score fell by more than the tolerance.
  scoreDrop,

  /// Passed every repetition in the baseline, only some in the candidate:
  /// pass^k broke while the mean may barely move.
  turnedFlaky,
}

final class Regression {
  const Regression({required this.kind, required this.task, required this.baseline, required this.candidate, this.agent});

  final RegressionKind kind;

  /// The task's cluster: the task, or the task in one rewording.
  final String task;

  /// Null when both runs hold one agent each and are matched task by task.
  final String? agent;

  /// Mean score and passes/episodes, baseline and candidate.
  final GroupScore baseline;
  final GroupScore candidate;

  String get label => agent == null ? task : '$agent/$task';

  @override
  String toString() => switch (kind) {
    .newlyFailing => '$label newly failing: ${baseline.passes}/${baseline.n} -> ${candidate.passes}/${candidate.n}',
    .scoreDrop => '$label score ${baseline.mean.toStringAsFixed(2)} -> ${candidate.mean.toStringAsFixed(2)}',
    .turnedFlaky => '$label turned flaky: ${baseline.passes}/${baseline.n} -> ${candidate.passes}/${candidate.n}',
  };
}

/// Episodes of one task (cluster) in one run, scored.
final class GroupScore {
  GroupScore(List<EpisodeRecord> records)
    : n = records.length,
      passes = records.where((r) => r.verdict.type == .success).length,
      mean = records.isEmpty ? 0 : records.fold<double>(0, (sum, r) => sum + r.verdict.score) / records.length;

  final int n;
  final int passes;
  final double mean;
}

/// The CI front end of a comparison (`aib gate`): a candidate run regresses
/// against a baseline when a task newly fails, its score drops by more than
/// [tolerance], or a task that passed every repetition no longer does.
///
/// A task only one run holds is listed as [unmatched], never as a regression.
final class RegressionGate {
  const RegressionGate({this.tolerance = 0.2});

  /// The largest drop in a task's mean score that is not a regression.
  final double tolerance;

  GateResult check(List<EpisodeRecord> baseline, List<EpisodeRecord> candidate) {
    // One agent on each side (the usual case, two arms of one study): match
    // task by task whatever the agents are called. Otherwise by agent too.
    final byTaskOnly = _agents(baseline).length == 1 && _agents(candidate).length == 1;
    String key(EpisodeRecord r) => byTaskOnly ? r.cluster : '${r.agentId}\u0000${r.cluster}';
    final before = _group(baseline, key);
    final after = _group(candidate, key);
    final regressions = <Regression>[];
    for (final entry in before.entries) {
      final now = after[entry.key];
      if (now == null) continue;
      final then = GroupScore(entry.value);
      final score = GroupScore(now);
      final parts = entry.key.split('\u0000');
      Regression of(RegressionKind kind) =>
          Regression(kind: kind, task: parts.last, agent: byTaskOnly ? null : parts.first, baseline: then, candidate: score);
      if (then.passes > 0 && score.passes == 0) {
        regressions.add(of(RegressionKind.newlyFailing));
      } else if (then.mean - score.mean > tolerance) {
        regressions.add(of(RegressionKind.scoreDrop));
      } else if (then.n > 1 && then.passes == then.n && score.passes < score.n) {
        regressions.add(of(RegressionKind.turnedFlaky));
      }
    }
    return GateResult(
      regressions: regressions,
      unmatched: [
        for (final k in {...before.keys, ...after.keys})
          if (!before.containsKey(k) || !after.containsKey(k)) k.replaceAll('\u0000', '/'),
      ]..sort(),
    );
  }

  static Set<String> _agents(List<EpisodeRecord> records) => {for (final r in records) r.agentId};

  static Map<String, List<EpisodeRecord>> _group(List<EpisodeRecord> records, String Function(EpisodeRecord) key) {
    final groups = <String, List<EpisodeRecord>>{};
    for (final record in records) {
      groups.putIfAbsent(key(record), () => []).add(record);
    }
    return groups;
  }
}

final class GateResult {
  const GateResult({required this.regressions, required this.unmatched});

  final List<Regression> regressions;

  /// Tasks (`agent/task` where agents are matched) only one run holds.
  final List<String> unmatched;

  bool get passed => regressions.isEmpty;
}
