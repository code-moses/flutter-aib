import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aib_cli/aib_cli.dart';
import 'package:aib_core/aib_core.dart';
import 'package:dart_mcp/server.dart';
import 'package:path/path.dart' as p;

import 'arms.dart';
import 'jobs.dart';
import 'replay.dart';
import 'runs.dart';
import 'study.dart';
import 'workspace.dart';

/// The aib CLI over MCP. Every tool calls [AibService] or [AibWorkspace]; none
/// writes anything the CLI could not also write. The transport is stdio or
/// Streamable HTTP.
base class AibMcpServer extends MCPServer with LoggingSupport, ElicitationRequestSupport, ToolsSupport, ResourcesSupport {
  AibMcpServer(super.channel, {required this.workspace, RunLauncher? runs, String? frameworkRevision})
    : runs =
          runs ??
          RunLauncher(
            workspace: workspace,
            jobs: JobManager(hostLimits: {for (final h in workspace.config.hosts.values) h.name: h.concurrency}),
          ),
      _framework = frameworkRevision,
      super.fromStreamChannel(
        implementation: Implementation(name: 'aib', version: '1.0.0'),
        instructions: _instructions,
      ) {
    _registerTools();
    _registerRunTools();
    _registerTuneTools();
    _registerResources();
  }

  final AibWorkspace workspace;

  /// Shared by every session of one server process: the host queue and the
  /// daily budget are the machine's, not a client's.
  final RunLauncher runs;
  final String? _framework;

  JobManager get jobs => runs.jobs;

  /// The study this session's tries are journaled to (aib_study).
  Study? _study;

  void _journal(String type, JsonMap data) => _study?.record(type, data);

  AibService get _service => workspace.service;

  static const _instructions =
      'The AI Interaction Benchmark (aib). Suites, agent configs ("arms") '
      'and runs are named as the list tools name them; paths are relative to '
      'the checkout. Suite descriptions carry no ground truth on purpose. A '
      'new arm is derived from an existing one with one change and a '
      'hypothesis; compare refuses runs that differ in more than `vary` names. '
      'Runs and judged evaluations are jobs: start one, then follow it with '
      'aib_job_wait. Where a suite has a holdout, every tool sees the tuning '
      'split only; aib_holdout_score needs a person\'s approval each time.';

  // Tools

  static final _read = ToolAnnotations(readOnlyHint: true, openWorldHint: false);
  static final _write = ToolAnnotations(readOnlyHint: false, destructiveHint: false, openWorldHint: false);

  static final _suite = Schema.string(description: 'Suite name as aib_list_suites names it (e.g. "todo_v2"), or a .yaml path.');
  static final _run = Schema.string(description: 'Run directory relative to the checkout, as aib_list_runs names it.');
  static final _agent = Schema.string(description: 'Agent kind the config is built as: semantics, intent, genui, hybrid or prepared.');
  static final _metrics = Schema.list(items: Schema.string(), description: 'Metric providers to add (see aib_metrics_catalog).');

  void _tool(String name, String description, ObjectSchema input, FutureOr<Object?> Function(Map<String, Object?> args) body, {bool write = false}) {
    registerTool(Tool(name: name, description: description, inputSchema: input, annotations: write ? _write : _read), (request) async {
      try {
        final result = await runZoned(() => body(request.arguments ?? const {}), zoneValues: {#request: request});
        final json = <String, Object?>{
          if (result is Map) ...result.cast<String, Object?>() else 'items': result,
          'aib': {'framework': ?_framework},
        };
        return CallToolResult(
          content: [TextContent(text: const JsonEncoder.withIndent('  ').convert(json))],
          structuredContent: json,
        );
      } on AibError catch (e) {
        return CallToolResult(content: [TextContent(text: e.message)], isError: true);
      } on FileSystemException catch (e) {
        return CallToolResult(content: [TextContent(text: '${e.message}: ${e.path}')], isError: true);
      } on FormatException catch (e) {
        return CallToolResult(content: [TextContent(text: e.message)], isError: true);
      }
    });
  }

  /// The call being handled, for the tools that report progress.
  static CallToolRequest get _request => Zone.current[#request] as CallToolRequest;

  /// Asks the person at the client, through elicitation. A client that
  /// cannot be asked gets a refusal rather than a silent yes.
  Future<bool> _approve(String message) async {
    if (!supportsElicitation) return false;
    final answer = await elicit(
      ElicitRequest.form(
        message: message,
        requestedSchema: Schema.object(
          properties: {'approve': Schema.bool(description: 'Approve?')},
          required: ['approve'],
        ),
      ),
    );
    return answer.action == .accept && answer.content?['approve'] == true;
  }

  Launcher get _launcher => (client: clientInfo.name, clientVersion: clientInfo.version);

  JsonMap _job(Job job) => job.toJson(path: workspace.sandbox.relative);

  ScoringOptions _scoring(Map<String, Object?> args) => ScoringOptions(metrics: [for (final m in args['metrics'] as List? ?? const []) '$m']);

  List<String> _strings(Object? list) => [for (final item in list as List? ?? const []) '$item'];

  void _registerTools() {
    // Discover ------------------------------------------------------------
    _tool(
      'aib_list_suites',
      'Task suites with task counts, tags, languages and criterion kinds.',
      Schema.object(),
      (_) => {'suites': workspace.listSuites()},
    );
    _tool(
      'aib_describe_suite',
      "A suite's tasks: id, title, instruction, tags, language, budget, optimalSteps. No ground truth.",
      Schema.object(properties: {'suite': _suite}, required: ['suite']),
      (args) => workspace.describeSuite(args['suite'] as String),
    );
    _tool(
      'aib_list_agent_configs',
      'Agent configs (arms) with their header comment, blocks and hash. Derived arms are named experiments/<name>.',
      Schema.object(properties: {'filter': Schema.string(description: 'Substring to match anywhere in the entry.')}),
      (args) => {'configs': workspace.listAgentConfigs(filter: args['filter'] as String?)},
    );
    _tool(
      'aib_read_agent_config',
      'One agent config: its YAML, the parsed config, and per-block hashes.',
      Schema.object(
        properties: {'name': Schema.string(description: 'Config name as aib_list_agent_configs names it.')},
        required: ['name'],
      ),
      (args) => workspace.readAgentConfig(args['name'] as String),
    );
    _tool(
      'aib_list_runs',
      'Run directories under results/ and experiments/, newest first: suite, agents, repetitions, trace count, whether evaluated.',
      Schema.object(
        properties: {
          'suite': Schema.string(description: 'Suite name as the manifest records it.'),
          'agent': Schema.string(description: 'Substring of an agent id.'),
          'since': Schema.string(description: 'ISO date; runs created before it are left out.'),
        },
      ),
      (args) => {
        'runs': workspace.listRuns(
          suite: args['suite'] as String?,
          agent: args['agent'] as String?,
          since: args['since'] == null ? null : DateTime.parse(args['since'] as String),
        ),
      },
    );
    _tool(
      'aib_describe_run',
      'A run: manifest, config blocks, judge, and which episodes are done, faulted, truncated or missing.',
      Schema.object(properties: {'run': _run}, required: ['run']),
      (args) => workspace.describeRun(args['run'] as String),
    );
    _tool(
      'aib_metrics_catalog',
      'Every metric: name, unit, source (builtin or the provider that adds it), description.',
      Schema.object(
        properties: {'providers': Schema.list(items: Schema.string(), description: 'Only these providers (and builtin).')},
      ),
      (args) {
        final only = _strings(args['providers']);
        return {
          'metrics': [
            for (final metric in _service.metrics())
              if (only.isEmpty || metric.source.startsWith('builtin') || only.any((name) => metric.source.startsWith('--metrics $name')))
                metric.toJson(),
          ],
        };
      },
    );
    _tool(
      'aib_doctor',
      'Preflight: suite loads, Ollama up with the pinned models, API keys present (reported as present or not, never their value).',
      Schema.object(
        properties: {
          'suite': _suite,
          'configs': Schema.list(items: Schema.string(), description: 'Agent config names to check.'),
          'judge': Schema.string(description: 'Judge config name.'),
        },
      ),
      (args) async => (await _service.doctor(
        suite: args['suite'] == null ? null : workspace.suitePath(args['suite'] as String),
        judge: args['judge'] == null ? null : workspace.agentConfigPath(args['judge'] as String),
        agents: [for (final name in _strings(args['configs'])) '$name=${workspace.agentConfigPath(name)}'],
      )).toJson(),
    );

    // Score -----------------------------------------------------------------
    _tool(
      'aib_evaluate',
      'Score a run: aggregates, per-episode verdicts. Without `judge`, rubric verdicts are reused from verdicts.json and '
          'nothing is written; a run that needs a judge and has none stored is refused. With `judge: true` the run is '
          'scored by the judge pinned for its suite, as a job (see aib_job_status); a priced judge needs maxUsd.',
      Schema.object(
        properties: {
          'run': _run,
          'metrics': _metrics,
          'judge': Schema.bool(description: "Score with the suite's pinned judge (a job)."),
          'maxUsd': Schema.num(description: 'Spend cap for a priced judge.'),
        },
        required: ['run'],
      ),
      (args) async {
        final dir = workspace.runDir(args['run'] as String);
        workspace.sandbox.write(dir);
        if (args['judge'] == true) {
          return _job(
            await runs.startJudgedEvaluation(
              runDir: dir,
              metrics: _strings(args['metrics']),
              maxUsd: (args['maxUsd'] as num?)?.toDouble(),
              approve: _approve,
              only: workspace.scoringTasks(dir),
              study: _study?.name,
            ),
          );
        }
        var summary = await _service.evaluate(dir, options: _scoring(args), withoutJudge: .reusePersisted);
        if (workspace.scoringTasks(dir) case final tune?) summary = await restrictSummary(_service, summary, _scoring(args), tune);
        return {...summary.toJson(), 'runDir': workspace.sandbox.relative(dir), 'written': summary.written.map(workspace.sandbox.relative).toList()};
      },
      write: true,
    );
    _tool(
      'aib_report',
      'Render reports into the run directory (md, json, csv, html) and return the Markdown report.',
      Schema.object(
        properties: {
          'run': _run,
          'formats': Schema.list(items: Schema.string(), description: 'Default: md.'),
          'metrics': _metrics,
        },
        required: ['run'],
      ),
      (args) async {
        final dir = workspace.runDir(args['run'] as String);
        workspace.sandbox.write(dir);
        final formats = _strings(args['formats']);
        final outcome = await _service.report(dir, formats: formats.isEmpty ? const ['md'] : formats, options: _scoring(args));
        var markdown = outcome.markdown;
        // The files hold the whole run; what the agent reads is the tuning split.
        if (workspace.scoringTasks(dir) case final tune?) {
          final run = await _service.evaluateRun(dir, options: _scoring(args).only(tune));
          markdown = MarkdownReporter().render(
            RunReportData(manifest: run.manifest, records: run.records, aggregates: run.aggregates, judge: run.judge),
          );
        }
        return {...outcome.toJson(), 'markdown': markdown, 'written': outcome.written.map(workspace.sandbox.relative).toList()};
      },
      write: true,
    );
    _tool(
      'aib_compare',
      'Two runs: paired deltas with 95% bootstrap CIs. Three or more: a sweep ranked on a cost-accuracy frontier. '
          'Refused when the manifests differ in more than `vary` names.',
      Schema.object(
        properties: {
          'runs': Schema.list(items: _run, minItems: 2),
          'vary': Schema.list(
            items: Schema.string(),
            description: 'Manifest paths allowed to differ, as dotted-path globs (`agents.*.metadata.model`, or `model`).',
          ),
          'metrics': _metrics,
        },
        required: ['runs'],
      ),
      (args) async {
        try {
          final dirs = [for (final run in _strings(args['runs'])) workspace.runDir(run)];
          final outcome = await _service.compare(
            dirs,
            options: _scoring(args).only(workspace.scoringTasks(dirs.first)),
            vary: _strings(args['vary']),
          );
          _journal('compare', {
            'runs': _strings(args['runs']),
            'vary': _strings(args['vary']),
            if (outcome is PairComparison) 'significant': outcome.significant,
          });
          // A reader of the result needs the number of tries to correct for them.
          return {...outcome.toJson(), 'markdown': outcome.markdown, 'study': ?_study?.summary()};
        } on UnintendedDifferences catch (e) {
          throw AibError(
            '${e.message}\n${jsonEncode({
              for (final entry in e.differences.entries) entry.key: [for (final d in entry.value) differenceJson(d)],
            })}',
          );
        }
      },
    );
    _tool(
      'aib_route',
      'Score routing deciders against the per-task oracle of an always-local and an always-cloud run, split by language.',
      Schema.object(
        properties: {
          'local': _run,
          'cloud': _run,
          'routed': Schema.list(items: _run, description: 'Routed arms to score.'),
        },
        required: ['local', 'cloud'],
      ),
      (args) async {
        final local = workspace.runDir(args['local'] as String);
        final outcome = await _service.route(
          local: local,
          cloud: workspace.runDir(args['cloud'] as String),
          routed: [for (final run in _strings(args['routed'])) workspace.runDir(run)],
          options: ScoringOptions(metrics: const ['routing'], tasks: workspace.scoringTasks(local)),
        );
        return {...outcome.toJson(), 'markdown': outcome.report.toMarkdown()};
      },
    );
    _tool(
      'aib_selftest',
      "Check a suite's oracles on the mock environment: each reference must pass, stopping at once must not.",
      Schema.object(
        properties: {
          'suite': _suite,
          'reference': Schema.string(description: 'Reference trajectories (ScriptedAgent config), path relative to the checkout.'),
          'tasks': Schema.list(items: Schema.string(), description: 'Only these task ids.'),
        },
        required: ['suite'],
      ),
      (args) async {
        final path = workspace.suitePath(args['suite'] as String);
        final name = _service.validateSuite(path).suite?.name ?? '';
        final tasks = _strings(args['tasks']);
        return (await _service.selftest(
          suite: path,
          reference: args['reference'] == null ? null : workspace.sandbox.read(args['reference'] as String),
          tasks: workspace.tuningTasks(name, tasks.isEmpty ? null : tasks),
        )).toJson();
      },
    );
    _tool(
      'aib_provenance',
      'What a run was, in the fields that decide whether another compares with it; with `against`, what differs.',
      Schema.object(properties: {'run': _run, 'against': _run}, required: ['run']),
      (args) => _service
          .provenance(workspace.runDir(args['run'] as String), against: args['against'] == null ? null : workspace.runDir(args['against'] as String))
          .toJson(),
    );

    // Configure ---------------------------------------------------------------
    _tool(
      'aib_validate_suite',
      'Schema check of a suite: errors, warnings, task count, tags, languages.',
      Schema.object(properties: {'suite': _suite}, required: ['suite']),
      (args) => _service.validateSuite(workspace.suitePath(args['suite'] as String)).toJson()..remove('path'),
    );
    _tool(
      'aib_validate_agent_config',
      'Build an agent config without running it: built or the refusal, block hashes, decision model. Pass a config name or inline YAML.',
      Schema.object(
        properties: {
          'agent': _agent,
          'name': Schema.string(description: 'Config name as aib_list_agent_configs names it.'),
          'yaml': Schema.string(description: 'Inline config YAML.'),
        },
        required: ['agent'],
      ),
      (args) {
        final check = workspace.validateAgentConfig(agent: args['agent'] as String, name: args['name'] as String?, yaml: args['yaml'] as String?);
        return check.toJson()..remove('path');
      },
    );
    _tool(
      'aib_derive_agent_config',
      'Derive a new arm from `base` with a JSON merge patch (RFC 7386) and write it to suites/agents/experiments/<name>.yaml '
          'with a header naming the base, the change and the hypothesis. Refused when the patch changes more than one config '
          'path (a whole added block counts as one), when the result does not build, or when the name exists.',
      Schema.object(
        properties: {
          'base': Schema.string(description: 'Config name of the arm to start from.'),
          'agent': _agent,
          'patch': Schema.object(description: 'JSON merge patch; null removes a key.', additionalProperties: true),
          'name': Schema.string(description: 'Name of the new arm (lowercase, digits, _ . -).'),
          'hypothesis': Schema.string(description: 'What the change should do, and which metric would show it.'),
        },
        required: ['base', 'agent', 'patch', 'name', 'hypothesis'],
      ),
      (args) {
        final derived = workspace.deriveAgentConfig(
          base: args['base'] as String,
          agent: args['agent'] as String,
          patch: args['patch'],
          name: args['name'] as String,
          hypothesis: args['hypothesis'] as String,
        );
        _journal('derive', {'arm': derived['name'], 'base': derived['base'], 'changes': derived['changes'], 'hypothesis': args['hypothesis']});
        return derived;
      },
      write: true,
    );
    _tool(
      'aib_diff_agent_configs',
      'Differences between two arms: by config path, and the manifest paths `aib_compare` would need in `vary` for runs of them.',
      Schema.object(
        properties: {
          'a': Schema.string(description: 'Config name.'),
          'b': Schema.string(description: 'Config name.'),
          'agent': _agent,
        },
        required: ['a', 'b', 'agent'],
      ),
      (args) => workspace.diffAgentConfigs(a: args['a'] as String, b: args['b'] as String, agent: args['agent'] as String),
    );
  }

  void _registerRunTools() {
    final runArgs = {
      'runner': Schema.string(description: 'Runner recipe from aib_mcp.yaml (aib_jobs lists them).'),
      'config': Schema.string(description: 'Agent config name, as aib_list_agent_configs names it.'),
      'agent': _agent,
      'suite': _suite,
      'reps': Schema.int(description: 'Repetitions per task (default: the suite\'s).'),
      'tasks': Schema.list(items: Schema.string(), description: 'Only these task ids (app runners).'),
    };
    _tool(
      'aib_run_estimate',
      'What a run would take: episodes, model hosts, priced models, and — from earlier runs of the same arm, or of its '
          'base — tokens, cost range and wall clock.',
      Schema.object(properties: runArgs, required: ['runner', 'config', 'agent']),
      (args) {
        final recipe = runs.recipe(args['runner'] as String);
        final suite = recipe.suite ?? args['suite'] as String? ?? (throw const AibError('pass `suite`'));
        return runs.estimate(
          configName: args['config'] as String,
          agent: args['agent'] as String,
          suite: suite,
          tasks: workspace.tuningTasks(suite, args['tasks'] == null ? null : _strings(args['tasks'])),
          reps: args['reps'] as int?,
        );
      },
    );
    _tool(
      'aib_run_start',
      'Start a run as a job and return its id at once. Runs on the same model host queue behind each other. Naming an '
          'existing `out` resumes that run (complete episodes are reused). Priced models need maxUsd, an estimate under '
          'it and, above the auto-approve limit, a yes from the person at the client.',
      Schema.object(
        properties: {
          ...runArgs,
          'seed': Schema.int(description: 'Task shuffle seed (in-process runners).'),
          'maxUsd': Schema.num(description: 'Spend cap; the job stops when it is reached.'),
          'out': Schema.string(description: 'Run directory name under results/; an existing one is resumed.'),
        },
        required: ['runner', 'config', 'agent'],
      ),
      (args) async {
        final recipe = runs.recipe(args['runner'] as String);
        final suite = recipe.suite ?? args['suite'] as String?;
        final job = await runs.startRun(
          runner: args['runner'] as String,
          configName: args['config'] as String,
          agent: args['agent'] as String,
          suite: args['suite'] as String?,
          reps: args['reps'] as int?,
          tasks: suite == null ? null : workspace.tuningTasks(suite, args['tasks'] == null ? null : _strings(args['tasks'])),
          seed: args['seed'] as int?,
          maxUsd: (args['maxUsd'] as num?)?.toDouble(),
          out: args['out'] as String?,
          study: _study?.name,
          launcher: _launcher,
          approve: _approve,
        );
        _journal('run', {'arm': args['config'], 'runner': args['runner'], 'job': job.id, 'run': workspace.sandbox.relative(job.runDir!)});
        return _job(job);
      },
      write: true,
    );
    final jobArg = {'job': Schema.string(description: 'Job id.')};
    Job job(Map<String, Object?> args) => jobs[args['job'] as String] ?? (throw AibError('no job "${args['job']}"'));
    _tool(
      'aib_job_status',
      'A job: state, episodes done of planned, spend, run directory, error, and its result once finished.',
      Schema.object(properties: jobArg, required: ['job']),
      (args) => _job(job(args)),
    );
    _tool(
      'aib_job_wait',
      'Wait until a job ends or `seconds` pass (default 60, at most 600), sending progress notifications meanwhile.',
      Schema.object(
        properties: {
          ...jobArg,
          'seconds': Schema.int(description: 'How long to wait.'),
        },
        required: ['job'],
      ),
      (args) async {
        final target = job(args);
        final token = _request.meta?.progressToken;
        final sub = target.changes.listen((_) {
          if (token != null) {
            notifyProgress(
              ProgressNotification(
                progressToken: token,
                progress: target.done,
                total: target.total,
                message: '${target.state.name}: ${target.done}/${target.total} episodes, \$${target.spendUsd.toStringAsFixed(4)}',
              ),
            );
          }
        });
        try {
          await jobs.wait(target, Duration(seconds: ((args['seconds'] as int?) ?? 60).clamp(1, 600)));
        } finally {
          await sub.cancel();
        }
        return _job(target);
      },
    );
    _tool(
      'aib_job_log',
      "The last lines of a job's output.",
      Schema.object(
        properties: {
          ...jobArg,
          'tail': Schema.int(description: 'Lines (default 50).'),
        },
        required: ['job'],
      ),
      (args) {
        final target = job(args);
        // Episode lines name held-out tasks and how they ended.
        if (target.kind == 'holdout') throw const AibError("a holdout job's log is not shown; its result is the holdout score");
        return {'job': args['job'], 'lines': target.tail((args['tail'] as int?) ?? 50)};
      },
    );
    _tool(
      'aib_job_cancel',
      'Stop a job. A cancelled run keeps its directory; start it again with the same `out` to resume.',
      Schema.object(properties: jobArg, required: ['job']),
      (args) => _job(jobs.cancel(args['job'] as String)),
      write: true,
    );
    _tool(
      'aib_jobs',
      'Every job of this server, newest first, and the configured runners and hosts.',
      Schema.object(),
      (_) => {
        'jobs': [for (final j in jobs.jobs.toList().reversed) _job(j)],
        'runners': {
          for (final r in workspace.config.runners.values) r.name: {'kind': r.kind.name, 'suite': ?r.suite},
        },
        'hosts': {
          for (final h in workspace.config.hosts.values) h.name: {'url': h.url, 'concurrency': h.concurrency},
        },
        'spentTodayUsd': jobs.spentToday(),
      },
    );
  }

  void _registerTuneTools() {
    Study study() => _study ?? (throw const AibError('open a study first (aib_study): every try is journaled to it'));

    _tool(
      'aib_study',
      'Open a tuning study (experiments/<name>/journal.jsonl), or reopen one. Derived arms, runs, comparisons, replays '
          'and holdout scores of this session are journaled to it with their hypotheses; comparisons report how many '
          'arms the study has tried.',
      Schema.object(
        properties: {
          'name': Schema.string(description: 'Study name (lowercase, digits, _ . -).'),
          'hypothesis': Schema.string(description: 'What the study sets out to show; required for a new study.'),
        },
        required: ['name'],
      ),
      (args) {
        _study = Study.open(workspace.sandbox.write(Study.directory), args['name'] as String, hypothesis: args['hypothesis'] as String?);
        return _study!.summary()..['journal'] = workspace.sandbox.relative(_study!.file.path);
      },
      write: true,
    );

    _tool(
      'aib_replay_thresholds',
      'Replay a decision threshold from a recorded run instead of re-running it. `route` is exact and needs the '
          'always-local and always-cloud runs that price each route. `completion`, `guard` and `select-*` are '
          'counterfactual, first decision only: episodes where a decision would have gone the other way are counted, not scored.',
      Schema.object(
        properties: {
          'run': _run,
          'decision': Schema.string(description: 'route, completion, guard, select-tools, select-listings, select-rows or select-*.'),
          'thresholds': Schema.list(items: Schema.num(), minItems: 1),
          'local': _run,
          'cloud': _run,
        },
        required: ['run', 'decision', 'thresholds'],
      ),
      (args) async {
        final dir = workspace.runDir(args['run'] as String);
        final tune = workspace.scoringTasks(dir);
        final thresholds = [for (final t in args['thresholds'] as List) (t as num).toDouble()];
        final decision = args['decision'] as String;
        final JsonMap result;
        if (decision == 'route') {
          if (args['local'] == null || args['cloud'] == null) {
            throw const AibError('a route replay needs `local` and `cloud`: the reference runs price each route');
          }
          final options = ScoringOptions(metrics: const ['routing'], tasks: tune);
          // The routed run is read for its routes and p(local) only — the
          // reference runs price the routes — so an unjudged one will do.
          EvaluatedRun routed;
          try {
            routed = await _service.evaluateRun(dir, options: options);
          } on MissingJudge {
            routed = await _service.evaluateRun(dir, options: options, withoutJudge: .scoreAsZero);
          }
          result = ThresholdReplay.route(
            routed: routed,
            local: await _service.evaluateRun(workspace.runDir(args['local'] as String), options: options),
            cloud: await _service.evaluateRun(workspace.runDir(args['cloud'] as String), options: options),
            thresholds: thresholds,
          );
        } else if (decision == 'completion' || decision == 'guard' || decision.startsWith('select-')) {
          EvaluatedRun run;
          var scored = true;
          try {
            run = await _service.evaluateRun(dir, options: ScoringOptions(tasks: tune));
          } on MissingJudge {
            // Decisions replay without scores; the rubrics were never judged.
            run = await _service.evaluateRun(
              dir,
              options: ScoringOptions(tasks: tune),
              withoutJudge: .scoreAsZero,
            );
            scored = false;
          }
          result = ThresholdReplay.decisions(run: run, purpose: decision, thresholds: thresholds, scored: scored);
        } else {
          throw AibError('unknown decision "$decision"');
        }
        _journal('replay', {'run': args['run'], 'decision': decision, 'thresholds': thresholds});
        return result;
      },
    );

    _tool(
      'aib_sweep_start',
      'Sweep one config path over `values`: derives one arm per value from `base` (a value equal to the base uses the '
          'base), runs each on the tuning split, scores them with the pinned judge where the suite needs one, and '
          'finishes with a comparison of all arms. Returns the sweep job; the run jobs queue on their model host.',
      Schema.object(
        properties: {
          'base': Schema.string(description: 'Config name of the arm to sweep from.'),
          'agent': _agent,
          'path': Schema.string(description: 'Dotted config path, e.g. preparation.topK.'),
          'values': Schema.list(minItems: 2, description: 'Values for the path (JSON).'),
          'runner': Schema.string(description: 'Runner recipe.'),
          'suite': _suite,
          'reps': Schema.int(description: 'Repetitions per task.'),
        },
        required: ['base', 'agent', 'path', 'values', 'runner'],
      ),
      (args) async {
        final current = study();
        final base = args['base'] as String;
        final agent = args['agent'] as String;
        final path = args['path'] as String;
        final recipe = runs.recipe(args['runner'] as String);
        final suite = recipe.suite ?? args['suite'] as String? ?? (throw const AibError('pass `suite`'));
        final tasks = workspace.tuningTasks(suite, null);
        final baseConfig = workspace.loadAgentConfig(base);
        final arms = <String>[];
        for (final value in args['values'] as List) {
          final patch = _patchAt(path, value);
          if (configChanges(baseConfig, mergePatch(baseConfig, patch)).isEmpty) {
            arms.add(base);
            continue;
          }
          final name = '${current.name}-$path-${jsonEncode(value)}'.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_.\-]+'), '_');
          final existing = File(p.join(workspace.sandbox.read(AibWorkspace.experimentsDir), '$name.yaml'));
          if (existing.existsSync()) {
            if (jsonEncode(workspace.loadAgentConfig('experiments/$name')) != jsonEncode(mergePatch(baseConfig, patch))) {
              throw AibError('experiments/$name exists with a different config');
            }
          } else {
            final derived = workspace.deriveAgentConfig(
              base: base,
              agent: agent,
              patch: patch,
              name: name,
              hypothesis: 'Sweep of $path in study ${current.name}: $path = ${jsonEncode(value)}.',
            );
            _journal('derive', {'arm': derived['name'], 'base': base, 'changes': derived['changes'], 'sweep': path});
          }
          arms.add('experiments/$name');
        }
        final runJobs = <Job>[];
        for (final arm in arms) {
          final job = await runs.startRun(
            runner: args['runner'] as String,
            configName: arm,
            agent: agent,
            suite: args['suite'] as String?,
            reps: args['reps'] as int?,
            tasks: tasks,
            study: current.name,
            launcher: _launcher,
            approve: _approve,
          );
          _journal('run', {'arm': arm, 'runner': args['runner'], 'job': job.id, 'run': workspace.sandbox.relative(job.runDir!), 'sweep': path});
          runJobs.add(job);
        }
        final vary = {
          for (final arm in arms.skip(1)) ...workspace.diffAgentConfigs(a: arms.first, b: arm, agent: agent)['vary'] as List? ?? const [],
        };
        final sweep = Job(
          id: jobs.newId(),
          kind: 'sweep',
          label: 'sweep $path over ${arms.length} arms',
          hosts: const {},
          study: current.name,
          total: runJobs.length,
        );
        jobs.submit(sweep, (sweep) async {
          Future<void> await_(Job job) async {
            while (!job.state.isFinal) {
              if (sweep.isCancelling) {
                jobs.cancel(job.id);
              }
              await jobs.wait(job, const Duration(seconds: 5));
            }
            if (job.state != .succeeded) throw AibError('${job.label}: ${job.state.name}${job.error == null ? '' : ' (${job.error})'}');
          }

          for (final job in runJobs) {
            await await_(job);
            sweep.progress(done: sweep.done + 1);
          }
          final dirs = [for (final job in runJobs) job.runDir!];
          final loaded = _service.validateSuite(workspace.suitePath(suite)).suite!;
          if (AibService.needsJudge(loaded)) {
            for (final dir in dirs) {
              await await_(await runs.startJudgedEvaluation(runDir: dir, study: current.name, approve: _approve));
            }
          }
          final outcome = await _service.compare(
            dirs,
            options: ScoringOptions(tasks: tasks?.toSet()),
            vary: [...vary.map((v) => '$v')],
          );
          _journal('compare', {
            'runs': [for (final d in dirs) workspace.sandbox.relative(d)],
            'sweep': path,
          });
          return {...outcome.toJson(), 'arms': arms, 'markdown': outcome.markdown, 'study': current.summary()};
        });
        return {
          ..._job(sweep),
          'arms': arms,
          'runJobs': [for (final j in runJobs) j.id],
        };
      },
      write: true,
    );

    _tool(
      'aib_holdout_score',
      "Score an arm on the suite's holdout: a person approves every call, the arm runs on the held-out tasks as a job, "
          'and only the suite-level score comes back. The call and the score are journaled to the open study.',
      Schema.object(
        properties: {
          'config': Schema.string(description: 'Config name of the arm.'),
          'agent': _agent,
          'runner': Schema.string(description: 'Runner recipe.'),
          'suite': _suite,
          'reps': Schema.int(description: 'Repetitions per task.'),
          'maxUsd': Schema.num(description: 'Spend cap for priced models.'),
        },
        required: ['config', 'agent', 'runner'],
      ),
      (args) async {
        final current = study();
        final recipe = runs.recipe(args['runner'] as String);
        final suite = recipe.suite ?? args['suite'] as String? ?? (throw const AibError('pass `suite`'));
        final split = workspace.split(suite) ?? (throw AibError('$suite has no holdout (${workspace.config.splits}/$suite.yaml)'));
        final config = args['config'] as String;
        final tried = current.summary();
        final message =
            'Score $config on the holdout of $suite (${split.holdout.length} tasks)? Study ${current.name} has derived '
            '${tried['armsDerived']} arm(s) and scored the holdout ${tried['holdoutScores']} time(s) before.';
        if (!supportsElicitation) {
          throw const AibError('a holdout score needs a person\'s approval, and this client cannot be asked (no elicitation)');
        }
        if (!await _approve(message)) throw AibError('not approved: $message');
        current.record('holdout', {'arm': config, 'suite': suite, 'approvedBy': clientInfo.name});
        final loaded = _service.validateSuite(workspace.suitePath(suite)).suite!;
        final judge = AibService.needsJudge(loaded)
            ? workspace.agentConfigPath(workspace.config.judges[suite] ?? (throw AibError('no judge is pinned for $suite (aib_mcp.yaml `judges:`)')))
            : null;
        final job = await runs.startRun(
          runner: args['runner'] as String,
          configName: config,
          agent: args['agent'] as String,
          suite: args['suite'] as String?,
          reps: args['reps'] as int?,
          tasks: split.holdout.toList()..sort(),
          maxUsd: (args['maxUsd'] as num?)?.toDouble(),
          out: '${current.name}-holdout-${config.replaceAll('/', '-')}-${DateTime.now().millisecondsSinceEpoch}',
          study: current.name,
          kind: 'holdout',
          launcher: _launcher,
          approve: _approve,
          then: (job, outDir) async {
            final summary = await runIsolate(job, evaluateWork(outDir, judge, const []));
            // The suite-level rows only: per-task holdout results would be a
            // map of what to tune next.
            final score = [
              for (final row in summary?['aggregates'] as List? ?? const [])
                if (asJsonMap(row)['taskId'] == '*') asJsonMap(row),
            ];
            current.record('holdout-result', {'arm': config, 'run': workspace.sandbox.relative(outDir), 'score': score});
            return {'holdout': score, 'episodes': summary?['episodes']};
          },
        );
        return _job(job);
      },
      write: true,
    );
  }

  /// `a.b.c` = [value] as a merge patch.
  static JsonMap _patchAt(String path, Object? value) {
    final keys = path.split('.');
    Object? node = value;
    for (final key in keys.reversed) {
      node = {key: node};
    }
    return asJsonMap(node);
  }

  // Resources

  /// Trace lines per page of `aib://runs/{run}/episodes/{episode}/trace`.
  static const tracePageLines = 200;

  void _registerResources() {
    void template(String uriTemplate, String name, String description, FutureOr<ReadResourceResult?> Function(Uri uri) read, {String? mimeType}) {
      addResourceTemplate(ResourceTemplate(uriTemplate: uriTemplate, name: name, description: description, mimeType: mimeType), (request) {
        final uri = Uri.parse(request.uri);
        return uri.scheme == 'aib' ? read(uri) : null;
      });
    }

    ReadResourceResult text(Uri uri, String text, {String mimeType = 'text/plain'}) => ReadResourceResult(
      contents: [TextResourceContents(uri: '$uri', text: text, mimeType: mimeType)],
    );

    template('aib://suites/{name}', 'suite', 'A suite as aib_describe_suite returns it: tasks without ground truth.', (uri) {
      if (uri.host != 'suites') return null;
      return text(uri, jsonEncode(workspace.describeSuite(_segments(uri).single)), mimeType: 'application/json');
    }, mimeType: 'application/json');

    template('aib://agents/{name}', 'agent config', 'An agent config YAML; derived arms are experiments/<name>.', (uri) {
      if (uri.host != 'agents') return null;
      return text(uri, File(workspace.agentConfigPath(_segments(uri).join('/'))).readAsStringSync(), mimeType: 'application/yaml');
    }, mimeType: 'application/yaml');

    // Run ids are paths (`results/demo`), so a run URI carries one path and
    // a known suffix; the path may arrive encoded or not.
    ({String dir, List<String> rest})? run(Uri uri, List<String> suffix) {
      if (uri.host != 'runs') return null;
      final segments = _segments(uri);
      final at = segments.length - suffix.length;
      if (at < 1) return null;
      for (var i = 0; i < suffix.length; i++) {
        if (suffix[i] != '*' && segments[at + i] != suffix[i]) return null;
      }
      return (dir: workspace.runDir(segments.take(at).join('/')), rest: segments.skip(at).toList());
    }

    String runFile(String dir, String name) {
      final file = File(p.join(dir, name));
      if (!file.existsSync()) throw AibError('the run has no $name');
      return file.readAsStringSync();
    }

    template('aib://runs/{run}/manifest', 'run manifest', 'run_manifest.json of a run.', (uri) {
      final match = run(uri, ['manifest']);
      return match == null ? null : text(uri, runFile(match.dir, RunStore.manifestFile), mimeType: 'application/json');
    }, mimeType: 'application/json');

    void noHoldout(String dir, String what) {
      if (workspace.scoringTasks(dir) != null) throw AibError('the suite has a holdout, which $what would show; use aib_report / aib_evaluate');
    }

    template('aib://runs/{run}/report.md', 'run report', 'report.md of a run (render it with aib_report).', (uri) {
      final match = run(uri, ['report.md']);
      if (match != null) noHoldout(match.dir, 'report.md');
      return match == null ? null : text(uri, runFile(match.dir, 'report.md'), mimeType: 'text/markdown');
    }, mimeType: 'text/markdown');

    template('aib://runs/{run}/verdicts', 'run verdicts', 'verdicts.json of an evaluated run.', (uri) {
      final match = run(uri, ['verdicts']);
      if (match != null) noHoldout(match.dir, 'verdicts.json');
      return match == null ? null : text(uri, runFile(match.dir, RunStore.verdictsFile), mimeType: 'application/json');
    }, mimeType: 'application/json');

    template(
      'aib://runs/{run}/episodes/{episode}/trace',
      'episode trace',
      'An episode trace as JSONL, $tracePageLines events per page (?page=N); the last line names the next page.',
      (uri) {
        final match = run(uri, ['episodes', '*', 'trace']);
        if (match == null) return null;
        final episode = match.rest[1];
        if (!RegExp(r'^[A-Za-z0-9_.\-]+$').hasMatch(episode)) throw AibError('"$episode" is not an episode id');
        final lines = const LineSplitter().convert(runFile(match.dir, p.join(RunStore.tracesDir, '$episode.jsonl')));
        final tune = workspace.scoringTasks(match.dir);
        final meta = lines
            .where((l) => l.contains('"episode.meta"'))
            .map((l) => asJsonMap(jsonDecode(l)))
            .where((e) => e['type'] == 'episode.meta')
            .firstOrNull;
        final task = asJsonMap(meta?['data'])['taskId'];
        if (tune != null && !tune.contains(task)) throw AibError('$episode is a held-out episode');
        final pages = (lines.length / tracePageLines).ceil().clamp(1, 1 << 30);
        final page = int.tryParse(uri.queryParameters['page'] ?? '') ?? 1;
        if (page < 1 || page > pages) throw AibError('page $page of $pages');
        final slice = lines.skip((page - 1) * tracePageLines).take(tracePageLines);
        final next = page < pages ? uri.replace(queryParameters: {'page': '${page + 1}'}) : null;
        return text(
          uri,
          [
            ...slice,
            jsonEncode({'_page': page, '_pages': pages, '_next': ?next?.toString()}),
          ].join('\n'),
          mimeType: 'application/jsonl',
        );
      },
      mimeType: 'application/jsonl',
    );

    template('aib://docs/{path}', 'doc', 'A Markdown file under docs/ (ADRs, findings, plans).', (uri) {
      if (uri.host != 'docs') return null;
      final path = _segments(uri).join('/');
      final resolved = workspace.sandbox.read(p.join('docs', path));
      if (!p.isWithin(workspace.sandbox.read('docs'), resolved) || !resolved.endsWith('.md')) throw AibError('$path is not a doc');
      return text(uri, File(resolved).readAsStringSync(), mimeType: 'text/markdown');
    }, mimeType: 'text/markdown');
  }

  /// Path segments of an `aib://` URI, each decoded; an encoded run path
  /// (`results%2Fdemo`) splits like an unencoded one.
  static List<String> _segments(Uri uri) => [
    for (final segment in uri.pathSegments)
      for (final part in Uri.decodeComponent(segment).split('/'))
        if (part.isNotEmpty) part,
  ];
}
