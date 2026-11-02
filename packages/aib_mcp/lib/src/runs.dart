import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:aib_cli/aib_cli.dart';
import 'package:aib_core/aib_core.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'jobs.dart';
import 'targets.dart';
import 'workspace.dart';

/// Asks a person to approve something; false when they decline or no one
/// can be asked.
typedef Approver = Future<bool> Function(String message);

/// Who launched a job, recorded next to the run it wrote.
typedef Launcher = ({String client, String clientVersion});

/// Starts runs and judged evaluations as jobs: resolves the runner recipe
/// and the arm, estimates what the run costs from earlier runs of the same
/// arm, and applies the budget before anything starts.
final class RunLauncher {
  RunLauncher({required this.workspace, required this.jobs, DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  final AibWorkspace workspace;
  final JobManager jobs;
  final DateTime Function() clock;

  AibMcpConfig get config => workspace.config;

  late final PriceTable prices = PriceTable.fromJson(Builtins.loadConfig(workspace.sandbox.read(config.budget.priceTable)));

  /// The file a run directory's launches are recorded in: who started it
  /// over MCP, for which study. Beside the manifest rather than in it — the
  /// manifest is the runner's, and a resumed run compares it.
  static const launchFile = 'aib_mcp_launch.json';

  RunnerRecipe recipe(String runner) =>
      config.runners[runner] ?? (throw AibError('no runner "$runner" (configured: ${config.runners.keys.join(', ')})'));

  /// What a run of [configName] would cost, from earlier runs of the same
  /// arm — or of its base, for a derived arm that has none yet.
  JsonMap estimate({required String configName, required String agent, required String suite, List<String>? tasks, int? reps}) {
    final plan = _plan(configName: configName, agent: agent, suite: suite, tasks: tasks, reps: reps);
    final targets = modelTargets(plan.config);
    final paid = paidTargets(targets, prices);
    final history = _history(plan.suite.name, agent: agent, configName: configName, config: plan.config);
    final per = history.episodes;
    double? mean(List<double> xs) => xs.isEmpty ? null : xs.reduce((a, b) => a + b) / xs.length;
    final costs = [for (final e in per) ?e.cost];
    final n = plan.episodes;
    return {
      'suite': plan.suite.name,
      'episodes': n,
      'hosts': hostsOf(targets, config.hosts).toList(),
      'paidModels': [for (final t in paid) '${t.provider}:${t.model}'],
      'basis': {'arm': history.arm, 'runs': history.runs, 'episodes': per.length},
      if (per.isNotEmpty) ...{
        'perEpisode': {
          'tokens': mean([for (final e in per) ?e.tokens]),
          'wallClockMs': mean([for (final e in per) ?e.wallClockMs]),
          'costUsd': mean(costs),
        },
        'costUsd': costs.isEmpty
            ? null
            : {'low': costs.reduce((a, b) => a < b ? a : b) * n, 'expected': mean(costs)! * n, 'high': costs.reduce((a, b) => a > b ? a : b) * n},
        'wallClockMinutes': (mean([for (final e in per) ?e.wallClockMs]) ?? 0) * n / 60000,
      },
    };
  }

  /// Starts a run of [configName] as [agent] through [runner], into
  /// `results/<out>`. An existing [out] is resumed, as `aib run` resumes.
  Future<Job> startRun({
    required String runner,
    required String configName,
    required String agent,
    String? suite,
    int? reps,
    List<String>? tasks,
    int? seed,
    double? maxUsd,
    String? out,
    String? study,
    String? otel,
    bool otelCaptureContent = false,
    Launcher? launcher,
    Approver? approve,
    String kind = 'run',
    Future<JsonMap?> Function(Job job, String outDir)? then,
  }) async {
    final recipe = this.recipe(runner);
    final suiteName = recipe.suite ?? suite ?? (throw AibError('runner "$runner" runs any suite: pass `suite`'));
    if (recipe.suite != null && suite != null && suite != recipe.suite) {
      throw AibError('runner "$runner" runs ${recipe.suite}, not $suite');
    }
    final plan = _plan(configName: configName, agent: agent, suite: suiteName, tasks: tasks, reps: reps);
    final targets = modelTargets(plan.config);
    final paid = paidTargets(targets, prices);
    final budget = await _guard(
      paid: paid,
      maxUsd: maxUsd,
      estimate: () => estimate(configName: configName, agent: agent, suite: suiteName, tasks: tasks, reps: reps),
      what: 'run $configName on ${plan.suite.name} (${plan.episodes} episodes)',
      approve: approve,
    );

    final name = out ?? '${configName.replaceAll('/', '-')}-$runner-${_stamp(clock())}';
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.\-]*$').hasMatch(name)) throw AibError('"$name" is not a run directory name');
    final outDir = workspace.sandbox.write(p.join('results', name));
    if (jobs.jobs.any((j) => j.runDir == outDir && !j.state.isFinal)) throw AibError('results/$name has a job on it already');

    final job = Job(
      id: jobs.newId(),
      kind: kind,
      label: '$configName on ${plan.suite.name} via $runner',
      hosts: hostsOf(targets, config.hosts),
      maxUsd: budget,
      runDir: outDir,
      total: plan.episodes,
      study: study,
    );
    final vars = {
      'root': config.root,
      'home': Platform.environment['HOME'] ?? '',
      'agentConfigPath': plan.configPath,
      'agentConfigName': configName,
      'agentConfigFile': p.basename(configName),
      'suitesDir': p.join(config.root, 'suites'),
      'agent': agent,
      'reps': reps?.toString() ?? '',
      'tasks': tasks?.join(',') ?? '',
      'seed': seed?.toString() ?? '',
      'out': name,
      'outDir': outDir,
      'suitePath': plan.suitePath,
      // OTLP/HTTP traces endpoint of a collector (or of the UI); a runner
      // passes it on as it passes the other variables.
      'otel': otel ?? '',
      'otelCaptureContent': otelCaptureContent ? '1' : '',
    };
    return jobs.submit(job, (job) async {
      // Recorded when the job starts, not when it queues: a queued job that
      // is cancelled leaves no directory behind.
      _recordLaunch(outDir, job, runner: runner, configName: configName, agent: agent, launcher: launcher, otel: otel);
      final result = recipe.kind == .inProcess
          ? await _inProcess(
              job,
              recipe,
              plan,
              agent: agent,
              outDir: outDir,
              reps: reps,
              seed: seed,
              tasks: tasks,
              otel: otel,
              otelCaptureContent: otelCaptureContent,
            )
          : await _process(job, recipe, vars, outDir: outDir);
      if (then == null || job.isCancelling) return result;
      return {...?result, ...?await then(job, outDir)};
    });
  }

  /// Scores [runDir] with the judge pinned for its suite, as a job: the
  /// judge is a model, and its calls take the host like a run does.
  Future<Job> startJudgedEvaluation({
    required String runDir,
    List<String> metrics = const [],
    double? maxUsd,
    String? study,
    Approver? approve,
    Set<String>? only,
  }) async {
    final manifest = RunStore(Directory(runDir)).readManifest();
    final judgeName = config.judges[manifest.suiteName] ?? (throw AibError('no judge is pinned for ${manifest.suiteName} (aib_mcp.yaml `judges:`)'));
    final judgePath = workspace.agentConfigPath(judgeName);
    final targets = modelTargets(Builtins.loadConfig(judgePath));
    final paid = paidTargets(targets, prices);
    final budget = await _guard(
      paid: paid,
      maxUsd: maxUsd,
      estimate: () => null,
      what: 'judge ${workspace.sandbox.relative(runDir)} with $judgeName',
      approve: approve,
    );
    final job = Job(
      id: jobs.newId(),
      kind: 'evaluate',
      label: 'judge ${workspace.sandbox.relative(runDir)} with $judgeName',
      hosts: hostsOf(targets, config.hosts),
      maxUsd: budget,
      runDir: runDir,
      // The episodes on disk: the manifest knows neither a task's own
      // repetitions nor its instruction variants.
      total: _traceCount(runDir),
      study: study,
    );
    return jobs.submit(job, (job) async {
      return runIsolate(job, evaluateWork(runDir, judgePath, metrics, only: only));
    });
  }

  static int _traceCount(String runDir) {
    final traces = Directory(p.join(runDir, RunStore.tracesDir));
    return traces.existsSync() ? traces.listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl')).length : 0;
  }

  /// Refuses what the budget does not allow; returns the job's spend cap.
  Future<double?> _guard({
    required List<ModelTarget> paid,
    required double? maxUsd,
    required JsonMap? Function() estimate,
    required String what,
    required Approver? approve,
  }) async {
    if (paid.isEmpty) return null;
    final models = paid.map((t) => '${t.provider}:${t.model}').join(', ');
    if (maxUsd == null) throw AibError('$what uses priced models ($models): pass maxUsd');
    if (maxUsd > config.budget.maxUsdPerJob) throw AibError('maxUsd \$$maxUsd exceeds the per-job budget of \$${config.budget.maxUsdPerJob}');
    final today = jobs.spentToday();
    if (today + maxUsd > config.budget.maxUsdPerDay) {
      throw AibError('\$${today.toStringAsFixed(2)} spent today; another \$$maxUsd exceeds the daily budget of \$${config.budget.maxUsdPerDay}');
    }
    final high = (asJsonMap(estimate()?['costUsd'])['high'] as num?)?.toDouble();
    if (high != null && high > maxUsd) throw AibError('the estimate reaches \$${high.toStringAsFixed(2)}, above maxUsd \$$maxUsd');
    if (high == null || high > config.budget.autoApproveUsd) {
      final message =
          'Approve: $what on $models, stopped at \$$maxUsd '
          '(estimate ${high == null ? 'unknown — no earlier run of this arm' : 'up to \$${high.toStringAsFixed(2)}'}).';
      if (approve == null || !await approve(message)) throw AibError('not approved: $message');
    }
    return maxUsd;
  }

  _Plan _plan({required String configName, required String agent, required String suite, List<String>? tasks, int? reps}) {
    final configPath = workspace.agentConfigPath(configName);
    final config = Builtins.loadConfig(configPath);
    final check = workspace.service.validateAgentConfig(agent: agent, config: config);
    if (!check.built) throw AibError('$configName does not build as $agent: ${check.error}');
    final suitePath = workspace.suitePath(suite);
    final validation = workspace.service.validateSuite(suitePath);
    final loaded = validation.suite ?? (throw AibError('Suite invalid:\n  ${validation.errors.join('\n  ')}'));
    final ids = {for (final t in loaded.tasks) t.id};
    final unknown = [...?tasks?.where((t) => !ids.contains(t))];
    if (unknown.isNotEmpty) throw AibError('${loaded.name} has no task ${unknown.join(', ')}');
    if (reps != null && reps < 1) throw const AibError('reps must be at least 1');
    final selected = [
      for (final task in loaded.tasks)
        if (tasks == null || tasks.contains(task.id)) task,
    ];
    return _Plan(
      configPath: configPath,
      config: config,
      manifest: check.manifest!,
      suitePath: suitePath,
      suite: loaded,
      // The runner asks each task as written and then in each of its
      // instruction variants, every asking for the task's repetitions.
      episodes: selected.fold(0, (n, task) => n + (1 + task.variants.length) * (reps ?? loaded.repetitionsFor(task))),
    );
  }

  /// Episodes of earlier runs of this exact arm (same manifest entry as a
  /// build of it now), else of the base a derived arm names in its header.
  ({String? arm, List<String> runs, List<({double? cost, double? tokens, double? wallClockMs})> episodes}) _history(
    String suite, {
    required String agent,
    required String configName,
    required JsonMap config,
  }) {
    String key(JsonMap entry) => jsonEncode({...entry}..remove('description'));
    List<String> runsOf(JsonMap config) {
      final check = workspace.service.validateAgentConfig(agent: agent, config: config);
      if (!check.built) return const [];
      final wanted = key(check.manifest!.toJson());
      return [
        for (final run in workspace.listRuns(suite: suite))
          if (RunStore(Directory(workspace.sandbox.read('${run['run']}'))).readManifest().agents.values.any((a) => key(a) == wanted)) '${run['run']}',
      ];
    }

    var arm = configName;
    var runs = runsOf(config);
    if (runs.isEmpty) {
      final text = File(workspace.agentConfigPath(configName)).readAsStringSync();
      if (RegExp(r'^# Derived from (\S+)\.yaml').firstMatch(text)?.group(1) case final base?) {
        arm = base;
        runs = runsOf(workspace.loadAgentConfig(base));
      }
    }
    if (runs.isEmpty) return (arm: null, runs: const [], episodes: const []);
    final metrics = MetricsRegistry.builtin(pricing: prices);
    return (
      arm: arm,
      runs: runs,
      episodes: [
        for (final run in runs)
          for (final trace in RunStore(Directory(workspace.sandbox.read(run))).readTraces(onUnreadable: (_, _) {}))
            if (trace.isComplete) _episodeCost(metrics.computeAll(metrics.contextFor(trace))),
      ],
    );
  }

  Future<JsonMap?> _inProcess(
    Job job,
    RunnerRecipe recipe,
    _Plan plan, {
    required String agent,
    required String outDir,
    int? reps,
    int? seed,
    List<String>? tasks,
    String? otel,
    bool otelCaptureContent = false,
  }) async {
    if (tasks != null && tasks.length != plan.suite.tasks.length) {
      throw const AibError('an in-process runner runs whole suites; `tasks` needs an app runner (`aib run` takes no task list)');
    }
    final work = _runWork(
      suite: plan.suitePath,
      agentSpec: '$agent=${plan.configPath}',
      outDir: outDir,
      env: recipe.environment,
      reps: reps,
      seed: seed ?? 42,
      otel: otel,
      otelCaptureContent: otelCaptureContent,
    );
    return _watched(job, outDir, recipe.maxMinutes, () => runIsolate(job, work));
  }

  Future<JsonMap?> _process(Job job, RunnerRecipe recipe, Map<String, String> vars, {required String outDir}) async {
    String expand(String template) =>
        template.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) => vars[m[1]] ?? (throw AibError('recipe ${recipe.name}: unknown {${m[1]}}')));
    final cwd = recipe.cwd == null
        ? config.root
        : (p.isAbsolute(expand(recipe.cwd!)) ? expand(recipe.cwd!) : p.join(config.root, expand(recipe.cwd!)));
    if (!Directory(cwd).existsSync()) throw AibError('recipe ${recipe.name}: $cwd does not exist (set it in aib_mcp.local.yaml)');
    final stage = recipe.stageSuites ? workspace.sandbox.write(p.join('results', '.aib_mcp', 'stage', job.id)) : null;
    if (stage != null) {
      final suites = p.join(stage, 'suites');
      copyTree(p.join(config.root, 'suites'), suites);
      File(vars['agentConfigPath']!).copySync(p.join(suites, 'agents', '${vars['agentConfigFile']}.yaml'));
      vars = {...vars, 'suitesDir': suites};
    }
    final env = {for (final entry in recipe.env.entries) entry.key: expand(entry.value)};
    final written = recipe.output == null ? outDir : expand(recipe.output!);
    try {
      if (recipe.prepare case final prepare?) {
        final code = await runProcess(job, [for (final part in prepare) expand(part)], cwd: cwd, env: env);
        if (code == null) return null;
        if (code != 0) throw AibError('prepare exited with $code');
      }
      return await _watched(job, written, recipe.maxMinutes, () async {
        final code = await runProcess(job, [for (final part in recipe.command) expand(part)], cwd: cwd, env: env);
        if (code == null) return null;
        if (code != 0) throw AibError('the runner exited with $code (see aib_job_log)');
        return {'runDir': workspace.sandbox.relative(outDir)};
      });
    } finally {
      if (written != outDir) copyTree(written, outDir);
      if (recipe.cleanup case final cleanup?) {
        // A job already asked to stop still cleans up: a fresh job-less
        // stop signal would kill the cleanup too.
        final cleanupJob = Job(id: '${job.id}-cleanup', kind: 'cleanup', label: 'cleanup', hosts: const {});
        final code = await runProcess(cleanupJob, [for (final part in cleanup) expand(part)], cwd: cwd, env: env);
        for (final line in cleanupJob.tail(20)) {
          job.log('cleanup: $line');
        }
        if (code != 0) job.log('cleanup exited with $code');
      }
      if (stage != null && Directory(stage).existsSync()) Directory(stage).deleteSync(recursive: true);
    }
  }

  /// Runs [body] while polling [dir] for progress and spend; stops the job
  /// at its spend cap and at the runner's wall-clock cap.
  Future<JsonMap?> _watched(Job job, String dir, int cap, Future<JsonMap?> Function() body) async {
    final watcher = RunWatcher(dir, prices: prices, since: job.startedAt ?? DateTime.now());
    void poll() {
      watcher.poll();
      job.progress(done: watcher.done, spend: watcher.spend);
      if (job.maxUsd case final max? when watcher.spend >= max) {
        job.stopReason = 'budget';
        job.requestStop('spend reached \$${watcher.spend.toStringAsFixed(4)} of \$$max');
      }
      if (DateTime.now().difference(job.startedAt!).inMinutes >= cap) {
        job.stopReason = 'wall clock';
        job.requestStop('wall-clock cap of $cap min');
      }
    }

    final timer = Timer.periodic(const Duration(seconds: 2), (_) => poll());
    try {
      return await body();
    } finally {
      timer.cancel();
      poll();
    }
  }

  void _recordLaunch(
    String outDir,
    Job job, {
    required String runner,
    required String configName,
    required String agent,
    Launcher? launcher,
    String? otel,
  }) {
    final file = File(p.join(outDir, launchFile));
    final previous = file.existsSync() ? (jsonDecode(file.readAsStringSync()) as List) : const <Object?>[];
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert([
        ...previous,
        {
          'launchedBy': 'mcp',
          'job': job.id,
          'at': clock().toIso8601String(),
          'runner': runner,
          'config': configName,
          'agent': agent,
          'client': ?launcher?.client,
          'clientVersion': ?launcher?.clientVersion,
          'study': ?job.study,
          'otel': ?otel,
        },
      ]),
    );
  }

  static String _stamp(DateTime t) => t.toIso8601String().replaceAll(RegExp(r'[:\-]'), '').replaceAll('T', '-').substring(0, 15);
}

