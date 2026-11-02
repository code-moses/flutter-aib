import 'dart:math' as math;

import '../aggregation/aggregator.dart';
import '../aggregation/stats.dart';
import '../common/json.dart';
import '../task/task.dart';

/// Human label for one episode: did a person consider the task solved? Binary
/// even though the oracles grade, because the question is whether the automatic
/// verdict agrees with a human.
enum HumanLabel { success, failure }

/// Agreement between an automatic yes/no and a human yes/no — the statistics
/// both calibration levels report. "Positive" is success (episode level) or
/// yes (criterion level).
abstract base class BinaryAgreement {
  BinaryAgreement(this.pairs, {required this.disagreements})
    : truePositives = pairs.where((p) => p.$1 && p.$2).length,
      falsePositives = pairs.where((p) => p.$1 && !p.$2).length,
      falseNegatives = pairs.where((p) => !p.$1 && p.$2).length,
      trueNegatives = pairs.where((p) => !p.$1 && !p.$2).length;

  /// (automatic, human) per labelled unit.
  final List<(bool, bool)> pairs;

  final int truePositives;
  final int falsePositives;
  final int falseNegatives;
  final int trueNegatives;

  /// Units where the two disagree — the list to look at by hand.
  final List<String> disagreements;

  int get n => pairs.length;

  /// Cohen's κ; NaN when undefined (no labels, or both raters constant).
  late final double kappa = pairs.isEmpty ? double.nan : Stats.cohensKappa([for (final p in pairs) p.$1], [for (final p in pairs) p.$2]);

  /// 95% percentile-bootstrap interval of [kappa] over the labelled units
  /// (seeded; resamples where κ is undefined are left out).
  late final ({double low, double high}) kappaCi = _kappaCi();

  ({double low, double high}) _kappaCi({int iterations = 2000, int seed = 42}) {
    if (pairs.length < 2 || kappa.isNaN) {
      return (low: double.nan, high: double.nan);
    }
    final random = math.Random(seed);
    final values = <double>[];
    for (var i = 0; i < iterations; i++) {
      final sample = [for (var j = 0; j < pairs.length; j++) pairs[random.nextInt(pairs.length)]];
      final value = Stats.cohensKappa([for (final p in sample) p.$1], [for (final p in sample) p.$2]);
      if (!value.isNaN) values.add(value);
    }
    if (values.isEmpty) return (low: double.nan, high: double.nan);
    return (low: Stats.percentile(values, 2.5), high: Stats.percentile(values, 97.5));
  }

  double get agreement => n == 0 ? double.nan : (truePositives + trueNegatives) / n;

  double get precision => truePositives + falsePositives == 0 ? double.nan : truePositives / (truePositives + falsePositives);

  double get recall => truePositives + falseNegatives == 0 ? double.nan : truePositives / (truePositives + falseNegatives);

  double get f1 {
    final p = precision, r = recall;
    if (p.isNaN || r.isNaN || p + r == 0) return double.nan;
    return 2 * p * r / (p + r);
  }

  /// Undefined statistics become `null` rather than NaN — JSON has no NaN,
  /// and a missing value is what they are.
  static double? finite(double v) => v.isNaN ? null : v;

  JsonMap agreementJson() => {
    'n': n,
    'agreement': finite(agreement),
    'kappa': finite(kappa),
    'kappaCi': [finite(kappaCi.low), finite(kappaCi.high)],
    'precision': finite(precision),
    'recall': finite(recall),
    'f1': finite(f1),
    'confusion': {'truePositives': truePositives, 'falsePositives': falsePositives, 'falseNegatives': falseNegatives, 'trueNegatives': trueNegatives},
  };

  /// Statistic table and confusion matrix, rows automatic, columns human.
  String agreementMarkdown({required String automatic, required String human, required String yes, required String no}) {
    String fmt(double v) => v.isNaN ? '—' : v.toStringAsFixed(3);
    return (StringBuffer()
          ..writeln('| Statistic | Value |')
          ..writeln('|---|---|')
          ..writeln('| Raw agreement | ${fmt(agreement)} |')
          ..writeln(
            "| Cohen's κ | ${fmt(kappa)} "
            '[${fmt(kappaCi.low)}, ${fmt(kappaCi.high)}] |',
          )
          ..writeln('| Precision | ${fmt(precision)} |')
          ..writeln('| Recall | ${fmt(recall)} |')
          ..writeln('| F1 | ${fmt(f1)} |')
          ..writeln()
          ..writeln('| | $human: $yes | $human: $no |')
          ..writeln('|---|---|---|')
          ..writeln('| **$automatic: $yes** | $truePositives | $falsePositives |')
          ..writeln('| **$automatic: $no** | $falseNegatives | $trueNegatives |'))
        .toString();
  }
}

