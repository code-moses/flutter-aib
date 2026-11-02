import 'dart:io';

import 'package:aib_agents/aib_agents.dart' show CassetteMode;
import 'package:aib_core/aib_core.dart' show RegressionGate, RepetitionOrder, ReporterRegistry;
import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import 'builtins.dart';
import 'service/aib_service.dart';
import 'service/results.dart';

CommandRunner<int> buildRunner() =>
    CommandRunner<int>(
        'aib',
        'AI Interaction Benchmark — run, evaluate and report benchmarks '
            '(execution and evaluation are separate passes, see ADR 0003).',
      )
      ..addCommand(ValidateCommand())
      ..addCommand(RunCommand())
      ..addCommand(EvaluateCommand())
      ..addCommand(ReportCommand())
      ..addCommand(CompareCommand())
      ..addCommand(GateCommand())
      ..addCommand(RouteCommand())
      ..addCommand(CalibrateCommand())
      ..addCommand(LabelSheetCommand())
      ..addCommand(SelftestCommand())
      ..addCommand(MetricsCommand())
      ..addCommand(IntentsCommand())
      ..addCommand(CatalogCommand())
      ..addCommand(ProvenanceCommand())
      ..addCommand(DoctorCommand());

/// A command that prints what [AibService] returns. Refusals become an exit
/// code and a message on stderr; a malformed request a [UsageException].
abstract base class AibCommand extends Command<int> {
  AibService get service => const AibService();

  ArgResults get args => argResults!;

  Future<int> execute();

  @override
  Future<int> run() async {
    try {
      return await execute();
    } on AibError catch (e) {
      if (e.isUsage) throw UsageException(e.message, '');
      stderr.writeln(e.message);
      return e.exitCode;
    }
  }

  void warn(Iterable<String> warnings) {
    for (final warning in warnings) {
      stderr.writeln('WARN $warning');
    }
  }

  /// Warnings and notes of an evaluated run, as `evaluate` printed them.
  void reportRun(EvaluatedRun run) {
    warn(run.warnings);
    run.notes.forEach(stderr.writeln);
  }

  /// Prints [markdown], or writes it to `<--out>/<fileName>`.
  void printOrWrite(String markdown, String fileName) {
    final out = args['out'] as String?;
    if (out == null) {
      stdout.write(markdown);
    } else {
      File(p.join(out, fileName)).writeAsStringSync(markdown);
      stdout.writeln('Wrote ${p.join(out, fileName)}.');
    }
  }
}

/// `aib validate --suite suites/todo_v1.yaml`
final class ValidateCommand extends AibCommand {
  ValidateCommand() {
    argParser.addOption('suite', mandatory: true, help: 'Suite YAML file.');
  }

  @override
  String get name => 'validate';
  @override
  String get description => 'Schema check of a declarative task suite.';

  @override
  Future<int> execute() async {
    final result = service.validateSuite(args['suite'] as String);
    for (final warning in result.warnings) {
      stdout.writeln('WARN  $warning');
    }
    if (!result.isValid) {
      for (final error in result.errors) {
        stdout.writeln('ERROR $error');
      }
      stdout.writeln('Suite is INVALID (${result.errors.length} error(s)).');
      return 1;
    }
    final suite = result.suite!;
    stdout.writeln(
      'Suite "${suite.name}" is valid: '
      '${suite.tasks.length} task(s), '
      'default repetitions ${suite.defaultRepetitions}, '
      'hash ${suite.sourceHash!.substring(0, 12)}.',
    );
    return 0;
  }
}

