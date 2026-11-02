import '../aggregation/aggregator.dart';
import '../evaluation/evaluator.dart';
import '../evaluation/verdict.dart';
import '../metrics/metrics.dart';
import '../task/task.dart';
import '../trace/trace.dart';

/// The repeatable evaluation pass (P6): traces + suite -> verdicts + metrics.
/// Applying a newer metric registry to an old run re-evaluates it without
/// re-execution.
final class RunEvaluation {
  /// Without an [evaluator], `traceAssertion` criteria get the assertion
  /// kinds [metrics]' providers registered.
  RunEvaluation({EpisodeEvaluator? evaluator, MetricsRegistry? metrics})
    : metrics = metrics ?? MetricsRegistry.builtin(),
      evaluator =
          evaluator ??
          EpisodeEvaluator(evaluators: EpisodeEvaluator.defaultEvaluators(assertions: (metrics ?? MetricsRegistry.builtin()).assertions));

  final EpisodeEvaluator evaluator;
  final MetricsRegistry metrics;

  /// A given [verdict] is reused; metrics are always recomputed.
  Future<EpisodeRecord> evaluateEpisode(EpisodeTrace trace, TaskSpec? task, {Verdict? verdict}) async {
    verdict ??= task == null
        ? Verdict.frameworkError('task "${trace.meta.taskId}" not found in suite')
        : await evaluator.judge(EvaluationContext(task: task, trace: trace));
    final context = metrics.contextFor(trace, task: task, verdict: verdict);
    return EpisodeRecord(
      runId: trace.meta.runId,
      episodeId: trace.meta.episodeId,
      taskId: trace.meta.taskId,
      agentId: trace.meta.agentId,
      repetition: trace.meta.repetition,
      verdict: verdict,
      metrics: metrics.computeAll(context),
      features: metrics.computeFeatures(context),
      tags: task?.tags ?? const [],
    );
  }

  /// [verdicts] by episode id are reused instead of re-judged.
  Future<List<EpisodeRecord>> evaluateRun(List<EpisodeTrace> traces, TaskSuite suite, {Map<String, Verdict> verdicts = const {}}) async => [
    for (final trace in traces) await evaluateEpisode(trace, suite.taskById(trace.meta.taskId), verdict: verdicts[trace.meta.episodeId]),
  ];
}
