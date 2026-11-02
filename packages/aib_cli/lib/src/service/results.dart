import 'package:aib_agents/aib_agents.dart';
import 'package:aib_core/aib_core.dart';

import '../label_sheet.dart';

/// A request [AibService] refuses, in words a person (or an agent) can act on.
///
/// The CLI prints [message] and exits with [exitCode]; [isUsage] marks a
/// malformed request, which the CLI raises as a `UsageException`. The MCP
/// server returns it as a tool error, never as a transport error.
final class AibError implements Exception {
  const AibError(this.message, {this.exitCode = 1, this.isUsage = false});

  final String message;
  final int exitCode;
  final bool isUsage;

  @override
  String toString() => message;
}

/// The runs differ in more than `vary` names, so a delta could come from
/// any of the differences. Keyed by run label; a pair has one key.
final class UnintendedDifferences extends AibError {
  const UnintendedDifferences(super.message, this.differences);

  final Map<String, List<ManifestDifference>> differences;
}

/// Raised when a run needs a judge to be scored and none was given.
final class MissingJudge extends AibError {
  const MissingJudge(super.message);
}

/// What to do when the suite has rubric criteria and no judge was passed.
enum WithoutJudge {
  /// Use `verdicts.json` as is.
  reusePersisted,

  /// Refuse; re-scoring would zero every rubric.
  refuse,

  /// Rubrics score 0. Explicit opt-in only.
  scoreAsZero,
}

/// What scoring a run needs besides the run: shared by evaluate, report,
/// compare, route and calibrate.
final class ScoringOptions {
  const ScoringOptions({
    this.judge,
    this.suite,
    this.metrics = const [],
    this.conventions = true,
    this.judgeK = defaultJudgeK,
    this.tasks,
    this.judgeCassette,
  });

  /// Majority votes per rubric criterion (spec §5.2 default k=3).
  static const defaultJudgeK = 3;

  /// Judge config file; null reuses `verdicts.json`.
  final String? judge;

  /// Suite file, when the path the manifest recorded does not resolve.
  final String? suite;

  /// Metric provider names to add.
  final List<String> metrics;

  /// Score with the intent/user bridge conventions.
  final bool conventions;
  final int judgeK;

  /// Only episodes of these tasks; null scores all. The MCP server scores
  /// a tuning agent's runs on the tuning split only.
  final Set<String>? tasks;

  /// A cassette the judge's calls are answered from and recorded to
  /// (`replayThenLive`): re-scoring the same run with the same judge then
  /// costs nothing and gives the same verdicts. Null asks the judge.
  final String? judgeCassette;

  ScoringOptions only(Set<String>? tasks) => ScoringOptions(
    judge: judge,
    suite: suite,
    metrics: metrics,
    conventions: conventions,
    judgeK: judgeK,
    tasks: tasks,
    judgeCassette: judgeCassette,
  );
}

/// A run's traces scored against its suite.
final class EvaluatedRun {
  const EvaluatedRun({
    required this.runDir,
    required this.manifest,
    required this.suite,
    required this.records,
    required this.judge,
    required this.metrics,
    this.reusedVerdicts = false,
    this.warnings = const [],
    this.notes = const [],
  });

  final String runDir;
  final RunManifest manifest;
  final TaskSuite suite;
  final List<EpisodeRecord> records;
  final JudgeProvenance? judge;
  final MetricsRegistry metrics;

  /// The rubric verdicts came from `verdicts.json`, not from a judge now.
  final bool reusedVerdicts;

  /// Something that may make the numbers wrong: a changed suite, foreign or
  /// unreadable traces, rubrics scored as 0.
  final List<String> warnings;

  /// Informational: where verdicts came from.
  final List<String> notes;

  List<AggregateRow> get aggregates => Aggregator(aggregates: metrics.aggregates, rates: metrics.rates).aggregate(records);

  /// The directory name, which carries the intent of a run
  /// ("m6-bad-semantics-…") where the run id only carries its timestamp.
  String get label => runLabel(runDir);
}

final class SuiteValidation {
  const SuiteValidation({required this.path, this.suite, this.errors = const [], this.warnings = const []});

  final String path;
  final TaskSuite? suite;
  final List<String> errors;
  final List<String> warnings;

  bool get isValid => errors.isEmpty && suite != null;

  JsonMap toJson() => {
    'path': path,
    'valid': isValid,
    if (errors.isNotEmpty) 'errors': errors,
    if (warnings.isNotEmpty) 'warnings': warnings,
    if (suite case final suite?) ...suiteSummaryJson(suite),
  };
}