/// `aib run --suite ... --agents scripted=cfg.yaml --env mock --out dir`
final class RunCommand extends AibCommand {
  RunCommand() {
    argParser
      ..addOption('suite', mandatory: true, help: 'Suite YAML file.')
      ..addOption('agents', mandatory: true, help: 'Comma-separated agent specs (name or name=configFile).')
      ..addOption('env', defaultsTo: 'mock', help: 'Environment spec (name or name=configFile).')
      ..addOption('reps', help: 'Override suite repetitions.')
      ..addOption('seed', defaultsTo: '42', help: 'Task shuffle seed.')
      ..addOption(
        'repetition-order',
        allowed: [for (final order in RepetitionOrder.values) order.name],
        defaultsTo: RepetitionOrder.interleaved.name,
        help: 'interleaved: repetition 1 of every task, then 2, … (honest latency); blocked: a task\'s repetitions back to back.',
      )
      ..addOption('out', mandatory: true, help: 'Output run directory.')
      ..addOption(
        'pricing',
        help:
            'Price table (YAML/JSON) for cost_usd. Pinned into the run '
            'manifest, since prices are volatile (spec 6.3).',
      )
      ..addOption(
        'fault-rate',
        help:
            'Share of app envelopes that fail transiently (G2). Recorded in '
            'the manifest; 0 or absent injects nothing.',
      )
      ..addOption('fault-seed', defaultsTo: '1', help: 'Seed of --fault-rate.')
      ..addOption('shuffle-catalog', help: 'Seed for reordering the intents.catalog listing (G3).')
      ..addOption('simulator', help: 'Config of the simulated user, for tasks declaring one (I2).')
      ..addOption(
        'cassette',
        allowed: [for (final mode in CassetteMode.values) mode.name],
        help:
            'Record the LLM calls (record), answer them from a recording (replay), '
            'or replay until the conversation leaves it and go live from there (replayThenLive).',
      )
      ..addOption('cassette-path', help: 'Cassette file; default <out>/llm/cassette.jsonl.')
      ..addOption('otel', help: 'OTLP/HTTP traces endpoint; episodes are exported as spans.')
      ..addFlag('otel-capture-content', negatable: false, help: 'Put envelope and result payloads on the spans.')
      ..addFlag(
        'force',
        negatable: false,
        help:
            'Re-execute every episode instead of resuming. By default an '
            'existing run directory is resumed: complete episodes are '
            'reused, framework faults and missing episodes re-executed.',
      );
  }

  @override
  String get name => 'run';
  @override
  String get description => 'Execute a benchmark run; writes run_manifest.json and traces/*.jsonl.';

  @override
  Future<int> execute() async {
    final outcome = await service.run(
      suite: args['suite'] as String,
      agents: (args['agents'] as String).split(','),
      env: args['env'] as String,
      outDir: args['out'] as String,
      reps: args['reps'] == null ? null : int.parse(args['reps'] as String),
      seed: int.parse(args['seed'] as String),
      repetitionOrder: RepetitionOrder.values.byName(args['repetition-order'] as String),
      pricing: args['pricing'] as String?,
      faultRate: double.tryParse(args['fault-rate'] as String? ?? ''),
      faultSeed: int.parse(args['fault-seed'] as String),
      shuffleCatalog: args['shuffle-catalog'] == null ? null : int.parse(args['shuffle-catalog'] as String),
      simulator: args['simulator'] as String?,
      otel: args['otel'] as String?,
      cassette: args['cassette'] == null ? null : CassetteMode.values.byName(args['cassette'] as String),
      cassettePath: args['cassette-path'] as String?,
      otelCaptureContent: args['otel-capture-content'] as bool,
      force: args['force'] as bool,
      onStart: (suite, agents) => stdout.writeln(
        'Running suite "${suite.name}" '
        '(${suite.tasks.length} tasks × $agents agent(s))…',
      ),
      onEpisode: (meta, result) => stdout.writeln('  ${meta.episodeId}: ${result.outcome.reason.name}'),
      onSkipped: (meta, endReason) => stdout.writeln('  ${meta.episodeId}: reused ($endReason)'),
    );
    stdout.writeln(
      'Run ${outcome.manifest.runId} written to ${outcome.outDir} '
      '(${outcome.executed} executed, ${outcome.skipped} reused).',
    );
    stdout.writeln('Next: aib evaluate --run ${outcome.outDir}');
    return 0;
  }
}

void _addJudgeKOption(ArgParser parser) => parser.addOption(
  'judge-k',
  defaultsTo: '${ScoringOptions.defaultJudgeK}',
  help:
      'Judge calls per rubric, majority per criterion. At temperature 0 the '
      'votes are near identical; use k>1 with a judge temperature above 0.',
);

void _addJudgeCassetteOption(ArgParser parser) => parser.addOption(
  'judge-cassette',
  help:
      'Answer the judge from this cassette while it holds the call and record '
      'to it otherwise: re-scoring with the same judge is then free and '
      'reproducible.',
);

