import 'dart:io';

import '../common/json.dart';
import '../metrics/pricing.dart';
import 'provenance.dart';

/// Complete description of a benchmark run (reproducibility, spec §5.3):
/// suite version + hash, agents, environment, repetitions, seed, task order,
/// platform. Every run is fully described by its manifest.
final class RunManifest {
  const RunManifest({
    required this.runId,
    required this.createdAt,
    required this.suiteName,
    required this.suiteHash,
    this.suitePath,
    required this.agents,
    required this.environmentId,
    this.environmentVersion,
    this.environmentMetadata = const {},
    this.environmentInstructionsHash,
    required this.repetitions,
    required this.seed,
    required this.taskOrder,
    required this.platform,
    this.frameworkVersion = '0.1.0',
    this.extra = const {},
  });

  final String runId;
  final DateTime createdAt;
  final String suiteName;
  final String suiteHash;
  final String? suitePath;

  /// agentId -> manifest/config json.
  final Map<String, JsonMap> agents;
  final String environmentId;

  /// The environment's own version, from its descriptor. The suite hash
  /// describes the questions; this describes what they were asked of. Null when
  /// the environment did not publish one.
  final String? environmentVersion;

  /// Whatever else the environment publishes about itself. The framework
  /// records it and never reads it.
  final JsonMap environmentMetadata;

  /// [EnvironmentDescriptor.instructionsHash] at run start: the instance text
  /// every agent was told (ADR 0018). Part of the experiment, since the same
  /// agent on the same app reads a different prompt when it moves.
  final String? environmentInstructionsHash;

  final int repetitions;
  final int seed;
  final List<String> taskOrder;
  final JsonMap platform;
  final String frameworkVersion;
  final JsonMap extra;

  /// `extra` key carrying the ISO timestamps of every resume of this run
  /// (§5.3: a run must stay fully described by its manifest, including the
  /// fact that it was executed in several sittings).
  static const resumesKey = 'resumes';

  /// `extra` key holding the pinned price table used for `cost_usd`
  /// (§6.3: prices are volatile, so they belong to the run, not the code).
  static const pricingKey = 'pricing';

  /// `extra` key holding per-agent warm-up milliseconds. Absent means the run
  /// was not warmed and its first episode carries the model load time.
  static const warmUpKey = 'warmUpMs';

  /// `extra` key: [SourceRevision] per source (`framework`, `app`, …).
  static const revisionsKey = 'revisions';

  /// `extra` key: what each agent resolved its model to at run start.
  static const modelsKey = 'models';

  /// `extra` key: [TaskSuite.contentHash] — the suite with fixtures and
  /// rubrics resolved, which [suiteHash] (the YAML file) does not cover.
  static const suiteContentHashKey = 'suiteContentHash';

  /// `extra` key: [TaskSuite.taskContentHashes]. A resume compares the tasks
  /// both runs have in common, so re-running a selection of the suite into its
  /// own directory works while an edited fixture is still refused.
  static const suiteTaskContentKey = 'suiteTaskContent';

  /// `extra` key: the repetition count the run was started with, when it
  /// overrode the suite's. [repetitions] alone cannot say: it holds the
  /// suite default otherwise, while a task with its own count runs that.
  static const repetitionsOverrideKey = 'repetitionsOverride';

  /// `extra` key: the [RepetitionOrder] episodes ran in. Absent means
  /// `blocked`.
  static const repetitionOrderKey = 'repetitionOrder';

  /// The [repetitionsOverrideKey] as recorded. Without one, a [repetitions]
  /// that differs from the suite default can only have been an override.
  int? repetitionsOverrideFor(int suiteDefault) =>
      (extra[repetitionsOverrideKey] as num?)?.toInt() ?? (repetitions == suiteDefault ? null : repetitions);

  Map<String, SourceRevision> get revisions => {
    for (final entry in asJsonMap(extra[revisionsKey]).entries) entry.key: SourceRevision.fromJson(asJsonMap(entry.value)),
  };

