import 'dart:math';

import '../common/json.dart';
import '../metrics/pricing.dart';
import '../ports/agent.dart';
import '../ports/environment.dart';
import '../task/task.dart';
import '../trace/trace.dart';
import '../ports/user_simulator.dart';
import '../trace/trace_observer.dart';
import 'engine.dart';
import 'provenance.dart';
import 'run_manifest.dart';
import 'run_store.dart';

/// The order a task's repetitions run in.
enum RepetitionOrder {
  /// Every repetition of a task back to back, then the next task. Repetitions 2
  /// and later send a prompt a local server's cache answers whole, a latency
  /// the shipped assistant never sees.
  blocked,

  /// Repetition 1 of every task (in the shuffled order), then repetition 2 of
  /// every task, and so on. No two consecutive episodes are the same task, so
  /// each pays the prefill a user's first question pays. The default, because
  /// latency only compares under it.
  interleaved,
}

/// Orchestrates a full benchmark run: suite × agents × repetitions, task
/// order shuffled with a fixed seed (spec §5.3), traces persisted via
/// [RunStore]. Produces raw traces only — evaluation is a separate pass
/// (P6, ADR 0003).
final class BenchmarkRunner {
  BenchmarkRunner({
    required this.suite,
    required this.agents,
    required this.environment,
    required this.store,
    this.repetitionsOverride,
    this.seed = 42,
    String? runId,
    this.onEpisode,
    this.onSkipped,
    this.resume = true,
    this.pricing,
    this.observer,
    this.userSimulator,
    this.onWarmUpFailed,
    this.revisions = const {},
    this.repetitionOrder = .interleaved,
  }) : runId = runId ?? _defaultRunId();

  /// Source revisions to record (`app`, `suites`, …). `framework` is detected
  /// when absent; a Flutter app cannot detect it and must pass it.
  final Map<String, SourceRevision> revisions;

  /// Milliseconds each agent spent warming up; -1 when the warm-up failed
  /// (which is not fatal — the first real call will report the problem).
  final Map<String, int> warmUpMs = {};

  /// [AgentModelIdentity] per agent.
  final Map<String, JsonMap> models = {};

  final TaskSuite suite;
  final Map<String, BenchmarkAgent> agents;
  final BenchmarkEnvironment environment;
  final RunStore store;
  final int? repetitionsOverride;
  final RepetitionOrder repetitionOrder;
  final int seed;
  final String runId;

  /// Progress callback (CLI output).
  final void Function(EpisodeMeta meta, EpisodeRunResult result)? onEpisode;

  /// Called instead of [onEpisode] for episodes reused from a previous run.
  final void Function(EpisodeMeta meta, String endReason)? onSkipped;

  /// Reuse episodes already present in [store] instead of re-executing them
  /// (§5.2). Traces that ended in `frameworkFault` are always re-executed.
  /// Refused when the configuration changed: see
  /// [RunManifest.incompatibilitiesWith].
  final bool resume;

  /// Price table pinned into the manifest so `cost_usd` stays computable —
  /// and correct — years after the prices changed (§6.3).
  final PriceTable? pricing;

  /// Live trace sink, forwarded to the engine.
  final TraceObserver? observer;

  /// The user for tasks that declare `userSimulator`; described in the
  /// manifest.
  final UserSimulator? userSimulator;

  final void Function(String agentId, Object error)? onWarmUpFailed;

  static String _defaultRunId() => 'run-${DateTime.now().toIso8601String().replaceAll(':', '-')}';