void _addMetricsOption(ArgParser parser) => parser
  ..addOption(
    'metrics',
    help:
        'Metric providers to add, comma-separated '
        '(${Builtins.metricProviders().names.join(', ')}).',
  )
  ..addFlag(
    'conventions',
    defaultsTo: true,
    help:
        'Score with the intent/user bridge conventions (the "intents" '
        'provider: clarifications, effects, catalog bytes, everIntent and '
        'confirmBefore policies). The core itself names no app key.',
  );

/// The scoring options every command that scores a run shares.
ScoringOptions _scoring(ArgResults args) {
  String? option(String name) => args.options.contains(name) ? args[name] as String? : null;
  final k = int.tryParse(option('judge-k') ?? '') ?? ScoringOptions.defaultJudgeK;
  if (k < 1) throw UsageException('--judge-k must be at least 1', '');
  return ScoringOptions(
    judge: option('judge'),
    suite: option('suite'),
    metrics: (option('metrics') ?? '').split(','),
    conventions: !args.options.contains('conventions') || args['conventions'] as bool,
    judgeK: k,
    judgeCassette: option('judge-cassette'),
  );
}

/// `aib evaluate --run results/...` — (re-)evaluation of persisted traces.
final class EvaluateCommand extends AibCommand {
  EvaluateCommand() {
    argParser
      ..addOption('run', mandatory: true, help: 'Run directory.')
      ..addOption(
        'judge',
        help:
            'LLM judge config (YAML: provider/model/…) for '
            'artifactRubric criteria.',
      )
      ..addOption(
        'suite',
        help:
            'Suite file, if the path recorded in the manifest no longer '
            'resolves from here.',
      )
      ..addFlag(
        'allow-missing-judge',
        negatable: false,
        help:
            'Score a suite with artifactRubric criteria without a judge; '
            'every rubric criterion counts as 0 and verdicts.json is '
            'overwritten.',
      )
      ..addFlag(
        'field',
        negatable: false,
        help:
            'Traces from a shipped assistant: --run is a directory of *.jsonl '
            'with no manifest or suite. Writes field_metrics.csv; verdict and '
            'ground-truth metrics stay blank.',
      )
      ..addOption('pricing', help: 'Price table for --field, whose traces pin none (adds cost_usd).');
    _addMetricsOption(argParser);
    _addJudgeKOption(argParser);
    _addJudgeCassetteOption(argParser);
  }

  @override
  String get name => 'evaluate';
  @override
  String get description => '(Re-)evaluate the traces of a run: writes verdicts.json + metrics.csv.';

  @override
  Future<int> execute() async {
    final runDir = args['run'] as String;
    if (args['field'] as bool) {
      final field = service.evaluateField(runDir, options: _scoring(args), pricing: args['pricing'] as String?);
      if (field.unreadable.isNotEmpty) {
        warn([
          '${field.unreadable.length} file(s) are not traces: '
              '${field.unreadable.take(3).join(', ')}${field.unreadable.length > 3 ? ', …' : ''}',
        ]);
      }
      stdout.writeln(
        '${field.rows} field trace(s) scored without a suite: success, score '
        'and every ground-truth metric are blank, not zero.',
      );
      stdout.writeln('Wrote ${field.outPath}.');
      return 0;
    }
    final summary = await service.evaluate(
      runDir,
      options: _scoring(args),
      withoutJudge: args['allow-missing-judge'] as bool ? WithoutJudge.scoreAsZero : WithoutJudge.refuse,
    );
    reportRun(summary.run);
    final spend = summary.spend;
    if (!spend.isEmpty) {
      stdout.writeln(
        'Judge spend: ${spend.calls} call(s), '
        '${spend.tokensPrompt + spend.tokensCompletion} tokens, '
        '${(spend.latencyMs / 1000).toStringAsFixed(1)}s.',
      );
    }
    stdout.writeln('${summary.run.records.length} episode(s) evaluated: ${summary.byVerdict}');
    if (summary.judge case final judge?) {
      stdout.writeln('Judge: ${judge.judgeId} (k=${judge.k}).');
    }
    for (final warning in summary.judgeWarnings) {
      stdout.writeln('WARN $warning');
    }
    stdout.writeln('Wrote ${summary.written.join(' and ')}.');
    return 0;
  }
}