/// Name, size, hash, and the tags, languages and criterion kinds its tasks
/// use: what a caller needs to choose a suite, and no ground truth.
JsonMap suiteSummaryJson(TaskSuite suite) => {
  'name': suite.name,
  'tasks': suite.tasks.length,
  'defaultRepetitions': suite.defaultRepetitions,
  'hash': suite.sourceHash,
  'tags': ({for (final task in suite.tasks) ...task.tags}.toList()..sort()),
  'languages': ({for (final task in suite.tasks) taskLanguage(task)}.nonNulls.toList()..sort()),
  'criterionKinds': ({for (final task in suite.tasks) ...task.successCriteria.map((c) => c.type)}.toList()..sort()),
};

/// A task's `lang:` tag, else the detected language of its instruction.
String? taskLanguage(TaskSpec task) {
  for (final tag in task.tags) {
    if (tag.startsWith('lang:')) return tag.substring(5);
  }
  return detectLanguage(task.instruction);
}

/// An agent config built without running it: the agent's manifest is what a
/// run would record, so its hashes identify the arm before it spends anything.
final class AgentConfigCheck {
  const AgentConfigCheck({required this.agent, required this.config, this.path, this.manifest, this.error});

  /// The agent kind the config was built as (`prepared`, `hybrid`, …).
  final String agent;
  final JsonMap config;
  final String? path;
  final AgentManifest? manifest;

  /// Why the build refused, as the builder said it.
  final String? error;

  bool get built => manifest != null;

  JsonMap get configBlocks => asJsonMap(manifest?.metadata['configBlocks']);

  JsonMap toJson() {
    final metadata = manifest?.metadata ?? const {};
    final decisions = asJsonMap(asJsonMap(configBlocks['decisions'])['config']);
    return {
      'agent': agent,
      'path': ?path,
      'built': built,
      'error': ?error,
      if (manifest case final manifest?) ...{
        'agentId': manifest.agentId,
        'model': ?metadata['model'],
        'agentConfigHash': ?metadata['agentConfigHash'],
        'promptHash': ?metadata['promptHash'],
        'blocks': {for (final entry in configBlocks.entries) entry.key: asJsonMap(entry.value)['hash']},
        if (decisions.isNotEmpty) 'decisions': decisions,
      },
    };
  }
}

final class RunOutcome {
  const RunOutcome({required this.manifest, required this.outDir, required this.executed, required this.skipped});

  final RunManifest manifest;
  final String outDir;
  final int executed;
  final int skipped;

  JsonMap toJson() => {'runId': manifest.runId, 'runDir': outDir, 'executed': executed, 'reused': skipped};
}

final class EvaluationSummary {
  const EvaluationSummary({required this.run, required this.judge, required this.spend, required this.written, this.judgeWarnings = const []});

  final EvaluatedRun run;

  /// The judge that scored the rubrics, with what scoring cost.
  final JudgeProvenance? judge;
  final JudgeSpend spend;

  /// `verdicts.json` and `metrics.csv`; empty when the verdicts were reused.
  final List<String> written;

  /// Why the rubric scores may not mean what they seem to.
  final List<String> judgeWarnings;