  Future<RunManifest> run() async {
    final shuffledTasks = List<TaskSpec>.of(suite.tasks)..shuffle(Random(seed));

    // The whole descriptor, not just the id: the suite hash says what was
    // asked and this says what it was asked of, and a run needs both to be
    // comparable with another (see RunManifest.environmentVersion).
    final descriptor = await environment.describe();
    final previous = resume ? store.readManifestOrNull() : null;
    final framework = revisions['framework'] ?? await SourceRevision.ofPackage('aib_core');
    final allRevisions = {...revisions, 'framework': ?framework};
    var manifest = RunManifest(
      // A resumed run keeps its identity: the episode traces already on disk
      // carry the original runId, and the manifest must keep describing the
      // same experiment (§5.3).
      runId: previous?.runId ?? runId,
      createdAt: previous?.createdAt ?? DateTime.now(),
      suiteName: suite.name,
      suiteHash: suite.sourceHash ?? '',
      suitePath: suite.sourcePath,
      agents: {for (final entry in agents.entries) entry.key: entry.value.manifest.toJson()},
      environmentId: descriptor.environmentId,
      environmentVersion: descriptor.version,
      environmentMetadata: descriptor.metadata,
      environmentInstructionsHash: descriptor.instructionsHash,
      repetitions: repetitionsOverride ?? suite.defaultRepetitions,
      seed: seed,
      taskOrder: shuffledTasks.map((t) => t.id).toList(),
      platform: RunManifest.currentPlatform(),
      frameworkVersion: framework?.label ?? 'unknown',
      extra: {
        for (final entry in previous?.extra.entries ?? const <MapEntry<String, Object?>>[])
          if (entry.key != RunManifest.repetitionsOverrideKey) entry.key: entry.value,
        RunManifest.repetitionsOverrideKey: ?repetitionsOverride,
        RunManifest.repetitionOrderKey: repetitionOrder.name,
        RunManifest.suiteContentHashKey: suite.contentHash,
        RunManifest.suiteTaskContentKey: suite.taskContentHashes,
        if (pricing != null) RunManifest.pricingKey: pricing!.toJson(),
        'userSimulator': ?userSimulator?.describe(),
        RunManifest.revisionsKey: {for (final entry in allRevisions.entries) entry.key: entry.value.toJson()},
      },
    );
    if (previous != null) {
      final incompatibilities = manifest.incompatibilitiesWith(previous);
      if (incompatibilities.isNotEmpty) {
        throw ResumeConflict(previous, incompatibilities);
      }
      manifest = manifest.withResumeAt(DateTime.now());
    }
    store.writeManifest(manifest);

    final engine = BenchmarkEngine(observer: observer, userSimulator: userSimulator);
    for (final agentEntry in agents.entries) {
      // Before the first episode, and recorded so a warmed run can be told from
      // a cold one.
      if (agentEntry.value case final AgentWarmUp warmable) {
        final watch = Stopwatch()..start();
        try {
          await warmable.warmUp();
          warmUpMs[agentEntry.key] = watch.elapsedMilliseconds;
        } catch (e) {
          warmUpMs[agentEntry.key] = -1;
          onWarmUpFailed?.call(agentEntry.key, e);
        }
      }
      if (agentEntry.value case final AgentModelIdentity identified) {
        try {
          models[agentEntry.key] = await identified.modelIdentity();
        } catch (e) {
          models[agentEntry.key] = {'error': '$e'};
        }
      }
      for (final (suffix, task, rep) in _episodeOrder(shuffledTasks)) {
        final meta = EpisodeMeta(
          runId: manifest.runId,
          episodeId: '${episodeId(task.id, agentEntry.key, rep)}$suffix',
          taskId: task.id,
          agentId: agentEntry.key,
          environmentId: descriptor.environmentId,
          repetition: rep,
          startedAt: DateTime.now(),
        );

        if (previous != null) {
          final reuse = _reusableTrace(meta.episodeId);
          if (reuse != null) {
            onSkipped?.call(meta, reuse);
            continue;
          }
        }

        final result = await engine.runEpisode(task: task, agent: agentEntry.value, environment: environment, meta: meta);
        store.writeTrace(result.trace);
        onEpisode?.call(meta, result);
      }
    }

    if (warmUpMs.isNotEmpty || models.isNotEmpty) {
      manifest = manifest.withExtra({if (warmUpMs.isNotEmpty) RunManifest.warmUpKey: warmUpMs, if (models.isNotEmpty) RunManifest.modelsKey: models});
      store.writeManifest(manifest);
    }
    return manifest;
  }

  /// Every episode of one agent as (episode-id suffix, task, repetition), in
  /// [repetitionOrder]. Each task is asked as written, then in each rewording;
  /// a rewording is its own task here, so `interleaved` spreads its repetitions
  /// too.
  List<(String, TaskSpec, int)> _episodeOrder(List<TaskSpec> tasks) {
    final askings = [
      for (final base in tasks)
        for (final asking in <(String, TaskSpec)>[('', base), for (final variant in base.variants) ('__${variant.id}', base.asVariant(variant))])
          (asking.$1, asking.$2, repetitionsOverride ?? suite.repetitionsFor(base)),
    ];
    return switch (repetitionOrder) {
      .blocked => [
        for (final (suffix, task, reps) in askings)
          for (var rep = 1; rep <= reps; rep++) (suffix, task, rep),
      ],
      .interleaved => [
        for (var rep = 1; rep <= askings.fold(0, (most, a) => a.$3 > most ? a.$3 : most); rep++)
          for (final (suffix, task, reps) in askings)
            if (rep <= reps) (suffix, task, rep),
      ],
    };
  }

  /// Termination reason of a persisted episode that may be reused, or `null`
  /// if it has to be (re-)executed: missing, truncated, or a framework fault
  /// (§5.2 — framework faults are repeated, never charged to the agent).
  String? _reusableTrace(String episodeId) {
    final trace = store.readTraceOrNull(episodeId);
    if (trace == null || !trace.isComplete) return null;
    if (trace.endReason == TerminationReason.frameworkFault.name) return null;
    return trace.endReason;
  }

  static String episodeId(String taskId, String agentId, int repetition) {
    String sanitize(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_.\-]'), '_');
    return '${sanitize(taskId)}__${sanitize(agentId)}__rep$repetition';
  }
}

/// Refusal to resume into a run directory that describes a different
/// experiment — mixing those episodes would produce a result set no
/// downstream statistic could tell apart (§5.3).
final class ResumeConflict implements Exception {
  const ResumeConflict(this.existing, this.reasons);

  final RunManifest existing;
  final List<String> reasons;

  @override
  String toString() =>
      'Cannot resume run "${existing.runId}": the configuration changed.\n'
      '  ${reasons.join('\n  ')}\n'
      'Use a fresh output directory, or re-run everything with resume '
      'disabled (aib run --force).';
}

/// Extensible factory registries (P7): agents, environments, evaluators,
/// metrics and reporters are plugged in by name — no case distinctions in
/// the core.
final class Registry<T> {
  final Map<String, T Function(JsonMap config)> _factories = {};

  void register(String name, T Function(JsonMap config) factory) {
    _factories[name] = factory;
  }

  bool contains(String name) => _factories.containsKey(name);

  List<String> get names => _factories.keys.toList()..sort();

  T create(String name, [JsonMap config = const {}]) {
    final factory = _factories[name];
    if (factory == null) {
      throw ArgumentError('No factory registered for "$name" (known: ${names.join(', ')})');
    }
    return factory(config);
  }
}