/// `aib report --run results/... --format md,csv,json`
final class ReportCommand extends AibCommand {
  ReportCommand() {
    argParser
      ..addOption('run', mandatory: true, help: 'Run directory.')
      ..addOption(
        'judge',
        help:
            'LLM judge config to re-score with. Without it the verdicts in '
            'verdicts.json are used as they are.',
      )
      ..addOption('format', defaultsTo: 'md', help: 'Comma-separated formats: ${ReporterRegistry().formats.join(', ')}.')
      ..addOption(
        'suite',
        help:
            'Suite file, if the path recorded in the manifest no longer '
            'resolves from here.',
      );
    _addMetricsOption(argParser);
  }

  @override
  String get name => 'report';
  @override
  String get description => 'Render reports from an evaluated run.';

  @override
  Future<int> execute() async {
    final outcome = await service.report(args['run'] as String, formats: (args['format'] as String).split(','), options: _scoring(args));
    reportRun(outcome.run);
    for (final path in outcome.written) {
      stdout.writeln('Wrote $path.');
    }
    return 0;
  }
}

/// `aib calibrate --run results/A --labels labels.csv [--judge cfg.yaml]`
///
/// How far the automatic verdicts agree with a human on a labelled sample
/// (§5.2).
final class CalibrateCommand extends AibCommand {
  CalibrateCommand() {
    argParser
      ..addMultiOption(
        'run',
        help:
            'Run directory. Repeat to pool several runs judged by the same '
            'judge; labels then name episodes as <run dir name>/<episode id>, '
            'the ids `aib labelsheet` writes.',
      )
      ..addOption(
        'labels',
        mandatory: true,
        help:
            'CSV with "episodeId,label" per line '
            '(success/failure, 1/0, true/false; header optional).',
      )
      ..addOption(
        'judge',
        help:
            'LLM judge config — required if the run contains '
            'artifactRubric criteria.',
      )
      ..addOption(
        'suite',
        help:
            'Suite file, if the path recorded in the manifests no longer '
            'resolves from here.',
      )
      ..addOption(
        'out',
        help:
            'Write calibration.md + calibration.json here '
            '(default: the run directory; required with several runs).',
      );
    _addMetricsOption(argParser);
    _addJudgeKOption(argParser);
    _addJudgeCassetteOption(argParser);
  }

  @override
  String get name => 'calibrate';
  @override
  String get description =>
      'Compare the automatic verdicts of a run against manual labels: '
      "Cohen's κ, F1, confusion matrix, judge stability (spec 5.2).";

  @override
  Future<int> execute() async {
    final outcome = await service.calibrate(
      args['run'] as List<String>,
      labels: args['labels'] as String,
      options: _scoring(args),
      out: args['out'] as String?,
    );
    stdout.write(outcome.markdown);
    stdout.writeln('\nWrote ${outcome.written.join(' and ')}.');
    final missing = outcome.missing;
    if (missing.isNotEmpty) {
      warn([
        '${missing.length} label(s) name an episode or criterion the '
            'judge did not vote on: ${missing.take(3).join(', ')}'
            '${missing.length > 3 ? ', …' : ''}',
      ]);
    }
    return 0;
  }
}

/// `aib labelsheet --run A --run B --sample 40 --out dir`
final class LabelSheetCommand extends AibCommand {
  LabelSheetCommand() {
    argParser
      ..addMultiOption('run', help: 'Run directory whose judged episodes to sample (repeatable).')
      ..addOption(
        'suite',
        help:
            'Suite file, if the path recorded in the manifests no longer '
            'resolves from here.',
      )
      ..addOption('sample', help: 'Episodes to sample (default: every judged episode).')
      ..addOption('seed', defaultsTo: '42', help: 'Sampling seed.')
      ..addOption('out', mandatory: true, help: 'Writes labels.md, labels.csv and sample.json here.');
  }

  @override
  String get name => 'labelsheet';
  @override
  String get description =>
      'Build the manual-labelling sheet for `aib calibrate` from the '
      'episodes a rubric judge voted on (spec 5.2, ADR 0008).';

  @override
  Future<int> execute() async {
    final outcome = service.labelSheet(
      args['run'] as List<String>,
      out: args['out'] as String,
      suite: args['suite'] as String?,
      sample: int.tryParse(args['sample'] as String? ?? ''),
      seed: int.parse(args['seed'] as String),
    );
    warn(outcome.warnings);
    stdout.writeln(
      'Sampled ${outcome.sample.length} of ${outcome.population} judged episodes '
      '(${outcome.criteria} criteria) into ${outcome.outDir}: labels.md, labels.csv, '
      'sample.json.',
    );
    return 0;
  }
}

