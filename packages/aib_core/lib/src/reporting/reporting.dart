import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../aggregation/aggregator.dart';
import '../aggregation/stats.dart';
import '../common/json.dart';
import '../engine/run_manifest.dart';
import '../evaluation/judge_provenance.dart';
import 'html_reporter.dart';
import 'junit_reporter.dart';

final class RunReportData {
  const RunReportData({this.manifest, required this.records, required this.aggregates, this.judge});

  final RunManifest? manifest;
  final List<EpisodeRecord> records;
  final List<AggregateRow> aggregates;

  /// Who produced the rubric scores, if the run has any (P6).
  final JudgeProvenance? judge;

  /// agentId -> self-reported model, from the run manifest.
  Map<String, String> get agentModels => {
    for (final entry in manifest?.agents.entries ?? const <MapEntry<String, JsonMap>>[])
      entry.key: '${asJsonMap(entry.value['metadata'])['model'] ?? 'n/a'}',
  };

  /// Agents whose model is also the judge model — SPA-Bench's "did the judge
  /// grade its own homework?" threat, made visible instead of implied.
  List<String> get judgeAgentOverlap {
    final judgeId = judge?.judgeId;
    if (judgeId == null) return const [];
    return [
      for (final entry in agentModels.entries)
        if (entry.value != 'n/a' && judgeId.contains(entry.value)) entry.key,
    ];
  }
}

/// Reporter port (P7): report formats are plugged in by name.
abstract class Reporter {
  String get format;
  String get fileName;
  String render(RunReportData data);

  void writeTo(RunReportData data, Directory directory) {
    directory.createSync(recursive: true);
    File(p.join(directory.path, fileName)).writeAsStringSync(render(data));
  }
}

/// `metrics.csv` in long format — directly analyzable in Python/R (§9).
final class CsvReporter extends Reporter {
  @override
  String get format => 'csv';
  @override
  String get fileName => 'metrics.csv';

  @override
  String render(RunReportData data) {
    final buffer = StringBuffer()..writeln('run_id,episode_id,task_id,agent_id,repetition,verdict,score,metric,value');
    for (final record in data.records) {
      for (final entry in record.metrics.entries) {
        if (entry.value == null) continue;
        buffer.writeln(
          [
            record.runId,
            record.episodeId,
            record.taskId,
            record.agentId,
            record.repetition,
            record.verdict.type.name,
            record.verdict.score,
            entry.key,
            entry.value,
          ].map(csvCell).join(','),
        );
      }
    }
    return buffer.toString();
  }
}

final class JsonReporter extends Reporter {
  @override
  String get format => 'json';
  @override
  String get fileName => 'report.json';

  @override
  String render(RunReportData data) => const JsonEncoder.withIndent('  ').convert({
    'manifest': ?data.manifest?.toJson(),
    'episodes': [
      for (final record in data.records)
        {
          'episodeId': record.episodeId,
          'taskId': record.taskId,
          'agentId': record.agentId,
          'repetition': record.repetition,
          'verdict': record.verdict.toJson(),
          'metrics': record.metrics,
        },
    ],
    'aggregates': [
      for (final row in data.aggregates)
        {
          'agentId': row.agentId,
          'taskId': row.taskId,
          'metric': row.metric,
          'n': row.n,
          'mean': row.mean,
          'median': row.median,
          'p95': row.p95,
          if (row.ciLow != null) 'ciLow': row.ciLow,
          if (row.ciHigh != null) 'ciHigh': row.ciHigh,
        },
    ],
  });
}

/// `report.md` — primary comparison table (§6.5) for direct inclusion in
/// the thesis.
final class MarkdownReporter extends Reporter {
  @override
  String get format => 'md';
  @override
  String get fileName => 'report.md';

  @override
  String render(RunReportData data) {
    final buffer = StringBuffer()..writeln('# AIB Report');
    _writeRun(buffer, data);
    _writeJudge(buffer, data);
    _writeReadingNotes(buffer, data);
    final tables = _MarkdownTables(buffer, data);
    tables.overview();
    tables.robustness();
    tables.termination();
    tables.reliability();
    tables.scorePerTask();
    return buffer.toString();
  }