/// A label cell. `yes`/`no` are accepted where [yesNo] (criterion rows).
HumanLabel _parseLabel(String raw, String line, {required bool yesNo}) {
  return switch (raw) {
    'success' || '1' || 'true' || 'pass' => HumanLabel.success,
    'failure' || '0' || 'false' || 'fail' => HumanLabel.failure,
    'yes' when yesNo => HumanLabel.success,
    'no' when yesNo => HumanLabel.failure,
    _ => throw FormatException(
      'unknown label "$raw" '
      '(use ${yesNo ? 'yes/no, ' : 'success/failure, '}1/0, true/false)',
      line,
    ),
  };
}

/// Result of comparing the automatic verdicts of a run against a manually
/// labelled sample (spec §5.2: "the judge reliability is calibrated once
/// against a small, manually labelled sample; Cohen's κ is reported").
final class JudgeCalibration extends BinaryAgreement {
  JudgeCalibration(
    super.pairs, {
    required super.disagreements,
    required this.splitDecisions,
    required this.judgedCriteria,
    required this.unlabelled,
    required this.missing,
  });

  /// Rubric criteria decided by a *non-unanimous* k-vote (e.g. 2:1 of k=3).
  /// A judge whose majority is regularly split is unstable even when it
  /// happens to agree with the human — a number SPA-Bench does not report.
  final int splitDecisions;

  /// Rubric criteria that were voted on at all (denominator of the above).
  final int judgedCriteria;

  /// Episodes in the run without a human label (not an error — the sample
  /// is meant to be small).
  final int unlabelled;

  /// Labels naming an episode that is not in the run.
  final List<String> missing;

  /// Share of rubric criteria whose majority was not unanimous.
  double get splitRate => judgedCriteria == 0 ? double.nan : splitDecisions / judgedCriteria;

  /// Compares the automatic verdicts of [records] against [labels]
  /// (episodeId -> label). Framework faults are excluded: they are not a
  /// judgement about the agent and there is nothing for a human to label.
  factory JudgeCalibration.compare(List<EpisodeRecord> records, Map<String, HumanLabel> labels) {
    final byEpisode = {
      for (final record in records)
        if (record.verdict.type != .error) record.episodeId: record,
    };

    final disagreements = <String>[];
    final missing = <String>[];
    final paired = <(bool, bool)>[];
    for (final entry in labels.entries) {
      final record = byEpisode[entry.key];
      if (record == null) {
        missing.add(entry.key);
        continue;
      }
      final automatic = record.verdict.type == .success;
      final human = entry.value == .success;
      paired.add((automatic, human));
      if (automatic != human) disagreements.add(entry.key);
    }

    var split = 0;
    var judged = 0;
    for (final record in byEpisode.values) {
      for (final detail in record.verdict.detailsOfType(CriterionTypes.artifactRubric)) {
        final k = (detail['k'] as num?)?.toInt() ?? 0;
        final votes = detail['votes'];
        if (k == 0 || votes is! Map) continue;
        for (final vote in asJsonMap(votes).values) {
          final yes = (vote as num?)?.toInt() ?? 0;
          judged++;
          if (yes != 0 && yes != k) split++;
        }
      }
    }

    return JudgeCalibration(
      paired,
      disagreements: disagreements..sort(),
      splitDecisions: split,
      judgedCriteria: judged,
      unlabelled: byEpisode.keys.where((id) => !labels.containsKey(id)).length,
      missing: missing..sort(),
    );
  }

  JsonMap toJson() => {
    ...agreementJson(),
    'splitDecisions': splitDecisions,
    'judgedCriteria': judgedCriteria,
    'splitRate': BinaryAgreement.finite(splitRate),
    'disagreements': disagreements,
    'unlabelled': unlabelled,
    'missing': missing,
  };

  /// `calibration.md` — the artifact §5.2 promises the thesis will report.
  String toMarkdown({String? runId, String? judgeId}) {
    String fmt(double v) => v.isNaN ? '—' : v.toStringAsFixed(3);
    final buffer = StringBuffer('# Judge calibration\n');
    if (runId != null) buffer.writeln('\n- Run: `$runId`');
    if (judgeId != null) buffer.writeln('- Judge: `$judgeId`');
    // A sheet labelled per criterion (ADR 0008) carries no episode rows; a
    // table of dashes would read as a failed calibration.
    if (n == 0) {
      buffer.writeln('- Episode-level labels: none; the criterion level below is the calibration.');
    } else {
      buffer
        ..writeln(
          '- Labelled episodes: $n'
          '${unlabelled > 0 ? ' (of ${n + unlabelled} in the run)' : ''}',
        )
        ..writeln()
        ..write(
          agreementMarkdown(
            automatic: 'automatic',
            human: 'human',
            yes: 'success',
            no: 'failure',
          ).replaceFirst('\n\n', '\n\n## Confusion matrix\n\n'),
        );
    }

    if (judgedCriteria > 0) {
      buffer
        ..writeln()
        ..writeln('## Judge stability')
        ..writeln()
        ..writeln(
          '$splitDecisions of $judgedCriteria rubric criteria '
          '(${fmt(splitRate)}) were decided by a non-unanimous vote — the '
          'majority was load-bearing that often.',
        );
    }
    if (disagreements.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## Disagreements (inspect these by hand)')
        ..writeln();
      for (final id in disagreements) {
        buffer.writeln('- `$id`');
      }
    }
    if (missing.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## Labels without an episode')
        ..writeln();
      for (final id in missing) {
        buffer.writeln('- `$id`');
      }
    }
    return buffer.toString();
  }