/// `aib gate --baseline results/A --run results/B [--tolerance 0.2]`
///
/// Exits 1 when the run regressed against the baseline: a task newly
/// failing, a score drop beyond the tolerance, a task turned flaky
/// (`RegressionGate`). For CI, next to `aib report --format junit`.
final class GateCommand extends AibCommand {
  GateCommand() {
    argParser
      ..addOption('baseline', mandatory: true, help: 'The run to hold the candidate to.')
      ..addOption('run', mandatory: true, help: 'The candidate run.')
      ..addOption('tolerance', defaultsTo: '0.2', help: 'Largest drop in a task\'s mean score that is not a regression.')
      ..addOption('judge', help: 'LLM judge config to re-score both runs with; without it each run\'s verdicts.json is used.')
      ..addOption('suite', help: 'Suite file to score both runs against, overriding the path their manifests recorded.');
    _addMetricsOption(argParser);
    _addJudgeKOption(argParser);
    _addJudgeCassetteOption(argParser);
  }

  @override
  String get name => 'gate';
  @override
  String get description => 'Exit non-zero when a run regressed against a baseline (newly failing, score drop, turned flaky).';

  @override
  Future<int> execute() async {
    final tolerance = double.tryParse(args['tolerance'] as String);
    if (tolerance == null || tolerance < 0) throw UsageException('--tolerance must be a number of at least 0', '');
    final baseline = await service.evaluateRun(args['baseline'] as String, options: _scoring(args));
    final candidate = await service.evaluateRun(args['run'] as String, options: _scoring(args));
    reportRun(baseline);
    reportRun(candidate);
    final result = RegressionGate(tolerance: tolerance).check(baseline.records, candidate.records);
    for (final task in result.unmatched) {
      stderr.writeln('WARN $task is in only one of the two runs; not gated');
    }
    if (result.passed) {
      stdout.writeln('gate passed: no regression against ${args['baseline']}');
      return 0;
    }
    stdout.writeln('gate failed: ${result.regressions.length} regression(s) against ${args['baseline']}');
    for (final regression in result.regressions) {
      stdout.writeln('  $regression');
    }
    return 1;
  }
}

/// `aib compare --runs results/A,results/B [--out dir]`
final class CompareCommand extends AibCommand {
  CompareCommand() {
    argParser
      ..addMultiOption(
        'runs',
        help:
            'Two run directories for a comparison, or more for a sweep '
            '(repeat or comma-separate).',
      )
      ..addOption(
        'judge',
        help:
            'LLM judge config to re-score both runs with. Without it each '
            'run\'s verdicts.json is used.',
      )
      ..addOption('out', help: 'Write comparison.md to this directory.')
      // A run produced inside an application records the suite path that
      // application saw, unreadable from here, so compare takes the override
      // evaluate and report take.
      ..addOption(
        'suite',
        help:
            'Suite file to score both runs against, overriding the path their '
            'manifests recorded.',
      )
      ..addMultiOption(
        'vary',
        help:
            'Manifest fields allowed to differ, as dotted-path globs '
            '(`agents.*.metadata.model`, or just `model`). Any other '
            'difference refuses the comparison.',
      )
      ..addFlag('allow-any-diff', negatable: false, help: 'Compare whatever differs; the differences are still listed.');
    _addMetricsOption(argParser);
    _addJudgeKOption(argParser);
    _addJudgeCassetteOption(argParser);
  }

  @override
  String get name => 'compare';
  @override
  String get description =>
      'Compare two runs (mean deltas with 95% bootstrap CIs, spec 6.5), '
      'or rank three or more on a cost-accuracy frontier.';

  @override
  Future<int> execute() async {
    final outcome = await service.compare(
      args['runs'] as List<String>,
      options: _scoring(args),
      vary: args['vary'] as List<String>,
      allowAnyDiff: args['allow-any-diff'] as bool,
    );
    outcome.runs.forEach(reportRun);
    final out = args['out'] as String?;
    switch (outcome) {
      case SweepComparison(:final markdown, :final html):
        if (out == null) {
          stdout.write(markdown);
        } else {
          Directory(out).createSync(recursive: true);
          File(p.join(out, 'sweep.md')).writeAsStringSync(markdown);
          File(p.join(out, 'sweep.html')).writeAsStringSync(html);
          stdout.writeln('Wrote ${p.join(out, 'sweep.md')} and sweep.html.');
        }
      case PairComparison(:final markdown, :final rows, :final significant):
        if (out != null) {
          Directory(out).createSync(recursive: true);
          File(p.join(out, 'comparison.md')).writeAsStringSync(markdown);
          stdout.writeln('Wrote ${p.join(out, 'comparison.md')}.');
        } else {
          stdout.write(markdown);
        }
        stdout.writeln('\n${rows.length} comparison(s), $significant with a 95% CI excluding 0.');
    }
    return 0;
  }
}

