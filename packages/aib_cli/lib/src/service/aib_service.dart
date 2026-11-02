import 'dart:convert';
import 'dart:io';

import 'package:aib_agents/aib_agents.dart';
import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:aib_otel/aib_otel.dart';
import 'package:path/path.dart' as p;

import '../builtins.dart';
import '../label_sheet.dart';
import 'results.dart';

/// What `aib` does, as typed results. The CLI commands print these; the MCP
/// server returns them as structured tool results.
///
/// Refusals are [AibError]s. Nothing here prints; warnings come back in the
/// result.
final class AibService {
  const AibService();

  /// Assertion kinds the CLI can evaluate beyond the core's own.
  static final Set<String> knownAssertionKinds = {...intentConventions.assertions.keys};

  // Suites and agent configs

  SuiteValidation validateSuite(String path) {
    final result = SuiteLoader.loadFile(path, assertionKinds: knownAssertionKinds);
    return SuiteValidation(path: path, suite: result.suite, errors: result.errors, warnings: result.warnings);
  }

  TaskSuite _loadSuite(String path) {
    final result = validateSuite(path);
    if (!result.isValid) throw AibError('Suite invalid:\n  ${result.errors.join('\n  ')}');
    return result.suite!;
  }

  /// Builds [agent] from a config file ([path]) or an inline [config] without
  /// running it. A config the builder refuses comes back with its `error`,
  /// not as an exception: refusing is the answer to "is this valid".
  AgentConfigCheck validateAgentConfig({required String agent, String? path, JsonMap? config}) {
    if ((path == null) == (config == null)) {
      throw const AibError('pass either a config path or an inline config', isUsage: true);
    }
    final registry = Builtins.agentRegistry();
    if (!registry.contains(agent)) {
      throw AibError('Unknown agent "$agent" (known: ${registry.names.join(', ')})', isUsage: true);
    }
    JsonMap loaded = config ?? const {};
    try {
      loaded = config ?? Builtins.loadConfig(path);
      return AgentConfigCheck(agent: agent, path: path, config: loaded, manifest: registry.create(agent, loaded).manifest);
    } on Object catch (error) {
      return AgentConfigCheck(agent: agent, path: path, config: loaded, error: '$error'.split('\n').first);
    }
  }

  // Running

  /// Executes a benchmark run into [outDir]; resumes it unless [force].
  Future<RunOutcome> run({
    required String suite,
    required List<String> agents,
    required String outDir,
    String env = 'mock',
    int? reps,
    int seed = 42,
    RepetitionOrder repetitionOrder = .interleaved,
    String? pricing,
    double? faultRate,
    int faultSeed = 1,
    int? shuffleCatalog,
    String? simulator,
    String? otel,
    bool otelCaptureContent = false,
    CassetteMode? cassette,
    String? cassettePath,
    bool force = false,
    void Function(TaskSuite suite, int agents)? onStart,
    void Function(EpisodeMeta meta, EpisodeRunResult result)? onEpisode,
    void Function(EpisodeMeta meta, String endReason)? onSkipped,
  }) async {
    final taskSuite = _loadSuite(suite);

    final built = <String, BenchmarkAgent>{};
    final agentRegistry = Builtins.agentRegistry();
    for (final spec in agents) {
      final (name, configPath) = Builtins.parseSpec(spec.trim());
      final config = Builtins.loadConfig(configPath);
      final agent = agentRegistry.create(name, {
        ...config,
        // One file for every agent of the run: a key includes the model and
        // the whole conversation, so two agents never share an answer.
        if (cassette != null) 'cassette': {'path': cassettePath ?? p.join(outDir, 'llm', 'cassette.jsonl'), 'mode': cassette.name},
      });
      final id = agent.manifest.agentId;
      if (built.containsKey(id)) {
        // Episode ids and traces are keyed by agent id: a second agent with
        // the same id silently replaced the first.
        throw AibError(
          'Two agents share the id "$id" ($spec). Run them as separate runs '
          'and compare those.',
          exitCode: 64,
        );
      }
      built[id] = agent;
    }

    final (envName, envConfigPath) = Builtins.parseSpec(env);
    final environment = PerturbedEnvironment.wrap(Builtins.environmentRegistry().create(envName, Builtins.loadConfig(envConfigPath)), [
      if (faultRate != null && faultRate > 0) FaultPerturbation(FaultSchedule(seed: faultSeed, failureRate: faultRate)),
      if (shuffleCatalog != null) CatalogShufflePerturbation(shuffleCatalog),
    ]);

    final userSimulator = simulator == null ? null : LlmUserSimulator(client: LlmClientFactory.fromConfig(Builtins.loadConfig(simulator)));
    final observer = otel == null ? null : await OtelExport.start(otel, captureContent: otelCaptureContent);

    var executed = 0;
    var skipped = 0;
    final runner = BenchmarkRunner(
      suite: taskSuite,
      agents: built,
      environment: environment,
      store: RunStore(Directory(outDir)),
      repetitionsOverride: reps,
      seed: seed,
      repetitionOrder: repetitionOrder,
      resume: !force,
      pricing: pricing == null ? null : PriceTable.fromJson(Builtins.loadConfig(pricing)),
      observer: observer,
      userSimulator: userSimulator,
      onEpisode: (meta, result) {
        executed++;
        onEpisode?.call(meta, result);
      },
      onSkipped: (meta, endReason) {
        skipped++;
        onSkipped?.call(meta, endReason);
      },
    );
    onStart?.call(taskSuite, built.length);
    try {
      final manifest = await runner.run();
      return RunOutcome(manifest: manifest, outDir: outDir, executed: executed, skipped: skipped);
    } on ResumeConflict catch (e) {
      throw AibError('$e');
    } finally {
      if (otel != null) await OtelExport.shutdown();
    }
  }

  // Scoring