  List<String> get resumes => (extra[resumesKey] as List? ?? const []).cast<String>();

  /// Price table pinned at execution time; `null` when the run was not
  /// costed, in which case `cost_usd` is absent rather than zero.
  PriceTable? get pricing => extra[pricingKey] == null ? null : PriceTable.fromJson(asJsonMap(extra[pricingKey]));

  /// Copy carrying [values] merged into [extra].
  RunManifest withExtra(JsonMap values) => RunManifest(
    runId: runId,
    createdAt: createdAt,
    suiteName: suiteName,
    suiteHash: suiteHash,
    suitePath: suitePath,
    agents: agents,
    environmentId: environmentId,
    environmentVersion: environmentVersion,
    environmentMetadata: environmentMetadata,
    environmentInstructionsHash: environmentInstructionsHash,
    repetitions: repetitions,
    seed: seed,
    taskOrder: taskOrder,
    platform: platform,
    frameworkVersion: frameworkVersion,
    extra: {...extra, ...values},
  );

  RunManifest withResumeAt(DateTime at) => RunManifest(
    runId: runId,
    createdAt: createdAt,
    suiteName: suiteName,
    suiteHash: suiteHash,
    suitePath: suitePath,
    agents: agents,
    environmentId: environmentId,
    environmentVersion: environmentVersion,
    environmentMetadata: environmentMetadata,
    environmentInstructionsHash: environmentInstructionsHash,
    repetitions: repetitions,
    seed: seed,
    taskOrder: taskOrder,
    platform: platform,
    frameworkVersion: frameworkVersion,
    extra: {
      ...extra,
      resumesKey: [...resumes, at.toIso8601String()],
    },
  );

  /// Reasons why [other] must not be resumed into this configuration; empty
  /// means the two describe the same experiment. Mixing episodes of two
  /// experiments into one result set is something no downstream statistic could
  /// detect.
  List<String> incompatibilitiesWith(RunManifest other) => [
    if (suiteName != other.suiteName) 'suite name: "${other.suiteName}" -> "$suiteName"',
    if (suiteHash != other.suiteHash)
      'suite hash: ${_short(other.suiteHash)} -> ${_short(suiteHash)} '
          '(the suite file changed)',
    for (final id in _tasksWhoseContentMoved(other)) 'task "$id": its fixture, rubric or ground truth changed',
    if (_tasksWhoseContentMoved(other).isEmpty && _contentMoved(other))
      'suite content: ${_short('${other.extra[suiteContentHashKey]}')} -> '
          '${_short('${extra[suiteContentHashKey]}')} '
          '(a fixture or rubric changed)',
    if (!_sameKeys(agents, other.agents))
      'agents: ${other.agents.keys.join(', ')} -> ${agents.keys.join(', ')}'
    else
      // Same ids are not the same agents: a new model, prompt or router
      // under an unchanged id is a different experiment.
      for (final id in agents.keys)
        if (_agentIdentity(agents[id]!) != _agentIdentity(other.agents[id]!)) 'agent "$id": its manifest changed (model, prompt or configuration)',
    if (environmentId != other.environmentId) 'environment: "${other.environmentId}" -> "$environmentId"',
    // Same reason the suite hash is here: an app that changed under a
    // half-finished run makes its two halves two experiments.
    if (environmentVersion != other.environmentVersion)
      'environment version: "${other.environmentVersion}" -> '
          '"$environmentVersion"',
    if (environmentInstructionsHash != other.environmentInstructionsHash)
      'environment instructions: ${other.environmentInstructionsHash} -> '
          '$environmentInstructionsHash',
    if (_frameworkMoved(other))
      'framework: ${other.revisions['framework']!.label} -> '
          '${revisions['framework']!.label}',
    if (repetitions != other.repetitions) 'repetitions: ${other.repetitions} -> $repetitions',
    if (seed != other.seed) 'seed: ${other.seed} -> $seed',
  ];