/// `aib route --local A --cloud B --routed C [--routed D]`
final class RouteCommand extends AibCommand {
  RouteCommand() {
    argParser
      ..addOption('local', help: 'Run directory of the always-local reference arm.')
      ..addOption('cloud', help: 'Run directory of the always-cloud reference arm.')
      ..addMultiOption(
        'routed',
        help:
            'Run directory of a routed arm (repeat for several deciders). '
            'Without any, only the oracle ceiling is reported.',
      )
      ..addOption('judge', help: 'LLM judge config to score every run with.')
      ..addOption('suite', help: 'Suite file to score every run against (see `compare`).')
      ..addOption('out', help: 'Write routing.md to this directory.');
    _addMetricsOption(argParser);
    _addJudgeKOption(argParser);
    _addJudgeCassetteOption(argParser);
  }

  @override
  String get name => 'route';
  @override
  String get description =>
      'Score model-routing deciders against the per-task oracle built from '
      'an always-local and an always-cloud run (docs/overview.md).';

  @override
  Future<int> execute() async {
    final localDir = args['local'] as String?;
    final cloudDir = args['cloud'] as String?;
    if (localDir == null || cloudDir == null) {
      throw UsageException('route needs both reference arms: --local and --cloud', usage);
    }
    final outcome = await service.route(local: localDir, cloud: cloudDir, routed: args['routed'] as List<String>, options: _scoring(args));
    final markdown = outcome.report.toMarkdown();
    stdout.write(markdown);
    for (final arm in outcome.report.arms) {
      final extras = outcome.extras[arm.label]!;
      final decider = extras.deciderCostUsd;
      final stability = extras.stability;
      stdout.writeln(
        '- ${arm.label}: decider cost/episode '
        '${decider == null ? '—' : '\$${decider.toStringAsFixed(5)}'}'
        '${stability == null ? '' : ', route stability ${(stability * 100).toStringAsFixed(0)}%'}'
        '${arm.costSaved == null ? '' : ', cloud spend saved ${(arm.costSaved! * 100).toStringAsFixed(1)}%'}',
      );
    }
    if ((args['out'] as String?) case final outDir?) {
      final file = File(p.join(outDir, 'routing.md'));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(markdown);
      stdout.writeln('written to ${file.path}');
    }
    return 0;
  }
}

/// `aib selftest --suite S --reference scripts/x.yaml [--env mock] [--judge cfg]`
final class SelftestCommand extends AibCommand {
  SelftestCommand() {
    argParser
      ..addOption('suite', mandatory: true, help: 'Suite YAML file.')
      ..addOption('reference', help: 'Reference trajectories per task (ScriptedAgent config format).')
      ..addOption('env', defaultsTo: 'mock', help: 'Environment spec (name or name=configFile).')
      ..addOption('judge', help: 'LLM judge config, for suites with artifactRubric criteria.')
      ..addOption('tasks', help: 'Comma-separated task ids (default: all).')
      ..addFlag('require-references', negatable: false, help: 'Fail when a task has no reference trajectory.');
  }

  @override
  String get name => 'selftest';
  @override
  String get description => "Check the oracles: each task's reference must pass, stopping at once must not.";