  void _writeRun(StringBuffer buffer, RunReportData data) {
    final manifest = data.manifest;
    if (manifest != null) {
      buffer
        ..writeln()
        ..writeln('- Run: `${manifest.runId}` (${manifest.createdAt})')
        ..writeln(
          '- Suite: `${manifest.suiteName}` '
          '(hash `${shortHash(manifest.suiteHash)}`)',
        )
        ..writeln(
          '- Environment: `${manifest.environmentId}` · '
          'Repetitions: ${manifest.repetitions} · Seed: ${manifest.seed}',
        );
      if (manifest.resumes.isNotEmpty) {
        buffer.writeln(
          '- Executed in ${manifest.resumes.length + 1} '
          'sitting(s) (resumed ${manifest.resumes.join(', ')})',
        );
      }
    }
  }

  /// Provenance of the rubric scores (P6): agent models and judge model side by
  /// side, so an overlap cannot hide.
  void _writeJudge(StringBuffer buffer, RunReportData data) {
    final judge = data.judge;
    if (judge != null) {
      buffer
        ..writeln()
        ..writeln('## Judge')
        ..writeln()
        ..writeln(
          '- Judge: `${judge.judgeId}` (k=${judge.k}'
          '${judge.pinnedModel == null ? '' : ', pinned to '
                    '`${judge.pinnedModel}`'})',
        )
        ..writeln('- Agent models: ${data.agentModels.entries.map((e) => '`${e.key}` -> `${e.value}`').join(' · ')}');
      for (final rubric in judge.rubrics.entries) {
        buffer.writeln(
          '- Rubric `${rubric.key}` (hash '
          '`${shortHash(rubric.value)}`)',
        );
      }
      final overlap = data.judgeAgentOverlap;
      if (overlap.isNotEmpty) {
        buffer.writeln(
          '- ⚠️ **The judge model is also the backbone of '
          '${overlap.join(', ')}** — rubric scores for these agents are '
          'not independent of the model under evaluation.',
        );
      }
    }
  }

  /// A blank is not a zero, and an n too small to separate two agents should say
  /// so before the tables do.
  void _writeReadingNotes(StringBuffer buffer, RunReportData data) {
    final scored = data.records.where((r) => r.verdict.type != .error).length;
    final unmeasured = <String>{
      for (final record in data.records)
        for (final entry in record.metrics.entries)
          if (entry.value == null) entry.key,
    }..removeWhere((metric) => data.records.any((record) => record.metrics[metric] != null));
    buffer
      ..writeln()
      ..writeln('## Reading this report')
      ..writeln()
      ..writeln(
        '- `—` means the metric was **not applicable** to those episodes '
        '(no fingerprints, no milestones, nothing to recover from), not that '
        'it was zero.',
      )
      ..writeln(
        '- $scored scored episode(s): the smallest difference in a rate this '
        'many could separate is about '
        '${Stats.minimumDetectableDifference(scored).toStringAsFixed(2)} '
        '(95%, 80% power, independent episodes — repetitions of one task are '
        'not, so read it as a floor).',
      );
    if (unmeasured.isNotEmpty) {
      buffer.writeln(
        '- Measured by nothing in this run: '
        '${(unmeasured.toList()..sort()).map((m) => '`$m`').join(', ')}.',
      );
    }
  }
}

/// The tables of `report.md`, one row per agent.
final class _MarkdownTables {
  _MarkdownTables(this.buffer, this.data) : agents = data.records.map((r) => r.agentId).toSet().toList()..sort();

  final StringBuffer buffer;
  final RunReportData data;
  final List<String> agents;

  String fmt(double? v) => v == null ? '—' : v.toStringAsFixed(2);

  double? cell(String agentId, String taskId, String metric, {bool median = false}) {
    for (final row in data.aggregates) {
      if (row.agentId == agentId && row.taskId == taskId && row.metric == metric) {
        return median ? row.median : row.mean;
      }
    }
    return null;
  }

  void overview() {
    buffer
      ..writeln()
      ..writeln('## Agent overview')
      ..writeln()
      ..writeln(
        '| Agent | weighted_score | success_rate (95% CI) | '
        'wall_clock_ms (median) | tokens_total (median) | cost_usd (median) '
        '| infrastructure_error_rate |',
      )
      ..writeln('|---|---|---|---|---|---|---|');
    for (final agent in agents) {
      String successCell = '—';
      for (final row in data.aggregates) {
        if (row.agentId == agent && row.taskId == '*' && row.metric == 'success_rate') {
          successCell = '${fmt(row.mean)} [${fmt(row.ciLow)}, ${fmt(row.ciHigh)}]';
        }
      }
      final cost = cell(agent, '*', 'cost_usd', median: true);
      buffer.writeln(
        '| $agent '
        '| ${fmt(cell(agent, '*', 'weighted_score'))} '
        '| $successCell '
        '| ${fmt(cell(agent, '*', 'wall_clock_ms', median: true))} '
        '| ${fmt(cell(agent, '*', 'tokens_total', median: true))} '
        '| ${cost == null ? 'not priced' : cost.toStringAsFixed(4)} '
        '| ${fmt(cell(agent, '*', 'infrastructure_error_rate'))} |',
      );
    }
  }