final class _Plan {
  const _Plan({
    required this.configPath,
    required this.config,
    required this.manifest,
    required this.suitePath,
    required this.suite,
    required this.episodes,
  });

  final String configPath;
  final JsonMap config;
  final AgentManifest manifest;
  final String suitePath;
  final TaskSuite suite;
  final int episodes;
}

({double? cost, double? tokens, double? wallClockMs}) _episodeCost(Map<String, num?> values) =>
    (cost: values['cost_usd']?.toDouble(), tokens: values['tokens_total']?.toDouble(), wallClockMs: values['wall_clock_ms']?.toDouble());

// Isolate entry points are built at top level: a closure made inside an
// instance method can capture that instance, which cannot cross isolates.

void Function(SendPort) _runWork({
  required String suite,
  required String agentSpec,
  required String outDir,
  required String env,
  required int? reps,
  required int seed,
  String? otel,
  bool otelCaptureContent = false,
}) => (port) async {
  try {
    final outcome = await const AibService().run(
      suite: suite,
      agents: [agentSpec],
      outDir: outDir,
      env: env,
      reps: reps,
      seed: seed,
      otel: otel,
      otelCaptureContent: otelCaptureContent,
      onEpisode: (meta, result) => port.send({'log': '  ${meta.episodeId}: ${result.outcome.reason.name}'}),
      onSkipped: (meta, reason) => port.send({'log': '  ${meta.episodeId}: reused ($reason)'}),
    );
    port.send({'result': outcome.toJson()});
  } on Object catch (e) {
    port.send({'error': '$e'});
  }
};