  @override
  Future<int> execute() async {
    final outcome = await service.selftest(
      suite: args['suite'] as String,
      reference: args['reference'] as String?,
      env: args['env'] as String,
      judge: args['judge'] as String?,
      tasks: (args['tasks'] as String?)?.split(','),
      requireReferences: args['require-references'] as bool,
    );
    warn(outcome.warnings);
    for (final check in outcome.checks) {
      String score(String probe) => check.probe(probe)?.verdict.score.toStringAsFixed(2) ?? '—';
      stdout.writeln(
        '${outcome.failed(check) ? 'FAIL' : 'ok  '}  ${check.task.id}  '
        'reference ${check.hasReference ? score('reference') : 'none'} · '
        'done ${score('null.done')} · abort ${score('null.abort')}',
      );
      for (final problem in check.problems) {
        stdout.writeln('        $problem');
      }
      for (final warning in check.warnings) {
        stdout.writeln('        warn: $warning');
      }
    }
    stdout.writeln('${outcome.checks.length} task(s), ${outcome.failures} failing, ${outcome.unreferenced} without a reference.');
    return outcome.failures == 0 ? 0 : 1;
  }
}

/// `aib metrics` — the metric catalogue as a Markdown table.
final class MetricsCommand extends AibCommand {
  @override
  String get name => 'metrics';
  @override
  String get description => 'List every metric: builtin, and per provider.';

  @override
  Future<int> execute() async {
    stdout
      ..writeln('| metric | unit | source | description |')
      ..writeln('|---|---|---|---|');
    for (final metric in service.metrics()) {
      stdout.writeln('| `${metric.name}` | ${metric.unit} | ${metric.source} | ${metric.description.replaceAll('|', '\\|')} |');
    }
    return 0;
  }
}

/// `aib doctor` — the preflight a 17-minute run deserves.
final class DoctorCommand extends AibCommand {
  DoctorCommand() {
    argParser
      ..addOption('suite', help: 'Suite file; checked for loading and for the files it names.')
      ..addOption('judge', help: 'Judge config.')
      ..addOption('simulator', help: 'Simulated-user config.')
      ..addMultiOption('agents', help: 'Agent specs, name or name=configFile.');
  }

  @override
  String get name => 'doctor';
  @override
  String get description => 'Check that a run can start before it spends the time.';

  @override
  Future<int> execute() async {
    final report = await service.doctor(
      suite: args['suite'] as String?,
      judge: args['judge'] as String?,
      simulator: args['simulator'] as String?,
      agents: args['agents'] as List<String>,
    );
    stdout.write(report.markdown);
    return report.failed ? 1 : 0;
  }
}

/// `aib provenance --run results/X` — the identity table that heads a RUN.md.
final class ProvenanceCommand extends AibCommand {
  ProvenanceCommand() {
    argParser
      ..addOption('run', mandatory: true, help: 'Run directory.')
      ..addOption('against', help: 'A second run; also lists what moved between them.')
      ..addOption('out', help: 'Write provenance.md here instead of stdout.');
  }

  @override
  String get name => 'provenance';
  @override
  String get description => "What a run was, in the fields that decide whether another compares with it.";

  @override
  Future<int> execute() async {
    printOrWrite(service.provenance(args['run'] as String, against: args['against'] as String?).markdown, 'provenance.md');
    return 0;
  }
}

/// `aib catalog lint --run results/X`: what the listing itself gets wrong.
/// Reads the catalogue out of a recorded run, so it needs no app process.
final class CatalogCommand extends AibCommand {
  CatalogCommand() {
    argParser
      ..addOption('run', mandatory: true, help: 'Run directory.')
      ..addOption('prompt', help: 'Prompt file; checks that every intent it names exists.')
      ..addOption('out', help: 'Write catalog.md here instead of stdout.')
      ..addFlag('strict', help: 'Exit non-zero on any finding, not only the ones that break a request.');
  }

  @override
  String get name => 'catalog';
  @override
  String get description => 'Lint the intent listing a run was shown.';

  @override
  Future<int> execute() async {
    final outcome = service.lintCatalog(args['run'] as String, prompt: args['prompt'] as String?);
    printOrWrite(outcome.markdown, 'catalog.md');
    if (outcome.blocking > 0) return 1;
    return args['strict'] as bool && outcome.findings.isNotEmpty ? 1 : 0;
  }
}

/// `aib intents --run results/X` — where the app integration loses turns.
final class IntentsCommand extends AibCommand {
  IntentsCommand() {
    argParser
      ..addOption('run', mandatory: true, help: 'Run directory.')
      ..addOption('out', help: 'Write intents.md here instead of stdout.');
  }

  @override
  String get name => 'intents';
  @override
  String get description => 'Per-intent failure, schema and repetition rates of a run.';

  @override
  Future<int> execute() async {
    printOrWrite(service.intents(args['run'] as String).markdown, 'intents.md');
    return 0;
  }
}
