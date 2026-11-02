import 'dart:convert';
import 'dart:io';

import 'package:aib_agents/aib_agents.dart';
import 'package:aib_cli/aib_cli.dart';
import 'package:aib_core/aib_core.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'arms.dart';
import 'config.dart';
import 'sandbox.dart';
import 'splits.dart';
import 'yaml_writer.dart';

/// The checkout as the tools see it: suites, agent configs and runs by name,
/// every path through the [sandbox].
final class AibWorkspace {
  AibWorkspace(this.config, {this.service = const AibService(), DateTime Function()? clock})
    : sandbox = PathSandbox(config.root, config.writable),
      clock = clock ?? DateTime.now;

  final AibMcpConfig config;
  final PathSandbox sandbox;
  final AibService service;
  final DateTime Function() clock;

  static const suitesDir = 'suites';
  static const agentsDir = 'suites/agents';
  static const experimentsDir = 'suites/agents/experiments';
  static const runRoots = ['results', 'experiments'];

  static final _name = RegExp(r'^[a-z0-9][a-z0-9_.\-]*$');

  // Splits

  /// The split of [suite] (by name), or null when it has none.
  SuiteSplit? split(String suite) => SuiteSplit.load(config.root, suite, dir: config.splits);

  /// The tasks of [runDir] a tuning agent may score: the tuning split of its
  /// suite; null when the suite has no split (everything).
  Set<String>? scoringTasks(String runDir) {
    final manifest = RunStore(Directory(runDir)).readManifest();
    return split(manifest.suiteName)?.tune(manifest.taskOrder);
  }

  /// Refuses [tasks] that include held-out ones; defaults to the tuning split.
  List<String>? tuningTasks(String suite, List<String>? tasks) {
    final split = this.split(suite);
    if (split == null) return tasks;
    final held = [...?tasks?.where(split.holdout.contains)];
    if (held.isNotEmpty) {
      throw AibError('${held.join(', ')} ${held.length == 1 ? 'is' : 'are'} held out; score an arm on the holdout with aib_holdout_score');
    }
    if (tasks != null) return tasks;
    final validation = service.validateSuite(suitePath(suite));
    return (validation.suite ?? (throw AibError('Suite invalid:\n  ${validation.errors.join('\n  ')}'))).tasks
        .map((t) => t.id)
        .where((id) => !split.holdout.contains(id))
        .toList();
  }

  // Suites

  /// A suite by name (`todo_v2`) or by path under the checkout.
  String suitePath(String suite) {
    if (suite.endsWith('.yaml') || suite.endsWith('.yml')) return sandbox.read(suite);
    if (!_name.hasMatch(suite)) throw AibError('"$suite" is not a suite name');
    return sandbox.read(p.join(suitesDir, '$suite.yaml'));
  }

  List<JsonMap> listSuites() {
    final dir = Directory(sandbox.read(suitesDir));
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.yaml')).toList()..sort((a, b) => a.path.compareTo(b.path));
    return [
      for (final file in files)
        // A price table sits next to the suites; only task suites are listed.
        if (_isSuite(file)) {'suite': p.basenameWithoutExtension(file.path), ...service.validateSuite(file.path).toJson()..remove('path')},
    ];
  }

  static bool _isSuite(File file) {
    try {
      return '${(loadYaml(file.readAsStringSync()) as Map?)?['schema']}'.startsWith('aib-task');
    } on Object {
      return false;
    }
  }

  /// The tasks of a suite as an agent may see them while tuning: no ground
  /// truth, no criterion configuration, and no held-out task. An agent that
  /// reads the expected final state is training on the answer key.
  JsonMap describeSuite(String suite) {
    final validation = service.validateSuite(suitePath(suite));
    final loaded = validation.suite;
    if (loaded == null) throw AibError('Suite invalid:\n  ${validation.errors.join('\n  ')}');
    final split = this.split(loaded.name);
    return {
      ...suiteSummaryJson(loaded),
      if (split != null) 'split': {'tune': loaded.tasks.length - split.holdout.length, 'holdout': split.holdout.length},
      'tasks': [
        for (final task in loaded.tasks)
          if (split == null || !split.holdout.contains(task.id))
            {
              'id': task.id,
              'title': task.title,
              'instruction': task.instruction,
              'tags': task.tags,
              'language': ?taskLanguage(task),
              'budget': task.budget.toJson(),
              'optimalSteps': ?task.optimalSteps,
              'repetitions': ?task.repetitions,
              'criteria': [for (final c in task.successCriteria) c.type],
            },
      ],
    };
  }