  bool _frameworkMoved(RunManifest other) {
    final mine = revisions['framework'];
    final theirs = other.revisions['framework'];
    return mine != null && theirs != null && !mine.sameCommitAs(theirs);
  }

  bool _contentMoved(RunManifest other) {
    // Per-task content decides whenever both manifests carry it: the
    // aggregate also moves when a run covers a different *selection* of the
    // suite, which is not a changed experiment.
    if (taskContent.isNotEmpty && other.taskContent.isNotEmpty) return false;
    final mine = extra[suiteContentHashKey];
    final theirs = other.extra[suiteContentHashKey];
    // A manifest without the field cannot say.
    return mine != null && theirs != null && mine != theirs;
  }

  /// [TaskSuite.taskContentHashes] as recorded; empty when the manifest has
  /// none.
  Map<String, String> get taskContent => {for (final entry in asJsonMap(extra[suiteTaskContentKey]).entries) entry.key: '${entry.value}'};

  /// Tasks both runs cover whose resolved content differs.
  List<String> _tasksWhoseContentMoved(RunManifest other) {
    final theirs = other.taskContent;
    return [
      for (final entry in taskContent.entries)
        if (theirs[entry.key] != null && theirs[entry.key] != entry.value) entry.key,
    ]..sort();
  }

  /// What identifies an agent for resuming: its manifest without the prose
  /// description, which is not part of the experiment.
  static String _agentIdentity(JsonMap agent) => stableStringify({...agent}..remove('description'));

  static bool _sameKeys(JsonMap a, JsonMap b) => a.length == b.length && a.keys.every(b.containsKey);

  static String _short(String hash) => hash.length <= 12 ? hash : hash.substring(0, 12);

  static JsonMap currentPlatform() => {
    'dartVersion': Platform.version,
    'operatingSystem': Platform.operatingSystem,
    'operatingSystemVersion': Platform.operatingSystemVersion,
  };

  JsonMap toJson() => {
    'aib': '1.0',
    'runId': runId,
    'createdAt': createdAt.toIso8601String(),
    'suite': {'name': suiteName, 'hash': suiteHash, if (suitePath != null) 'path': suitePath},
    'agents': agents,
    'environment': {
      'id': environmentId,
      if (environmentVersion != null) 'version': environmentVersion,
      if (environmentMetadata.isNotEmpty) 'metadata': environmentMetadata,
      if (environmentInstructionsHash != null) 'instructionsHash': environmentInstructionsHash,
    },
    'repetitions': repetitions,
    'seed': seed,
    'taskOrder': taskOrder,
    'platform': platform,
    'frameworkVersion': frameworkVersion,
    'extra': extra,
  };

  factory RunManifest.fromJson(JsonMap json) {
    final suite = asJsonMap(json['suite']);
    return RunManifest(
      runId: json['runId'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      suiteName: suite['name'] as String,
      suiteHash: suite['hash'] as String? ?? '',
      suitePath: suite['path'] as String?,
      agents: asJsonMap(json['agents']).map((k, v) => MapEntry(k, asJsonMap(v))),
      environmentId: asJsonMap(json['environment'])['id'] as String? ?? '',
      environmentVersion: asJsonMap(json['environment'])['version'] as String?,
      environmentMetadata: asJsonMap(asJsonMap(json['environment'])['metadata']),
      environmentInstructionsHash: asJsonMap(json['environment'])['instructionsHash'] as String?,
      repetitions: (json['repetitions'] as num?)?.toInt() ?? 1,
      seed: (json['seed'] as num?)?.toInt() ?? 0,
      taskOrder: (json['taskOrder'] as List? ?? const []).cast<String>(),
      platform: asJsonMap(json['platform']),
      frameworkVersion: json['frameworkVersion'] as String? ?? 'unknown',
      extra: asJsonMap(json['extra']),
    );
  }
}