  /// Builds the LLM judge for artifactRubric criteria from a config file
  /// (same format as agent configs: provider/model/…). Without a judge those
  /// criteria fail with an instructive message.
  ///
  /// With [cassette], its calls are answered from that file while it holds
  /// them and recorded to it otherwise.
  ArtifactJudge? judgeFrom(String? configPath, {String? cassette}) {
    if (configPath == null) return null;
    final config = {
      ...Builtins.loadConfig(configPath),
      if (cassette != null) 'cassette': {'path': cassette, 'mode': CassetteMode.replayThenLive.name},
    };
    return LlmJudge(
      client: LlmClientFactory.fromConfig(config),
      // `temperature:` at the top of the judge config, or in its `judge:`
      // block; recorded in the provenance either way.
      temperature: ((asJsonMap(config['judge'])['temperature'] ?? config['temperature']) as num?)?.toDouble() ?? 0,
    );
  }

  static double _judgeTemperature(ArtifactJudge? judge) => judge is LlmJudge ? judge.temperature : 0;

  /// The metric providers [options] name, the conventions first.
  List<MetricProvider> providers(ScoringOptions options) {
    final registry = Builtins.metricProviders();
    return [
      if (options.conventions) intentConventions,
      for (final name in options.metrics.map((s) => s.trim()).where((s) => s.isNotEmpty))
        if (name == intentConventions.name && options.conventions)
          ...const <MetricProvider>[]
        else if (registry.contains(name))
          registry.create(name)
        else
          throw AibError('Unknown metric provider "$name" (known: ${registry.names.join(', ')})', isUsage: true),
    ];
  }

  /// Finds the suite a run was executed with: evaluation usually happens from
  /// another working directory than the run. The recorded path is tried first,
  /// then the same path relative to the run directory and its ancestors, and
  /// last the suite's file name under a `suites/` above the run.
  ///
  /// A run an app wrote records a path inside the app's sandbox, which can
  /// exist and refuse to be read, so a candidate counts only when it opens. A
  /// readable sandbox path may hold a later copy, so when several candidates
  /// open, [judgedRubrics] (the run's judge provenance, name → hash) picks the
  /// suite whose rubrics the judge was asked, then [suiteHash] the one the run
  /// was executed with; without a match the first readable candidate stays.
  static String? locateSuite(
    String recordedPath,
    String runDir, {
    String? override,
    String? suiteHash,
    Map<String, String> judgedRubrics = const {},
  }) {
    if (override != null) return _readable(override) ? override : null;
    final ancestors = [for (var dir = p.absolute(runDir); p.dirname(dir) != dir; dir = p.dirname(dir)) dir];
    final candidates = <String>{
      recordedPath,
      for (final dir in ancestors) p.normalize(p.join(dir, recordedPath)),
      for (final dir in ancestors) p.join(dir, 'suites', p.basename(recordedPath)),
    }.where(_readable).toList();
    if (candidates.length < 2 || (suiteHash == null && judgedRubrics.isEmpty)) return candidates.firstOrNull;
    final suites = {for (final path in candidates) path: ?SuiteLoader.loadFile(path, assertionKinds: knownAssertionKinds).suite};
    bool judgedWith(TaskSuite suite) {
      final rubrics = JudgeProvenance.forSuite(suite, judgeId: '', k: 0).rubrics;
      return judgedRubrics.entries.every((e) => rubrics[e.key] == e.value);
    }

    return (judgedRubrics.isEmpty ? null : suites.entries.where((e) => judgedWith(e.value)).firstOrNull?.key) ??
        suites.entries.where((e) => e.value.sourceHash == suiteHash).firstOrNull?.key ??
        candidates.first;
  }

  /// The rubrics the judge answered that [suite] does not carry, or carries
  /// in another wording — questions a label sheet built from it would lack.
  static List<String> rubricsMissingFrom(TaskSuite suite, JudgeProvenance? judge) {
    final rubrics = JudgeProvenance.forSuite(suite, judgeId: '', k: 0).rubrics;
    return [
      for (final MapEntry(:key, :value) in (judge?.rubrics ?? const <String, String>{}).entries)
        if (rubrics[key] != value) key,
    ];
  }