  // Agent configs

  /// An agent config by name: `hybrid_union`, or `experiments/<name>` for a
  /// derived arm.
  String agentConfigPath(String name) {
    if (!RegExp(r'^(experiments/)?[a-z0-9][a-z0-9_.\-]*$').hasMatch(name)) throw AibError('"$name" is not an agent config name');
    final path = sandbox.read(p.join(agentsDir, '$name.yaml'));
    if (!File(path).existsSync()) throw AibError('No agent config "$name" (see aib_list_agent_configs)');
    return path;
  }

  List<JsonMap> listAgentConfigs({String? filter}) {
    final dir = Directory(sandbox.read(agentsDir));
    final files = dir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.yaml')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return [
      for (final file in files)
        if (_describeConfig(file) case final entry when filter == null || jsonEncode(entry).contains(filter)) entry,
    ];
  }

  JsonMap _describeConfig(File file) {
    final name = p.withoutExtension(p.relative(file.path, from: sandbox.read(agentsDir)));
    final text = file.readAsStringSync();
    try {
      final config = asJsonMap(yamlToJson(loadYaml(text)));
      return {
        'name': name,
        'header': headerComment(text),
        'blocks': [for (final entry in config.entries) entry.key],
        'hash': configHash(config),
        'model': ?_llmModel(config),
      };
    } on Object catch (error) {
      return {'name': name, 'header': headerComment(text), 'error': '$error'.split('\n').first};
    }
  }

  static String? _llmModel(JsonMap config) {
    final llm = config['modelRouter'] != null ? null : LlmClientFactory.llmSection(config);
    return (llm?['model'] ?? llm?['deployment']) as String?;
  }

  /// The leading `#` block of a YAML file, without the markers.
  static String headerComment(String text) => [
    for (final line in const LineSplitter().convert(text).takeWhile((l) => l.startsWith('#') || l.trim().isEmpty))
      line.replaceFirst(RegExp(r'^#\s?'), ''),
  ].join('\n').trim();

  JsonMap loadAgentConfig(String name) => Builtins.loadConfig(agentConfigPath(name));

  JsonMap readAgentConfig(String name) {
    final path = agentConfigPath(name);
    final text = File(path).readAsStringSync();
    final config = Builtins.loadConfig(path);
    return {
      'name': name,
      'path': sandbox.relative(path),
      'yaml': text,
      'config': config,
      'hash': configHash(config),
      'blocks': {for (final entry in AgentProfile.otherSections(config).entries) entry.key: configHash(entry.value)},
    };
  }

  /// Validates a named config or inline YAML, built as [agent].
  AgentConfigCheck validateAgentConfig({required String agent, String? name, String? yaml}) {
    if ((name == null) == (yaml == null)) throw const AibError('pass either name or yaml', isUsage: true);
    if (name != null) return service.validateAgentConfig(agent: agent, path: agentConfigPath(name));
    final Object? parsed;
    try {
      parsed = yamlToJson(loadYaml(yaml!));
    } on YamlException catch (e) {
      throw AibError('yaml does not parse: ${e.message}');
    }
    if (parsed is! Map) throw const AibError('yaml is not a mapping');
    return service.validateAgentConfig(agent: agent, config: asJsonMap(parsed));
  }

  /// A new arm from [base] and a JSON merge [patch], written to
  /// `suites/agents/experiments/<name>.yaml` with a header naming the base,
  /// the change and the [hypothesis].
  ///
  /// Refuses a patch that changes nothing or more than
  /// [AibMcpConfig.maxChangedPaths] paths, a config the builder refuses, and
  /// an existing name. Nothing is written on a refusal.
  JsonMap deriveAgentConfig({required String base, required String agent, required Object? patch, required String name, required String hypothesis}) {
    if (!_name.hasMatch(name)) throw AibError('"$name" is not a valid arm name (lowercase letters, digits, _ . -)');
    if (hypothesis.trim().isEmpty) throw const AibError('an arm needs a hypothesis: what should change, and which metric would show it');
    if (patch is! Map) throw const AibError('patch must be a JSON object (RFC 7386 merge patch)');
    final baseConfig = loadAgentConfig(base);
    final derived = asJsonMap(mergePatch(baseConfig, patch));
    final changes = configChanges(baseConfig, derived);
    if (changes.isEmpty) throw AibError('the patch changes nothing against $base');
    if (changes.length > config.maxChangedPaths) {
      throw AibError(
        'the patch changes ${changes.length} paths, at most ${config.maxChangedPaths} allowed — '
        'one change per arm keeps a comparison attributable:\n  ${changes.join('\n  ')}',
      );
    }
    for (final existing in [p.join(agentsDir, '$name.yaml'), p.join(experimentsDir, '$name.yaml')]) {
      if (File(sandbox.read(existing)).existsSync()) throw AibError('an agent config "$name" exists already ($existing); arms are never overwritten');
    }
    final target = sandbox.write(p.join(experimentsDir, '$name.yaml'));
    final check = service.validateAgentConfig(agent: agent, config: derived);
    if (!check.built) throw AibError('the derived config does not build as $agent: ${check.error}');

    final header = derivedHeader(
      base: base,
      agent: agent,
      hypothesis: hypothesis,
      changes: changes,
      agentConfigHash: check.manifest!.metadata['agentConfigHash'] as String?,
      at: clock(),
    );
    Directory(p.dirname(target)).createSync(recursive: true);
    File(target).writeAsStringSync('$header\n${toYaml(derived)}');
    return {
      'name': 'experiments/$name',
      'path': sandbox.relative(target),
      'base': base,
      'changes': [for (final change in changes) change.toJson()],
      'check': check.toJson(),
    };
  }

  /// Two arms' differences: by config path, and by the manifest paths
  /// `aib compare --vary` would name for runs of them.
  JsonMap diffAgentConfigs({required String a, required String b, required String agent}) {
    final configA = loadAgentConfig(a);
    final configB = loadAgentConfig(b);
    final checkA = service.validateAgentConfig(agent: agent, config: configA);
    final checkB = service.validateAgentConfig(agent: agent, config: configB);
    JsonMap projection(AgentConfigCheck check) => {
      'agents': {check.manifest!.agentId: check.manifest!.toJson()..remove('description')},
    };
    final built = checkA.built && checkB.built;
    final left = built ? flattenJsonPaths(projection(checkA)) : const <String, Object?>{};
    final right = built ? flattenJsonPaths(projection(checkB)) : const <String, Object?>{};
    return {
      'a': a,
      'b': b,
      'changes': [for (final change in configChanges(configA, configB)) change.toJson()],
      if (built)
        'vary': [
          for (final path in ({...left.keys, ...right.keys}.toList()..sort()))
            if (jsonEncode(left[path]) != jsonEncode(right[path])) path,
        ]
      else
        'buildErrors': {a: ?checkA.error, b: ?checkB.error},
    };
  }

  // Runs

  /// A run by its path under the checkout (`results/demo`), as
  /// [listRuns] names it. Field traces carry no manifest and are refused:
  /// they may hold real customer data.
  String runDir(String run) {
    final dir = sandbox.read(run);
    if (!File(p.join(dir, RunStore.manifestFile)).existsSync()) {
      throw AibError('$run is not a run directory (no ${RunStore.manifestFile}); field traces are not served');
    }
    return dir;
  }

  List<JsonMap> listRuns({String? suite, String? agent, DateTime? since}) {
    final runs = <JsonMap>[];
    for (final rootName in runRoots) {
      final root = Directory(sandbox.read(rootName));
      if (!root.existsSync()) continue;
      for (final manifestFile in _manifests(root, depth: 4)) {
        final dir = p.dirname(manifestFile.path);
        final RunManifest manifest;
        try {
          manifest = RunStore(Directory(dir)).readManifest();
        } on Object {
          continue;
        }
        if (suite != null && manifest.suiteName != suite) continue;
        if (agent != null && !manifest.agents.keys.any((id) => id.contains(agent))) continue;
        if (since != null && manifest.createdAt.isBefore(since)) continue;
        runs.add(_runSummary(dir, manifest));
      }
    }
    return runs..sort((a, b) => '${b['createdAt']}'.compareTo('${a['createdAt']}'));
  }

  static Iterable<File> _manifests(Directory dir, {required int depth}) sync* {
    final manifest = File(p.join(dir.path, RunStore.manifestFile));
    if (manifest.existsSync()) {
      yield manifest;
      return;
    }
    if (depth == 0) return;
    for (final child in dir.listSync(followLinks: false).whereType<Directory>()) {
      if (p.basename(child.path).startsWith('.')) continue;
      yield* _manifests(child, depth: depth - 1);
    }
  }

  JsonMap _runSummary(String dir, RunManifest manifest) {
    final traces = Directory(p.join(dir, RunStore.tracesDir));
    return {
      'run': sandbox.relative(dir),
      'runId': manifest.runId,
      'createdAt': manifest.createdAt.toIso8601String(),
      'suite': manifest.suiteName,
      'suiteHash': manifest.suiteHash,
      'environment': manifest.environmentId,
      'agents': manifest.agents.keys.toList(),
      'repetitions': manifest.repetitions,
      'traces': traces.existsSync() ? traces.listSync().where((f) => f.path.endsWith('.jsonl')).length : 0,
      'evaluated': File(p.join(dir, RunStore.verdictsFile)).existsSync(),
    };
  }

  /// Manifest, config blocks, and which episodes are done, faulted,
  /// truncated or missing — what a resume would re-execute.
  JsonMap describeRun(String run) {
    final dir = runDir(run);
    final store = RunStore(Directory(dir));
    final manifest = store.readManifest();
    final done = <String>[];
    final faulted = <String>[];
    final truncated = <String>[];
    final traceDir = Directory(p.join(dir, RunStore.tracesDir));
    final ids = traceDir.existsSync()
        ? [for (final f in traceDir.listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl'))) p.basenameWithoutExtension(f.path)]
        : const <String>[];
    for (final id in ids) {
      final trace = store.readTraceOrNull(id);
      if (trace == null || !trace.isComplete) {
        truncated.add(id);
      } else if (trace.endReason == TerminationReason.frameworkFault.name) {
        faulted.add(id);
      } else {
        done.add(id);
      }
    }
    final planned = _plannedEpisodes(manifest);
    final missing = [
      for (final id in planned.ids)
        if (!ids.contains(id)) id,
    ];
    // Held-out episodes are not named: that a task failed is already a hint.
    final tune = split(manifest.suiteName)?.tune(manifest.taskOrder);
    bool shown(String id) => tune == null || tune.any((task) => id.startsWith('${BenchmarkRunner.episodeId(task, '', 0).split('__').first}__'));
    faulted.retainWhere(shown);
    truncated.retainWhere(shown);
    missing.retainWhere(shown);
    return {
      ..._runSummary(dir, manifest),
      'manifest': manifest.toJson()..remove('taskOrder'),
      'tasks': manifest.taskOrder.length,
      'episodes': {
        'planned': planned.ids.length,
        if (!planned.fromSuite) 'plannedFrom': 'manifest (the suite file changed since): a floor',
        'done': done.length,
        'faulted': faulted,
        'truncated': truncated,
        'missing': missing,
      },
      'judge': ?store.readJudgeProvenance()?.toJson(),
    };
  }

  /// Every episode id the run plans, as the runner names them: each task
  /// as written and in each instruction variant, × agent × repetition — and
  /// whether that came from the suite. The variants and a task's own
  /// repetitions live in the suite, not in the manifest; without the suite
  /// file the run was started from (same hash) this falls back to the
  /// manifest's task × agent × repetition, the floor of what it planned.
  ({List<String> ids, bool fromSuite}) _plannedEpisodes(RunManifest manifest) {
    TaskSuite? suite;
    for (final path in [?manifest.suitePath, manifest.suiteName]) {
      try {
        final loaded = service.validateSuite(suitePath(path)).suite;
        if (loaded != null && (manifest.suiteHash.isEmpty || loaded.sourceHash == manifest.suiteHash)) {
          suite = loaded;
          break;
        }
      } on AibError {
        continue;
      }
    }
    final tasks = {for (final task in suite?.tasks ?? const <TaskSpec>[]) task.id: task};
    final override = manifest.repetitionsOverrideFor(suite?.defaultRepetitions ?? manifest.repetitions);
    final ids = [
      for (final taskId in manifest.taskOrder)
        for (final agentId in manifest.agents.keys)
          for (final suffix in ['', for (final variant in tasks[taskId]?.variants ?? const <InstructionVariant>[]) '__${variant.id}'])
            for (var rep = 1; rep <= (tasks[taskId] == null ? manifest.repetitions : override ?? suite!.repetitionsFor(tasks[taskId]!)); rep++)
              '${BenchmarkRunner.episodeId(taskId, agentId, rep)}$suffix',
    ];
    return (ids: ids, fromSuite: suite != null);
  }
}