  Map<String, int> get byVerdict {
    final counts = <String, int>{};
    for (final record in run.records) {
      counts.update(record.verdict.type.name, (v) => v + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  JsonMap toJson() => {
    'runId': run.manifest.runId,
    'runDir': run.runDir,
    'suite': run.suite.name,
    'episodes': run.records.length,
    'byVerdict': byVerdict,
    'metricProviders': run.metrics.providers,
    'judge': ?judge?.toJson(),
    'aggregates': [
      for (final row in run.aggregates)
        if (row.isAggregateRow) aggregateRowJson(row),
    ],
    'verdicts': [for (final record in run.records) episodeVerdictJson(record)],
    'written': written,
    'reusedVerdicts': run.reusedVerdicts,
    if (run.warnings.isNotEmpty || judgeWarnings.isNotEmpty) 'warnings': [...run.warnings, ...judgeWarnings],
  };
}

final class FieldEvaluation {
  const FieldEvaluation({required this.traceDir, required this.rows, required this.outPath, this.unreadable = const []});

  final String traceDir;
  final int rows;
  final String outPath;
  final List<String> unreadable;
}

final class ReportOutcome {
  const ReportOutcome({required this.run, required this.written, required this.markdown});

  final EvaluatedRun run;
  final List<String> written;

  /// The Markdown report, whether or not `md` was among the formats.
  final String markdown;

  JsonMap toJson() => {'runId': run.manifest.runId, 'written': written, 'markdown': markdown, if (run.warnings.isNotEmpty) 'warnings': run.warnings};
}

final class CalibrationOutcome {
  const CalibrationOutcome({required this.markdown, required this.json, required this.written, this.missing = const []});

  final String markdown;
  final JsonMap json;
  final List<String> written;

  /// Labels naming an episode or criterion the judge did not vote on.
  final List<String> missing;
}

final class LabelSheetOutcome {
  const LabelSheetOutcome({required this.sample, required this.population, required this.outDir, this.warnings = const []});

  final List<LabelItem> sample;
  final int population;
  final String outDir;
  final List<String> warnings;

  int get criteria => sample.fold<int>(0, (sum, item) => sum + item.rubrics.fold(0, (s, r) => s + r.rubric.criteria.length));
}

/// `compare` over two runs or over a sweep of three or more.
sealed class ComparisonOutcome {
  const ComparisonOutcome({required this.runs, required this.markdown});

  final List<EvaluatedRun> runs;
  final String markdown;

  JsonMap toJson();
}

final class PairComparison extends ComparisonOutcome {
  const PairComparison({
    required super.runs,
    required super.markdown,
    required this.differences,
    required this.vary,
    required this.rows,
    this.pairedAgents,
  });

  final List<ManifestDifference> differences;
  final List<String> vary;
  final List<ComparisonRow> rows;
  final (String, String)? pairedAgents;

  int get significant => rows.where((r) => r.significant).length;

  @override
  JsonMap toJson() => {
    'a': runs[0].label,
    'b': runs[1].label,
    'differences': [for (final d in differences) differenceJson(d, intended: vary.any((pattern) => pathMatches(d.path, pattern)))],
    if (pairedAgents case (final a, final b)) 'pairedAgents': [a, b],
    // Suite and tag rows, and the per-task rows whose CI excludes 0: the
    // rest is the Markdown table.
    'rows': [
      for (final row in rows)
        if (row.taskId == '*' || row.taskId.startsWith(AggregateRow.tagPrefix) || row.significant) comparisonRowJson(row),
    ],
    'comparisons': rows.length,
    'significant': significant,
  };
}

final class SweepComparison extends ComparisonOutcome {
  const SweepComparison({required super.runs, required super.markdown, required this.points, required this.html, this.differences = const {}});

  final List<RunPoint> points;
  final String html;

  /// Differences beyond `vary`, allowed through by `allowAnyDiff`.
  final Map<String, List<ManifestDifference>> differences;

  @override
  JsonMap toJson() => {
    'baseline': points.first.label,
    'points': [
      for (final point in points)
        {
          'label': point.label,
          'episodes': point.episodes,
          'metrics': {for (final entry in point.metrics.entries) entry.key: finite(entry.value)},
          if (point.nominallyPriced.isNotEmpty) 'nominallyPriced': point.nominallyPriced.toList(),
        },
    ],
    if (differences.isNotEmpty)
      'differences': {
        for (final entry in differences.entries) entry.key: [for (final d in entry.value) differenceJson(d, intended: false)],
      },
  };
}

/// One routed arm's numbers beyond what [RouteReport] holds.
final class RoutedArmExtras {
  const RoutedArmExtras({this.deciderCostUsd, this.stability});

  final double? deciderCostUsd;

  /// Share of tasks every repetition routed the same way.
  final double? stability;
}

final class RouteOutcome {
  const RouteOutcome({required this.report, required this.extras});

  final RouteReport report;
  final Map<String, RoutedArmExtras> extras;

  JsonMap toJson() {
    final oracle = report.oracle;
    final languages = ({...report.languages.values}.toList()..sort());
    Iterable<String> tasksIn(String language) => [
      for (final task in oracle.tasks)
        if (report.languages[task] == language) task,
    ];
    JsonMap arm(ArmSummary a) => {
      'label': a.label,
      'score': finite(a.score),
      'costUsd': finite(a.costUsd),
      'localShare': finite(a.localShare),
      'tasks': a.tasks,
    };
    return {
      'tasks': oracle.tasks.length,
      'decisiveTasks': oracle.decisiveTasks,
      'oracle': {'score': finite(oracle.score), 'costUsd': finite(oracle.costUsd), 'localShare': finite(oracle.localShare)},
      'references': [arm(oracle.localArm), arm(oracle.cloudArm)],
      'arms': [
        for (final routed in report.arms)
          {
            'label': routed.label,
            'decider': routed.decider,
            'tasks': routed.tasks.length,
            'score': finite(routed.score),
            'costUsd': finite(routed.costUsd),
            'localShare': finite(routed.localShare),
            'accuracy': finite(routed.accuracy),
            'agreement': finite(routed.agreement),
            'regret': finite(routed.regret),
            'costSaved': finite(routed.costSaved),
            'deciderCostUsd': finite(extras[routed.label]?.deciderCostUsd),
            'stability': finite(extras[routed.label]?.stability),
            if (languages.isNotEmpty)
              'byLanguage': {
                for (final language in languages)
                  language: {
                    'accuracy': finite(routed.accuracyOver(tasksIn(language))),
                    'score': finite(routed.scoreOver(tasksIn(language))),
                    'localShare': finite(routed.localShareOver(tasksIn(language))),
                  },
              },
          },
      ],
      if (languages.isNotEmpty) 'languages': {for (final language in languages) language: tasksIn(language).length},
    };
  }
}

final class SelftestOutcome {
  const SelftestOutcome({required this.checks, required this.requireReferences, this.warnings = const []});

  final List<OracleCheck> checks;
  final bool requireReferences;
  final List<String> warnings;

  bool failed(OracleCheck check) => check.problems.isNotEmpty || (!check.hasReference && requireReferences);

  int get failures => checks.where(failed).length;
  int get unreferenced => checks.where((c) => !c.hasReference).length;

  JsonMap toJson() => {
    'tasks': checks.length,
    'failures': failures,
    'unreferenced': unreferenced,
    if (warnings.isNotEmpty) 'warnings': warnings,
    'checks': [
      for (final check in checks)
        {
          'task': check.task.id,
          'ok': !failed(check),
          'scores': {for (final probe in check.probes) probe.name: probe.verdict.score},
          if (check.problems.isNotEmpty) 'problems': check.problems,
          if (check.warnings.isNotEmpty) 'warnings': check.warnings,
        },
    ],
  };
}

final class MetricInfo {
  const MetricInfo({required this.name, required this.unit, required this.source, required this.description});

  final String name;
  final String unit;

  /// `builtin`, or the `--metrics` provider that adds it.
  final String source;
  final String description;

  JsonMap toJson() => {'name': name, 'unit': unit, 'source': source, 'description': description};
}

final class DoctorReport {
  const DoctorReport(this.checks);

  final List<DoctorCheck> checks;

  bool get failed => checks.any((c) => c.isFail);

  String get markdown => doctorMarkdown(checks);

  JsonMap toJson() => {
    'ok': !failed,
    'checks': [
      for (final check in checks) {'status': check.status.name, 'what': check.what, 'detail': ?check.detail, 'nextStep': ?check.nextStep},
    ],
  };
}

final class ProvenanceOutcome {
  const ProvenanceOutcome({required this.manifest, required this.markdown, this.judge, this.against, this.differences = const []});

  final RunManifest manifest;
  final JudgeProvenance? judge;
  final RunManifest? against;

  /// What differs from [against]; empty without one.
  final List<ManifestDifference> differences;
  final String markdown;

  JsonMap toJson() => {
    'runId': manifest.runId,
    'experiment': comparabilityProjection(manifest, judge: judge),
    if (against != null) 'differences': [for (final d in differences) differenceJson(d)],
    'markdown': markdown,
  };
}

final class CatalogOutcome {
  const CatalogOutcome({required this.entries, required this.findings, required this.promptOnly, required this.markdown});

  final List<CatalogEntry> entries;
  final List<CatalogFinding> findings;

  /// Intents the prompt names that the listing does not have.
  final List<String> promptOnly;
  final String markdown;

  int get blocking => findings.where((f) => f.isError).length + promptOnly.length;
}

final class IntentsOutcome {
  const IntentsOutcome({required this.rows, required this.episodes, required this.markdown});

  final List<IntentHealthRow> rows;
  final int episodes;
  final String markdown;
}

/// The last path segment of a run directory.
String runLabel(String runDir) => runDir.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty && s != '.').lastOrNull ?? runDir;

/// JSON has no NaN or infinity; an undefined mean is null.
double? finite(num? value) => value == null || !value.isFinite ? null : value.toDouble();

JsonMap aggregateRowJson(AggregateRow row) => {
  'agentId': row.agentId,
  'taskId': row.taskId,
  'metric': row.metric,
  'n': row.n,
  'mean': finite(row.mean),
  'median': finite(row.median),
  'p95': finite(row.p95),
  if (row.ciLow != null) 'ci': [finite(row.ciLow), finite(row.ciHigh)],
};

JsonMap comparisonRowJson(ComparisonRow row) => {
  'agentId': row.agentId,
  'taskId': row.taskId,
  'metric': row.metric,
  'nA': row.nA,
  'nB': row.nB,
  'meanA': finite(row.meanA),
  'meanB': finite(row.meanB),
  'diff': finite(row.diff),
  'ci': [finite(row.ciLow), finite(row.ciHigh)],
  'significant': row.significant,
  'pairedTasks': ?row.pairedTasks,
};

JsonMap differenceJson(ManifestDifference d, {bool? intended}) => {'path': d.path, 'a': d.a, 'b': d.b, 'intended': ?intended};

JsonMap episodeVerdictJson(EpisodeRecord record) => {
  'episodeId': record.episodeId,
  'taskId': record.taskId,
  'agentId': record.agentId,
  'repetition': record.repetition,
  'verdict': record.verdict.type.name,
  'score': finite(record.verdict.score),
  'reason': ?record.verdict.reason,
};