  /// Only meaningful where episodes actually hit failures (§6.4), so the section
  /// is omitted when nothing failed.
  void robustness() {
    final anyFailures = data.aggregates.any((r) => r.metric == 'failed_envelope_count' && r.mean > 0);
    if (anyFailures) {
      buffer
        ..writeln()
        ..writeln('## Robustness & recovery')
        ..writeln()
        ..writeln(
          '| Agent | failed envelopes (median) | retries (median) | '
          'recovery_success_rate | recovery_time_ms (median) | '
          'self-corrections (median) |',
        )
        ..writeln('|---|---|---|---|---|---|');
      for (final agent in agents) {
        buffer.writeln(
          '| $agent '
          '| ${fmt(cell(agent, '*', 'failed_envelope_count', median: true))} '
          '| ${fmt(cell(agent, '*', 'retry_count', median: true))} '
          '| ${fmt(cell(agent, '*', 'recovery_success_rate'))} '
          '| ${fmt(cell(agent, '*', 'recovery_time_ms', median: true))} '
          '| ${fmt(cell(agent, '*', 'self_correction_count', median: true))} |',
        );
      }
    }
  }

  /// How episodes ended, not just whether they succeeded (SPA-Bench).
  void termination() {
    buffer
      ..writeln()
      ..writeln('## Termination quality')
      ..writeln()
      ..writeln(
        '| Agent | premature (said done, wasn\'t) | '
        'overdue (solved, never said so) | budget exhausted |',
      )
      ..writeln('|---|---|---|---|');
    for (final agent in agents) {
      buffer.writeln(
        '| $agent '
        '| ${fmt(cell(agent, '*', 'premature_termination_rate'))} '
        '| ${fmt(cell(agent, '*', 'overdue_termination_rate'))} '
        '| ${fmt(cell(agent, '*', 'budget_exhaustion_rate'))} |',
      );
    }
  }

  /// pass^k decay (τ-bench). pass^1 is the success rate; the drop towards pass^n
  /// shows how much of that rate is chance (P3).
  void reliability() {
    final kMax = data.aggregates
        .where((r) => r.taskId == '*' && r.metric.startsWith('pass_'))
        .map((r) => int.parse(r.metric.substring(5)))
        .fold(0, (a, b) => a > b ? a : b);
    if (kMax > 0) {
      buffer
        ..writeln()
        ..writeln(
          '## Reliability — pass^k (all k repetitions of a task '
          'succeed, averaged over tasks)',
        )
        ..writeln()
        ..writeln('| Agent | ${[for (var k = 1; k <= kMax; k++) 'pass^$k'].join(' | ')} |')
        ..writeln('|---|${'---|' * kMax}');
      for (final agent in agents) {
        final cells = [for (var k = 1; k <= kMax; k++) fmt(cell(agent, '*', 'pass_$k'))];
        buffer.writeln('| $agent | ${cells.join(' | ')} |');
      }
    }
  }

  void scorePerTask() {
    final tasks = data.records.map((r) => r.taskId).toSet().toList()..sort();
    buffer
      ..writeln()
      ..writeln('## weighted_score per agent × task')
      ..writeln()
      ..writeln('| Task | ${agents.join(' | ')} |')
      ..writeln('|---|${'---|' * agents.length}');
    for (final task in tasks) {
      final cells = [for (final agent in agents) fmt(cell(agent, task, 'weighted_score'))];
      buffer.writeln('| $task | ${cells.join(' | ')} |');
    }
  }
}

/// A hash short enough for a report.
String shortHash(String hash) => hash.length <= 12 ? hash : hash.substring(0, 12);

final class ReporterRegistry {
  ReporterRegistry() {
    for (final reporter in [CsvReporter(), JsonReporter(), MarkdownReporter(), HtmlReporter(), JunitReporter()]) {
      register(reporter);
    }
  }

  final Map<String, Reporter> _reporters = {};

  void register(Reporter reporter) => _reporters[reporter.format] = reporter;

  Reporter? operator [](String format) => _reporters[format];

  List<String> get formats => _reporters.keys.toList()..sort();
}