/// Scores [runDir] with the judge at [judgePath] (writing its verdicts) and
/// reports the scores of [only]'s tasks — the tuning split, when the suite
/// has one.
void Function(SendPort) evaluateWork(String runDir, String? judgePath, List<String> metrics, {Set<String>? only}) => (port) async {
  try {
    const service = AibService();
    final options = ScoringOptions(judge: judgePath, metrics: metrics);
    final summary = await service.evaluate(runDir, options: options, withoutJudge: .reusePersisted);
    final shown = only == null ? summary : await restrictSummary(service, summary, options, only);
    port.send({'log': 'judge spend: ${summary.spend.calls} call(s)', 'result': shown.toJson()});
  } on Object catch (e) {
    port.send({'error': '$e'});
  }
};

/// [summary] re-read for [only]'s tasks from the verdicts it just wrote.
Future<EvaluationSummary> restrictSummary(AibService service, EvaluationSummary summary, ScoringOptions options, Set<String> only) async {
  final run = await service.evaluateRun(
    summary.run.runDir,
    options: ScoringOptions(metrics: options.metrics, conventions: options.conventions, tasks: only),
    withoutJudge: .reusePersisted,
  );
  return EvaluationSummary(run: run, judge: summary.judge, spend: summary.spend, written: summary.written, judgeWarnings: summary.judgeWarnings);
}