  /// Parses `episodeId,label` CSV (header optional). Accepted labels:
  /// `success`/`failure`, `1`/`0`, `true`/`false`, `pass`/`fail`.
  static Map<String, HumanLabel> parseLabels(String csv) {
    final labels = <String, HumanLabel>{};
    for (final rawLine in csv.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split(',');
      if (parts.length < 2) {
        throw FormatException('expected "episodeId,label"', line);
      }
      // Per-criterion rows (episodeId,criterionId,label) live in the same
      // file and are read by [parseCriterionLabels].
      if (parts.length > 2) continue;
      final episodeId = parts[0].trim();
      final raw = parts[1].trim().toLowerCase();
      if (episodeId == 'episode_id' || episodeId == 'episodeId') continue;
      labels[episodeId] = _parseLabel(raw, line, yesNo: false);
    }
    return labels;
  }

  /// Parses the per-criterion rows `episodeId,criterionId,label` of the same
  /// CSV (episode-level rows are ignored here).
  static Map<CriterionLabelKey, HumanLabel> parseCriterionLabels(String csv) {
    final labels = <CriterionLabelKey, HumanLabel>{};
    for (final rawLine in csv.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split(',');
      if (parts.length < 3) continue; // episode-level row
      final episodeId = parts[0].trim();
      if (episodeId == 'episode_id' || episodeId == 'episodeId') continue;
      final criterionId = parts[1].trim();
      final raw = parts[2].trim().toLowerCase();
      labels[(episodeId: episodeId, criterionId: criterionId)] = _parseLabel(raw, line, yesNo: true);
    }
    return labels;
  }
}

/// One rubric criterion of one episode — the unit a rubric judge actually
/// decides.
typedef CriterionLabelKey = ({String episodeId, String criterionId});

/// Calibration at the level the judge works on: **one rubric criterion at a
/// time** (spec §5.2).
///
/// Where almost every surface earns partial credit, every episode verdict is
/// "not success", both raters are constant and episode-level κ is undefined.
/// Per criterion, n grows by the number of criteria and disagreement is
/// attributable to one question.
final class CriterionCalibration extends BinaryAgreement {
  CriterionCalibration(super.pairs, {required super.disagreements, required this.missing});

  /// Labels naming an episode or criterion the run does not contain.
  final List<String> missing;

  /// Compares the judge's per-criterion majority vote against human labels.
  factory CriterionCalibration.compare(List<EpisodeRecord> records, Map<CriterionLabelKey, HumanLabel> labels) {
    // Every rubric of an episode: a label names a criterion id, or
    // `<rubric>:<criterion id>` where two rubrics share an id.
    final votesByEpisode = <String, Map<String, ({int k, num yes})>>{};
    for (final record in records) {
      for (final detail in record.verdict.detailsOfType(CriterionTypes.artifactRubric)) {
        final k = (detail['k'] as num?)?.toInt() ?? 0;
        final votes = detail['votes'];
        if (k == 0 || votes is! Map) continue;
        final byId = votesByEpisode.putIfAbsent(record.episodeId, () => {});
        for (final entry in asJsonMap(votes).entries) {
          if (entry.value is! num) continue;
          final vote = (k: k, yes: entry.value as num);
          byId.putIfAbsent(entry.key, () => vote);
          byId['${detail['rubric']}:${entry.key}'] = vote;
        }
      }
    }

    final disagreements = <String>[];
    final missing = <String>[];
    final paired = <(bool, bool)>[];

    for (final entry in labels.entries) {
      final vote = votesByEpisode[entry.key.episodeId]?[entry.key.criterionId];
      if (vote == null) {
        missing.add('${entry.key.episodeId}/${entry.key.criterionId}');
        continue;
      }
      // Same majority rule as ArtifactRubricEvaluator (ties count as no).
      final automatic = vote.yes.toInt() * 2 > vote.k;
      final human = entry.value == .success;
      paired.add((automatic, human));
      if (automatic != human) {
        disagreements.add('${entry.key.episodeId}/${entry.key.criterionId}');
      }
    }

    return CriterionCalibration(paired, disagreements: disagreements..sort(), missing: missing..sort());
  }

  JsonMap toJson() => {...agreementJson(), 'disagreements': disagreements, 'missing': missing};

  /// Markdown section appended to `calibration.md`.
  String toMarkdown() {
    final buffer = StringBuffer()
      ..writeln('## Per rubric criterion')
      ..writeln()
      ..writeln('- Labelled criteria: $n')
      ..writeln()
      ..write(agreementMarkdown(automatic: 'judge', human: 'human', yes: 'yes', no: 'no'));
    if (disagreements.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Disagreements:')
        ..writeln();
      for (final id in disagreements) {
        buffer.writeln('- `$id`');
      }
    }
    return buffer.toString();
  }
}