  static bool _readable(String path) {
    try {
      File(path).openSync().closeSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Whether the suite contains criteria that only an LLM judge can score.
  static bool needsJudge(TaskSuite suite) =>
      suite.tasks.expand((task) => task.successCriteria).any((criterion) => criterion.type == CriterionTypes.artifactRubric);

  /// Loads manifest, traces and suite of [runDir] and scores the traces.
  ///
  /// Without a judge, a suite with rubric criteria reuses `verdicts.json`
  /// ([WithoutJudge.reusePersisted]), refuses, or scores rubrics as 0.
  Future<EvaluatedRun> evaluateRun(
    String runDir, {
    ScoringOptions options = const ScoringOptions(),
    WithoutJudge withoutJudge = .reusePersisted,
  }) async {
    if (options.judgeK < 1) throw const AibError('--judge-k must be at least 1', isUsage: true);
    final providers = this.providers(options);
    final judge = judgeFrom(options.judge, cassette: options.judgeCassette);
    final warnings = <String>[];
    final notes = <String>[];
    final store = RunStore(Directory(runDir));
    if (store.readManifestOrNull() == null) {
      throw AibError('$runDir has no ${RunStore.manifestFile}: not a run directory');
    }
    final manifest = store.readManifest();
    final recordedPath = manifest.suitePath;
    if (recordedPath == null) {
      throw AibError('run manifest of $runDir carries no suite path');
    }
    final suitePath = locateSuite(
      recordedPath,
      runDir,
      override: options.suite,
      suiteHash: manifest.suiteHash,
      // Reused verdicts belong to the suite they were judged with; a new
      // judge scores the suite the run was executed with.
      judgedRubrics: judge == null ? store.readJudgeProvenance()?.rubrics ?? const {} : const {},
    );
    if (suitePath == null) {
      throw AibError(
        'suite "$recordedPath" of run ${manifest.runId} not found — it was '
        'recorded relative to the process that ran the benchmark. Pass '
        '--suite <path> to point at it.',
      );
    }
    final suiteResult = SuiteLoader.loadFile(suitePath, assertionKinds: knownAssertionKinds);
    if (!suiteResult.isValid) {
      throw AibError('suite invalid:\n${suiteResult.errors.join('\n')}');
    }
    final suite = suiteResult.suite!;
    if (suite.sourceHash != manifest.suiteHash) {
      warnings.add(
        'suite hash differs from the manifest — the suite '
        'changed since the run (results may not correspond to the tasks).',
      );
    }
    var persisted = const <String, Verdict>{};
    if (judge == null && needsJudge(suite)) {
      final hasVerdicts = File(p.join(runDir, RunStore.verdictsFile)).existsSync();
      switch (withoutJudge) {
        case .reusePersisted when hasVerdicts:
          persisted = store.readVerdicts();
          final by = store.readJudgeProvenance()?.judgeId;
          notes.add(
            'Verdicts reused from ${RunStore.verdictsFile}'
            '${by == null ? '' : ' (judge $by)'}; pass --judge to re-score.',
          );
        case .reusePersisted || .refuse:
          throw MissingJudge(
            'The suite has artifactRubric criteria and no --judge was given'
            '${hasVerdicts ? '' : ', and the run has no ${RunStore.verdictsFile} to reuse'}. '
            'Scoring it now would count every rubric criterion as failed. Pass '
            '--judge <config> (the model the suite pins), or --allow-missing-judge '
            'to score rubrics as 0 on purpose.',
          );
        case .scoreAsZero:
          warnings.add('scoring without a judge: every artifactRubric criterion counts as 0.');
      }
    }
    final only = options.tasks;
    final traces = [
      for (final trace in store.readTraces(
        onUnreadable: (path, error) => warnings.add(
          'skipped $path: not a readable trace ($error) — a run killed '
          'mid-write? Re-run the run to replace it.',
        ),
      ))
        if (only == null || only.contains(trace.meta.taskId)) trace,
    ];
    // Stale traces from an earlier, differently-configured run in the same
    // directory would silently enter the statistics.
    final foreign = traces.where((t) => t.meta.runId != manifest.runId).toList();
    if (foreign.isNotEmpty) {
      warnings.add(
        '${foreign.length} trace(s) belong to a different run '
        'id than the manifest (${foreign.take(3).map((t) => t.meta.episodeId).join(', ')}'
        '${foreign.length > 3 ? ', …' : ''}) — leftovers from a previous run '
        'in this directory?',
      );
    }
    final metrics = MetricsRegistry.builtin(pricing: manifest.pricing, providers: providers);
    final evaluation = RunEvaluation(
      evaluator: EpisodeEvaluator(
        evaluators: EpisodeEvaluator.defaultEvaluators(judge: judge, judgeRepetitions: options.judgeK, assertions: metrics.assertions),
      ),
      // cost_usd is priced with the table pinned at execution time, so
      // re-evaluating an old run yields the cost it actually had (§6.3).
      metrics: metrics,
    );
    final List<EpisodeRecord> records;
    try {
      records = await evaluation.evaluateRun(traces, suite, verdicts: persisted);
    } on JudgePinMismatch catch (e) {
      throw AibError('$e');
    }
    return EvaluatedRun(
      runDir: runDir,
      manifest: manifest,
      suite: suite,
      records: records,
      // Recorded only when a judge actually took part — otherwise the run has
      // no rubric scores to attribute (P6).
      judge: judge != null
          ? JudgeProvenance.forSuite(suite, judgeId: judge.judgeId, k: options.judgeK, temperature: _judgeTemperature(judge))
          : persisted.isNotEmpty
          ? store.readJudgeProvenance()
          : null,
      metrics: metrics,
      reusedVerdicts: persisted.isNotEmpty,
      warnings: warnings,
      notes: notes,
    );
  }

  /// (Re-)evaluates the traces of a run: writes `verdicts.json` and
  /// `metrics.csv`. A rubric suite without a judge is refused by default;
  /// with [WithoutJudge.reusePersisted] its stored verdicts are read and
  /// nothing is written, since there is nothing new to write.
  Future<EvaluationSummary> evaluate(String runDir, {ScoringOptions options = const ScoringOptions(), WithoutJudge withoutJudge = .refuse}) async {
    // verdicts.json is the run's; a filtered evaluation would overwrite it
    // with a part of it.
    if (options.tasks != null) throw const AibError('evaluate scores and writes the whole run; filter with evaluateRun', isUsage: true);
    final evaluated = await evaluateRun(runDir, options: options, withoutJudge: withoutJudge);
    final store = RunStore(Directory(runDir));
    // What scoring this run cost, summed from what each rubric recorded.
    var spend = const JudgeSpend();
    for (final record in evaluated.records) {
      spend = spend.plus(JudgeSpend.fromVerdict(record.verdict));
    }
    final judge = evaluated.judge;
    final judgeWithSpend = judge == null || spend.isEmpty
        ? judge
        : JudgeProvenance(
            judgeId: judge.judgeId,
            k: judge.k,
            temperature: judge.temperature,
            pinnedModel: judge.pinnedModel,
            rubrics: judge.rubrics,
            evaluatedAt: judge.evaluatedAt,
            spend: spend,
          );
    final data = RunReportData(manifest: evaluated.manifest, records: evaluated.records, aggregates: evaluated.aggregates, judge: evaluated.judge);
    if (!evaluated.reusedVerdicts) {
      store.writeVerdicts(
        {for (final record in evaluated.records) record.episodeId: record.verdict},
        judge: judgeWithSpend,
        scoredWith: await SourceRevision.ofPackage('aib_core'),
        metricProviders: evaluated.metrics.providers,
      );
      store.writeMetricsCsv(CsvReporter().render(data));
    }
    final judgeWarnings = <String>[
      if (judge != null && judge.k > 1 && judge.temperature == 0)
        'k=${judge.k} at temperature 0: the votes are near identical '
            '(ADR 0008), so the majority costs ${judge.k} calls and buys '
            'nothing. Set a judge temperature or pass --judge-k 1.',
      if (judge != null && data.judgeAgentOverlap.isNotEmpty)
        'the judge model is also the backbone of '
            '${data.judgeAgentOverlap.join(', ')} — rubric scores for these agents are not '
            'independent of the model under evaluation.',
    ];
    return EvaluationSummary(
      run: evaluated,
      judge: judgeWithSpend,
      spend: spend,
      written: evaluated.reusedVerdicts ? const [] : [p.join(runDir, RunStore.verdictsFile), p.join(runDir, RunStore.metricsFile)],
      judgeWarnings: judgeWarnings,
    );
  }

  /// Metrics over field traces, without suite, judge or verdict (L2):
  /// writes `field_metrics.csv` into [dir].
  FieldEvaluation evaluateField(String dir, {ScoringOptions options = const ScoringOptions(), String? pricing}) {
    final nested = p.join(dir, RunStore.tracesDir);
    final traceDir = Directory(nested).existsSync() ? nested : dir;
    if (!Directory(traceDir).existsSync()) {
      throw AibError('No such directory: $traceDir');
    }
    final files = Directory(traceDir).listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final metrics = MetricsRegistry.builtin(
      providers: providers(options),
      pricing: pricing == null ? null : PriceTable.fromJson(Builtins.loadConfig(pricing)),
    );
    final rows = <Map<String, Object?>>[];
    final unreadable = <String>[];
    for (final file in files) {
      final EpisodeTrace trace;
      try {
        trace = TraceCodec.decode(file.readAsStringSync());
      } on FormatException {
        unreadable.add(p.basename(file.path));
        continue;
      }
      rows.add({
        'episodeId': trace.meta.episodeId,
        'agentId': trace.meta.agentId,
        'endReason': trace.endReason,
        ...metrics.computeAll(metrics.contextFor(trace)),
      });
    }
    if (rows.isEmpty) {
      throw AibError('No readable traces in $traceDir.');
    }

    const fixed = ['episodeId', 'agentId', 'endReason'];
    final columns = [
      ...fixed,
      ...({for (final row in rows) ...row.keys}.difference(fixed.toSet()).toList()..sort()),
    ];
    final out = p.join(dir, 'field_metrics.csv');
    File(out).writeAsStringSync([columns.join(','), for (final row in rows) columns.map((c) => csvCell(row[c])).join(',')].join('\n'));
    return FieldEvaluation(traceDir: traceDir, rows: rows.length, outPath: out, unreadable: unreadable);
  }

  /// Renders [formats] into [runDir] from an evaluated run.
  Future<ReportOutcome> report(String runDir, {List<String> formats = const ['md'], ScoringOptions options = const ScoringOptions()}) async {
    final registry = ReporterRegistry();
    final reporters = [
      for (final format in formats.map((f) => f.trim()))
        registry[format] ?? (throw AibError('Unknown format "$format" (known: ${registry.formats.join(', ')})')),
    ];
    final evaluated = await evaluateRun(runDir, options: options);
    final data = RunReportData(manifest: evaluated.manifest, records: evaluated.records, aggregates: evaluated.aggregates, judge: evaluated.judge);
    final written = <String>[];
    for (final reporter in reporters) {
      reporter.writeTo(data, Directory(runDir));
      written.add(p.join(runDir, reporter.fileName));
    }
    return ReportOutcome(run: evaluated, written: written, markdown: MarkdownReporter().render(data));
  }

  /// Compares the automatic verdicts of [runDirs] against manual [labels]
  /// (spec 5.2): writes `calibration.md` and `calibration.json` to [out], by
  /// default the single run's directory.
  Future<CalibrationOutcome> calibrate(
    List<String> runDirs, {
    required String labels,
    ScoringOptions options = const ScoringOptions(),
    String? out,
  }) async {
    if (runDirs.isEmpty) throw const AibError('Pass at least one --run.', exitCode: 64);
    final names = runDirs.map((d) => p.basename(p.normalize(d))).toList();
    if (names.toSet().length != names.length) {
      throw const AibError(
        'Two --run directories share a name; pooled labels could not tell '
        'their episodes apart.',
      );
    }
    if (runDirs.length > 1 && out == null) throw const AibError('Pass --out when pooling several runs.', exitCode: 64);
    final labelsFile = File(labels);
    if (!labelsFile.existsSync()) throw AibError('Labels file not found: ${labelsFile.path}');
    final Map<String, HumanLabel> episodeLabels;
    final Map<CriterionLabelKey, HumanLabel> criterionLabels;
    try {
      final csv = labelsFile.readAsStringSync();
      episodeLabels = JudgeCalibration.parseLabels(csv);
      // Same file may carry `episode,criterion,label` rows — the level a
      // rubric judge actually decides on (§5.2).
      criterionLabels = JudgeCalibration.parseCriterionLabels(csv);
    } on FormatException catch (e) {
      throw AibError(
        'Cannot read ${labelsFile.path}: ${e.message}'
        '${e.source == null ? '' : ' — in line: ${e.source}'}',
      );
    }
    if (episodeLabels.isEmpty && criterionLabels.isEmpty) throw AibError('${labelsFile.path} contains no labels.');

    final records = <EpisodeRecord>[];
    final judgeIds = <String?>{};
    final runIds = <String>[];
    for (final (index, runDir) in runDirs.indexed) {
      final evaluated = await evaluateRun(runDir, options: options);
      judgeIds.add(evaluated.judge?.judgeId);
      runIds.add(evaluated.manifest.runId);
      for (final record in evaluated.records) {
        records.add(
          runDirs.length == 1
              ? record
              : EpisodeRecord(
                  runId: record.runId,
                  episodeId: labelIdOf(names[index], record.episodeId, runCount: runDirs.length),
                  taskId: record.taskId,
                  agentId: record.agentId,
                  repetition: record.repetition,
                  verdict: record.verdict,
                  metrics: record.metrics,
                  tags: record.tags,
                  features: record.features,
                ),
        );
      }
    }
    // Pooling two judges' verdicts would calibrate neither of them.
    if (judgeIds.length > 1) {
      throw AibError(
        'The runs were scored by different judges (${judgeIds.join(', ')}); '
        'pool only runs one judge scored, or re-score them with --judge.',
      );
    }

    final calibration = JudgeCalibration.compare(records, episodeLabels);
    final criterionCalibration = criterionLabels.isEmpty ? null : CriterionCalibration.compare(records, criterionLabels);

    if (calibration.n == 0 && (criterionCalibration?.n ?? 0) == 0) {
      throw AibError(
        'None of the ${episodeLabels.length + criterionLabels.length} label(s) '
        'name an episode of ${runDirs.length == 1 ? 'this run' : 'these runs'}'
        ' — do the episode ids match?',
      );
    }

    // Per rubric: a faithfulness judge and a task-answer judge are different
    // instruments, and one pooled κ hides which of the two is the weak one.
    final byRubric = <String, CriterionCalibration>{};
    for (final rubric in {
      for (final key in criterionLabels.keys)
        if (key.criterionId.contains(':')) key.criterionId.split(':').first,
    }) {
      byRubric[rubric] = CriterionCalibration.compare(records, {
        for (final entry in criterionLabels.entries)
          if (entry.key.criterionId.startsWith('$rubric:')) entry.key: entry.value,
      });
    }
    // Task rubrics are small one by one — a handful of rows each — so the
    // rubric most rows belong to (a suite-wide one) is set against the rest
    // pooled, which is the comparison that has an n.
    if (byRubric.length > 2) {
      final largest = byRubric.entries.reduce((a, b) => b.value.n > a.value.n ? b : a).key;
      byRubric['all but $largest'] = CriterionCalibration.compare(records, {
        for (final entry in criterionLabels.entries)
          if (!entry.key.criterionId.startsWith('$largest:')) entry.key: entry.value,
      });
    }

    final outDir = Directory(out ?? runDirs.single)..createSync(recursive: true);
    final markdown = [
      calibration.toMarkdown(runId: runIds.join(', '), judgeId: judgeIds.single),
      if (criterionCalibration != null) '\n${criterionCalibration.toMarkdown()}',
      if (byRubric.length > 1) '\n${_perRubricMarkdown(byRubric)}',
    ].join();
    final json = <String, Object?>{
      if (runDirs.length > 1) 'runs': names,
      ...calibration.toJson(),
      if (criterionCalibration != null) 'perCriterion': criterionCalibration.toJson(),
      if (byRubric.length > 1) 'perRubric': {for (final entry in byRubric.entries) entry.key: entry.value.agreementJson()},
    };
    final mdPath = p.join(outDir.path, 'calibration.md');
    final jsonPath = p.join(outDir.path, 'calibration.json');
    File(mdPath).writeAsStringSync(markdown);
    File(jsonPath).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
    return CalibrationOutcome(
      markdown: markdown,
      json: json,
      written: [mdPath, jsonPath],
      missing: [...calibration.missing, ...?criterionCalibration?.missing],
    );
  }

  static String _perRubricMarkdown(Map<String, CriterionCalibration> byRubric) {
    String fmt(double v) => v.isNaN ? '—' : v.toStringAsFixed(3);
    final buffer = StringBuffer()
      ..writeln('## Per rubric')
      ..writeln()
      ..writeln("| rubric | n | agreement | κ [95% CI] | F1 | disagreements |")
      ..writeln('|---|---|---|---|---|---|');
    for (final MapEntry(key: rubric, value: c) in byRubric.entries) {
      buffer.writeln(
        '| `$rubric` | ${c.n} | ${fmt(c.agreement)} | ${fmt(c.kappa)} '
        '[${fmt(c.kappaCi.low)}, ${fmt(c.kappaCi.high)}] | ${fmt(c.f1)} | '
        '${c.disagreements.length} |',
      );
    }
    return buffer.toString();
  }

  /// Builds the manual-labelling sheet for [calibrate] from the episodes a
  /// rubric judge voted on (spec 5.2, ADR 0008).
  LabelSheetOutcome labelSheet(List<String> runDirs, {required String out, String? suite, int? sample, int seed = 42}) {
    if (runDirs.isEmpty) throw const AibError('Pass at least one --run.', exitCode: 64);
    final names = runDirs.map((d) => p.basename(p.normalize(d))).toList();
    if (names.toSet().length != names.length) throw const AibError('Two --run directories share a name.');
    final warnings = <String>[];
    final items = <LabelItem>[];
    final judges = <String?>{};
    for (final (index, runDir) in runDirs.indexed) {
      final store = RunStore(Directory(runDir));
      final manifest = store.readManifest();
      final recorded = manifest.suitePath;
      final judge = store.readJudgeProvenance();
      final suitePath = recorded == null
          ? suite
          : locateSuite(recorded, runDir, override: suite, suiteHash: manifest.suiteHash, judgedRubrics: judge?.rubrics ?? const {});
      if (suitePath == null) throw AibError('Suite of $runDir not found; pass --suite <path>.');
      final loaded = SuiteLoader.loadFile(suitePath, assertionKinds: knownAssertionKinds);
      if (!loaded.isValid) throw AibError('suite invalid:\n${loaded.errors.join('\n')}');
      final missing = rubricsMissingFrom(loaded.suite!, judge);
      if (missing.isNotEmpty) {
        warnings.add(
          '$runDir: the judge answered ${missing.join(', ')} in a wording $suitePath '
          'does not carry — those questions are not on the sheet. Pass --suite '
          'the run was judged with.',
        );
      } else if (loaded.suite!.sourceHash != manifest.suiteHash) {
        warnings.add(
          '$runDir: the suite changed since the run; the rubrics are the ones '
          'the judge was asked.',
        );
      }
      judges.add(judge?.judgeId);
      items.addAll(
        judgedEpisodes(
          runName: names[index],
          runCount: runDirs.length,
          traces: store.readTraces(),
          verdicts: store.readVerdicts(),
          suite: loaded.suite!,
        ),
      );
    }
    if (judges.length > 1) {
      warnings.add(
        'the runs were scored by different judges (${judges.join(', ')}); '
        '`aib calibrate` will refuse to pool them.',
      );
    }
    if (items.isEmpty) throw const AibError('No episode in these runs carries a judge vote.');
    final picked = stratifiedSample(items, size: sample ?? items.length, seed: seed);

    final outDir = Directory(out)..createSync(recursive: true);
    final csvFile = File(p.join(outDir.path, 'labels.csv'));
    if (csvFile.existsSync() && _hasLabels(csvFile.readAsStringSync())) {
      throw AibError(
        '${csvFile.path} already carries labels; not overwriting it. Move '
        'it away to build a new sheet.',
      );
    }
    csvFile.writeAsStringSync(labelsCsv(picked));
    File(p.join(outDir.path, 'labels.md')).writeAsStringSync(labelsMarkdown(picked, runs: names, population: items.length, seed: seed));
    File(p.join(outDir.path, 'sample.json')).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'runs': runDirs,
        'seed': seed,
        'population': items.length,
        'judges': judges.toList(),
        'episodes': [for (final item in picked) item.labelId],
      }),
    );
    return LabelSheetOutcome(sample: picked, population: items.length, outDir: outDir.path, warnings: warnings);
  }

  /// Whether a labels file has at least one row someone filled in.
  static bool _hasLabels(String csv) =>
      csv.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('#')).any((l) => !l.endsWith(',?'));

  // Comparing

  /// Two runs: mean deltas with 95% bootstrap CIs (spec 6.5). Three or more: a
  /// sweep ranked on a cost-accuracy frontier.
  ///
  /// Refuses with [UnintendedDifferences] when the manifests differ in more
  /// than [vary] names, unless [allowAnyDiff].
  Future<ComparisonOutcome> compare(
    List<String> runDirs, {
    ScoringOptions options = const ScoringOptions(),
    List<String> vary = const [],
    bool allowAnyDiff = false,
  }) async {
    if (runDirs.length < 2) throw const AibError('compare needs at least two --runs directories', exitCode: 64);
    final runs = [for (final dir in runDirs) await evaluateRun(dir, options: options)];
    if (runs.length > 2) return _sweep(runs, vary: vary, allowAnyDiff: allowAnyDiff);
    final [a, b] = runs;
    final differences = manifestDifferences(a.manifest, b.manifest, judgeA: a.judge, judgeB: b.judge);
    final unexplained = [
      for (final d in differences)
        if (!vary.any((pattern) => pathMatches(d.path, pattern))) d,
    ];
    if (unexplained.isNotEmpty && !allowAnyDiff) {
      throw UnintendedDifferences(
        [
          'The runs differ in more than --vary names, so a delta could come from any of these:',
          for (final d in unexplained) '  ${d.path}: ${_short(d.a)} -> ${_short(d.b)}',
          'Name the intended ones with --vary, or pass --allow-any-diff.',
        ].join('\n'),
        {b.label: unexplained},
      );
    }
    final rows = RunComparator().compare(a.records, b.records);
    // Two arms of a sweep name their agent for what it is (`hybrid`,
    // `prepared`), so pairing by id would compare nothing at all.
    final paired = RunComparator.needsPairing(a.records, b.records) ? (a.records.first.agentId, b.records.first.agentId) : null;
    // Directory names carry the intent of a run, run ids only its timestamp.
    final markdown =
        _differencesMarkdown(differences, vary) +
        RunComparator.toMarkdown(
          rows,
          labelA: p.basename(p.normalize(p.absolute(runDirs[0]))),
          labelB: p.basename(p.normalize(p.absolute(runDirs[1]))),
          pairedAgents: paired,
        );
    return PairComparison(runs: runs, markdown: markdown, differences: differences, vary: vary, rows: rows, pairedAgents: paired);
  }

  static bool _sameTasks(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

  /// N runs side by side with a Pareto frontier, for choosing among
  /// conditions rather than testing one against another.
  SweepComparison _sweep(List<EvaluatedRun> runs, {required List<String> vary, required bool allowAnyDiff}) {
    final points = [
      for (final run in runs)
        RunSweep.summarise(
          p.basename(p.normalize(p.absolute(run.runDir))),
          run.records,
          nominallyPriced: {
            for (final model in run.manifest.agents.values.map((a) => asJsonMap(a['metadata'])['model']))
              if (model is String && (run.manifest.pricing?.isNominal(model) ?? false)) model,
          },
        ),
    ];

    // A sweep applies the same refusal as a pair, against the first run as the
    // baseline. It also compares the *task set*: `comparabilityProjection`
    // leaves `taskOrder` out because a pair is matched by task, but a sweep
    // reduces each run to one number.
    final unexplained = <String, List<ManifestDifference>>{};
    Set<String> tasksOf(EvaluatedRun run) => {for (final r in run.records) r.taskId};
    final baselineTasks = tasksOf(runs.first);
    for (var i = 1; i < runs.length; i++) {
      final differences = manifestDifferences(
        runs.first.manifest,
        runs[i].manifest,
        judgeA: runs.first.judge,
        judgeB: runs[i].judge,
      ).where((d) => !vary.any((pattern) => pathMatches(d.path, pattern))).toList();
      final tasks = tasksOf(runs[i]);
      if (!_sameTasks(tasks, baselineTasks)) {
        differences.add(
          ManifestDifference(
            'tasks',
            '${baselineTasks.length} task(s)',
            '${tasks.length} task(s), '
                '${baselineTasks.difference(tasks).length} missing and '
                '${tasks.difference(baselineTasks).length} extra',
          ),
        );
      }
      if (differences.isNotEmpty) unexplained[points[i].label] = differences;
    }
    if (unexplained.isNotEmpty && !allowAnyDiff) {
      throw UnintendedDifferences(
        [
          'These runs differ from ${points.first.label} in more than --vary '
              'names, so the ranking would mix conditions with bookkeeping:',
          for (final entry in unexplained.entries) ...[
            '  ${entry.key}:',
            for (final d in entry.value) '    ${d.path}: ${_short(d.a)} -> ${_short(d.b)}',
          ],
          'Name the intended ones with --vary, or pass --allow-any-diff.',
        ].join('\n'),
        unexplained,
      );
    }
    return SweepComparison(
      runs: runs,
      markdown: RunSweep.toMarkdown(points),
      html: RunSweep.toHtml(points),
      points: points,
      differences: unexplained,
    );
  }

  static String _short(Object? value) {
    final text = value is String ? value : jsonEncode(value);
    return text.length <= 60 ? text : '${text.substring(0, 57)}...';
  }

  static String _differencesMarkdown(List<ManifestDifference> differences, List<String> vary) {
    if (differences.isEmpty) {
      return '> The two manifests describe the same experiment.\n\n';
    }
    final buffer = StringBuffer()
      ..writeln('## What differs between the runs')
      ..writeln()
      ..writeln('| field | A | B | intended |')
      ..writeln('|---|---|---|---|');
    for (final d in differences) {
      final intended = vary.any((pattern) => pathMatches(d.path, pattern));
      buffer.writeln('| `${d.path}` | ${_short(d.a)} | ${_short(d.b)} | ${intended ? 'yes' : '**no**'} |');
    }
    return (buffer..writeln()).toString();
  }

  /// Scores model-routing deciders ([routed]) against the per-task oracle
  /// built from an always-[local] and an always-[cloud] run
  /// (docs/overview.md). Needs the `routing` metric provider.
  Future<RouteOutcome> route({
    required String local,
    required String cloud,
    List<String> routed = const [],
    ScoringOptions options = const ScoringOptions(metrics: ['routing']),
  }) async {
    // The route metrics are what the routed arms are read through; asking for
    // them silently would hide that the number depends on a provider.
    if (!providers(options).any((p) => p.name == routingMetrics.name)) {
      throw const AibError('route reads the "routing" metric provider — add --metrics routing', isUsage: true);
    }
    final localRun = await evaluateRun(local, options: options);
    final cloudRun = await evaluateRun(cloud, options: options);
    final routedRuns = <String, EvaluatedRun>{
      for (final dir in routed) p.basename(p.normalize(p.absolute(dir))): await evaluateRun(dir, options: options),
    };

    final oracle = RouteOracle.from(local: localRun.records, cloud: cloudRun.records);
    if (oracle.tasks.isEmpty) throw const AibError('the two reference arms share no task — they cannot be routed between');
    final report = RouteReport(
      oracle: oracle,
      arms: [for (final entry in routedRuns.entries) RoutedArm.from(label: entry.key, records: entry.value.records, oracle: oracle)],
      // A task's `lang:` tag, else what the router detected, else a
      // detection of the suite's instruction — so a run from before the
      // router recorded a language still splits.
      languages: RouteReport.languagesOf(
        [...localRun.records, ...cloudRun.records, for (final run in routedRuns.values) ...run.records],
        fallback: {for (final task in localRun.suite.tasks) task.id: ?detectLanguage(task.instruction)},
      ),
    );
    return RouteOutcome(
      report: report,
      extras: {
        for (final arm in report.arms)
          arm.label: RoutedArmExtras(
            deciderCostUsd: arm.deciderCostUsd(routedRuns[arm.label]!.records),
            stability: routeStability(routedRuns[arm.label]!.records),
          ),
      },
    );
  }

  // Checks

  /// Checks the suite's oracles: each task's reference must pass, stopping at
  /// once must not.
  Future<SelftestOutcome> selftest({
    required String suite,
    String? reference,
    String env = 'mock',
    String? judge,
    List<String>? tasks,
    bool requireReferences = false,
  }) async {
    final taskSuite = _loadSuite(suite);
    final only = tasks?.map((s) => s.trim()).toSet();
    final selected = [
      for (final task in taskSuite.tasks)
        if (only == null || only.contains(task.id)) task,
    ];
    final artifactJudge = judgeFrom(judge);
    final (envName, envConfig) = Builtins.parseSpec(env);
    final selftest = OracleSelfTest(
      environment: Builtins.environmentRegistry().create(envName, Builtins.loadConfig(envConfig)),
      references: reference == null ? ScriptedAgent(agentId: 'reference') : ScriptedAgent.fromJson(Builtins.loadConfig(reference)),
      evaluator: EpisodeEvaluator(
        evaluators: EpisodeEvaluator.defaultEvaluators(judge: artifactJudge, assertions: intentConventions.assertions),
      ),
    );
    return SelftestOutcome(
      checks: await selftest.run(selected),
      requireReferences: requireReferences,
      warnings: [if (artifactJudge == null && needsJudge(taskSuite)) 'no --judge: artifactRubric criteria score 0, so references using them fail.'],
    );
  }

  /// Every metric: builtin, and per provider.
  List<MetricInfo> metrics() {
    final providers = Builtins.metricProviders();
    return [
      for (final metric in builtinMetrics) MetricInfo(name: metric.name, unit: metric.unit, source: 'builtin', description: metric.description),
      const MetricInfo(name: 'cost_usd', unit: 'usd', source: 'builtin (priced runs)', description: 'Tokens × the run\'s pinned price table'),
      const MetricInfo(name: 'agent.<name>', unit: 'count', source: 'builtin', description: 'Sum of extra.counters.<name> over the episode'),
      for (final providerName in providers.names) ...[
        for (final metric in providers.create(providerName).metrics)
          MetricInfo(name: metric.name, unit: metric.unit, source: '--metrics $providerName', description: metric.description),
        for (final aggregate in providers.create(providerName).aggregates)
          MetricInfo(name: aggregate.name, unit: aggregate.unit, source: '--metrics $providerName (per task, *)', description: aggregate.description),
      ],
    ];
  }

  /// Checks that a run can start before it spends the time.
  Future<DoctorReport> doctor({String? suite, String? judge, String? simulator, List<String> agents = const []}) async {
    final checks = <DoctorCheck>[];
    // A doctor that throws is a doctor nobody runs first: an unreadable
    // config is a finding like any other.
    LlmTarget? read(String label, String path) {
      try {
        return _target(label, Builtins.loadConfig(path));
      } on Object catch (error) {
        checks.add(DoctorCheck(DoctorStatus.fail, '$label: $path does not load', detail: '$error'.split('\n').first, nextStep: 'ls suites/agents/'));
        return null;
      }
    }

    final judgeTarget = judge == null ? null : read('judge', judge);
    final simulatorTarget = simulator == null ? null : read('simulator', simulator);
    final agentTargets = <LlmTarget>[];
    for (final spec in agents) {
      final (agentName, configPath) = Builtins.parseSpec(spec);
      if (configPath == null) continue;
      if (read(agentName, configPath) case final target?) agentTargets.add(target);
    }

    if (suite != null) {
      final result = validateSuite(suite);
      checks.add(
        result.isValid
            ? DoctorCheck(
                DoctorStatus.ok,
                'suite ${result.suite!.name}: ${result.suite!.tasks.length} tasks load',
                detail: result.warnings.isEmpty ? null : '${result.warnings.length} warning(s).',
              )
            : DoctorCheck(
                DoctorStatus.fail,
                'suite is invalid (${result.errors.length} error(s))',
                detail: result.errors.first,
                nextStep: 'aib validate --suite $suite',
              ),
      );
    }

    checks.addAll(
      preflightConfigChecks(
        judge: judgeTarget,
        agents: agentTargets,
        simulator: simulatorTarget,
        environmentKeys: {
          for (final entry in Platform.environment.entries)
            if (entry.value.isNotEmpty) entry.key,
        },
      ),
    );

    for (final target in [?judgeTarget, ?simulatorTarget, ...agentTargets]) {
      if (!target.isLocal) continue;
      checks.add(await _probeOllama(target));
    }
    return DoctorReport(checks);
  }

  LlmTarget _target(String label, JsonMap config) {
    final llm = LlmClientFactory.llmSection(config);
    const defaultKeyEnv = {'anthropic': 'ANTHROPIC_API_KEY', 'openai': 'OPENAI_API_KEY', 'azure': 'AZURE_OPENAI_API_KEY'};
    final provider = llm['provider'] as String? ?? 'anthropic';
    return LlmTarget(
      label: label,
      provider: provider,
      model: '${llm['model'] ?? llm['modelId'] ?? llm['deployment'] ?? 'unknown'}',
      baseUrl: llm['baseUrl'] as String?,
      apiKeyEnv: llm['apiKeyEnv'] as String? ?? defaultKeyEnv[provider],
    );
  }

  /// Reachable, and holding the pinned model. A model that is merely absent
  /// looks exactly like a model that is slow to load.
  Future<DoctorCheck> _probeOllama(LlmTarget target) async {
    final base = target.baseUrl ?? 'http://localhost:11434';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client.getUrl(Uri.parse('$base/api/tags'));
      final response = await request.close().timeout(const Duration(seconds: 5));
      final body = await response.transform(utf8.decoder).join();
      final models = [for (final m in asJsonMap(jsonDecode(body))['models'] as List? ?? const []) '${asJsonMap(m)['name']}'];
      if (models.contains(target.model)) {
        return DoctorCheck(DoctorStatus.ok, '${target.label}: ${target.model} is pulled on $base');
      }
      return DoctorCheck(
        DoctorStatus.fail,
        '${target.label}: $base has no ${target.model}',
        detail: models.isEmpty ? 'It has no models at all.' : 'It has ${models.join(", ")}.',
        nextStep: 'ollama pull ${target.model}',
      );
    } on Object catch (error) {
      return DoctorCheck(DoctorStatus.fail, '${target.label}: $base is not answering', detail: '$error', nextStep: 'ollama serve');
    } finally {
      client.close(force: true);
    }
  }

  // Run inspection

  /// What a run was, in the fields that decide whether another compares
  /// with it; with [against], also what moved between them.
  ProvenanceOutcome provenance(String runDir, {String? against}) {
    final store = RunStore(Directory(runDir));
    final otherStore = against == null ? null : RunStore(Directory(against));
    final manifest = store.readManifest();
    final judge = store.readJudgeProvenance();
    final other = otherStore?.readManifest();
    final otherJudge = otherStore?.readJudgeProvenance();
    return ProvenanceOutcome(
      manifest: manifest,
      judge: judge,
      against: other,
      differences: other == null ? const [] : manifestDifferences(manifest, other, judgeA: judge, judgeB: otherJudge),
      markdown: provenanceMarkdown(
        manifest,
        judge: judge,
        against: other,
        againstJudge: otherJudge,
        againstName: against == null ? null : p.basename(against),
      ),
    );
  }

  /// Lints the intent listing a run was shown. The listing is the whole of
  /// what a model chooses from, and a defect in it costs every episode.
  CatalogOutcome lintCatalog(String runDir, {String? prompt}) {
    final traces = RunStore(Directory(runDir)).readTraces();
    final entries = catalogFromTraces(traces, listingKey: IntentConventions.catalogKey);
    if (entries.isEmpty) throw const AibError('No intents.catalog result in this run; nothing to lint.');
    final findings = catalogLint(entries);
    final promptOnly = prompt == null ? const <String>[] : promptIntentsNotInCatalog(File(prompt).readAsStringSync(), entries);
    return CatalogOutcome(
      entries: entries,
      findings: findings,
      promptOnly: promptOnly,
      markdown: catalogLintMarkdown(entries, findings, promptOnly: promptOnly),
    );
  }

  /// Per-intent failure, schema and repetition rates of a run: where the app
  /// integration loses turns.
  IntentsOutcome intents(String runDir) {
    final traces = RunStore(Directory(runDir)).readTraces();
    final rows = intentHealth(traces, label: (x) => IntentConventions.label(x.key, asJsonMap(x.envelope.data['payload'])));
    return IntentsOutcome(
      rows: rows,
      episodes: traces.length,
      markdown: intentHealthMarkdown(rows, episodes: traces.length),
    );
  }
}
