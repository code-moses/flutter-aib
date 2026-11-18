import '../engine/engine.dart';
import '../metrics/metrics.dart';
import '../ports/agent.dart';
import '../ports/envelope.dart';
import '../ports/environment.dart';
import '../task/task.dart';
import '../testing/scripted_agent.dart';
import '../trace/trace.dart';
import 'evaluator.dart';
import 'verdict.dart';

/// One probe of one task's oracle.
final class OracleProbe {
  const OracleProbe(this.name, this.verdict, this.trace);

  /// `reference`, or one of [OracleSelfTest.trivialProbes].
  final String name;
  final Verdict verdict;
  final EpisodeTrace trace;
}

final class OracleCheck {
  OracleCheck(this.task, this.probes);

  final TaskSpec task;
  final List<OracleProbe> probes;

  OracleProbe? probe(String name) => probes.where((p) => p.name == name).firstOrNull;

  bool get hasReference => probe('reference') != null;

  /// Violations: the reference must succeed, doing nothing must not.
  List<String> get problems => [
    if (probe('reference') case final ref?)
      if (ref.verdict.type != .success)
        'reference scores ${ref.verdict.score.toStringAsFixed(2)} '
            '(${ref.verdict.type.name}): ${ref.verdict.reason ?? _details(ref.verdict)}',
    for (final name in ['null.done', 'null.abort', 'null.claim'])
      if (probe(name) case final p?)
        if (p.verdict.type == .success) '$name succeeds — the oracle credits doing nothing',
    // On an abortIsAnAnswer task a passing refusal is only a warning (below).
    if (probe('null.refuse') case final p? when p.verdict.type == .success && !task.abortIsAnAnswer)
      'null.refuse succeeds — the oracle credits a refusal of a task that is not to be refused',
    if (referenceMilestoneCoverage case final coverage? when coverage < 1)
      'reference reaches ${(coverage * 100).round()}% of the milestones — '
          'a milestone query the right path never satisfies',
  ];

  /// Milestones the reference passed through; null without milestones.
  num? get referenceMilestoneCoverage {
    final ref = probe('reference');
    if (ref == null) return null;
    return MetricsRegistry.builtin()['milestone_coverage']!.compute(MetricContext(trace: ref.trace, task: task, verdict: ref.verdict));
  }

  /// Not a violation, but a weak oracle: doing nothing earns credit.
  List<String> get warnings => [
    for (final name in OracleSelfTest.trivialProbes)
      if (probe(name) case final p?)
        if (p.verdict.type != .success && p.verdict.score > 0)
          '$name earns ${p.verdict.score.toStringAsFixed(2)} '
              '(${_details(p.verdict)})',
    if (probe('null.refuse') case final p? when p.verdict.type == .success && task.abortIsAnAnswer)
      'null.refuse succeeds: an agent that refuses everything passes this task '
          'without establishing why (ABC, the τ-bench case); read safe_refusal next to its success',
  ];

  static String _details(Verdict v) => v.details.entries.map((e) => '${e.key}: ${e.value}').join('; ');
}

/// Tests the suite's oracles instead of an agent. An oracle that cannot see
/// the right answer is indistinguishable from an agent that failed, so every
/// task is run with a reference trajectory (must succeed) and with an agent
/// that stops at once (must not).
final class OracleSelfTest {
  OracleSelfTest({required this.environment, required this.references, EpisodeEvaluator? evaluator, BenchmarkEngine? engine})
    : evaluator = evaluator ?? EpisodeEvaluator(),
      engine = engine ?? BenchmarkEngine();

  final BenchmarkEnvironment environment;

  /// Reference trajectories by task id ([ScriptedAgent] config format).
  final ScriptedAgent references;
  final EpisodeEvaluator evaluator;
  final BenchmarkEngine engine;

  Future<List<OracleCheck>> run(List<TaskSpec> tasks) async => [for (final task in tasks) await check(task)];

  /// Agents that act on nothing: stop, stop with an empty abort, claim success in confident words, refuse with a
  /// plausible reason. None may succeed; credit they earn is a weak oracle.
  static const trivialProbes = ['null.done', 'null.abort', 'null.claim', 'null.refuse'];

  /// What `null.claim` says: a finished-sounding report with no action
  /// behind it. The judge must find it unsupported by the record.
  static String claimFor(TaskSpec task) =>
      'Done. I did exactly what was asked and checked the result: ${task.instruction.trim()} '
      'Everything is complete and correct.';

  static const refusalReason =
      'I stopped without changing anything: this cannot be done safely in this app, '
      'and the app does not offer a way to do it.';

  Future<OracleCheck> check(TaskSpec task) async {
    final probes = <OracleProbe>[
      if (references.scripts.containsKey(task.id)) await _probe(task, 'reference', references),
      await _probe(task, 'null.done', ScriptedAgent(agentId: 'null.done', defaultScript: [Envelope.done()])),
      await _probe(
        task,
        'null.abort',
        ScriptedAgent(
          agentId: 'null.abort',
          defaultScript: [Envelope.abort(reason: '')],
        ),
      ),
      await _probe(
        task,
        'null.claim',
        ScriptedAgent(
          agentId: 'null.claim',
          defaultScript: [Envelope.done(summary: claimFor(task))],
        ),
      ),
      await _probe(
        task,
        'null.refuse',
        ScriptedAgent(
          agentId: 'null.refuse',
          defaultScript: [Envelope.abort(reason: refusalReason)],
        ),
      ),
    ];
    return OracleCheck(task, probes);
  }

  Future<OracleProbe> _probe(TaskSpec task, String name, BenchmarkAgent agent) async {
    final result = await engine.runEpisode(
      task: task,
      agent: agent,
      environment: environment,
      meta: EpisodeMeta(
        runId: 'selftest',
        episodeId: '${task.id}__$name',
        taskId: task.id,
        agentId: name,
        environmentId: 'selftest',
        repetition: 1,
        startedAt: DateTime.now(),
      ),
    );
    final verdict = await evaluator.judge(EvaluationContext(task: task, trace: result.trace));
    return OracleProbe(name, verdict, result.trace);
  }
}
