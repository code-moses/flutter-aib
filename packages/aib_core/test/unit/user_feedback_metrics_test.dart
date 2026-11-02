import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

EpisodeTrace _trace(String runId, List<String> kinds) => EpisodeTrace(
  meta: EpisodeMeta(
    runId: runId,
    episodeId: 'live-1',
    taskId: 'live',
    agentId: 'hybrid',
    environmentId: 'sysco_mobile',
    repetition: 0,
    startedAt: DateTime.utc(2026, 9, 14),
  ),
  events: [
    const TraceEvent(seq: 0, tUs: 0, type: TraceEventTypes.episodeStart, data: {}),
    const TraceEvent(seq: 1, tUs: 10, type: TraceEventTypes.episodeEnd, data: {'reason': 'done', 'wallClockMs': 1}),
    for (final (i, kind) in kinds.indexed) TraceEvent(seq: 2 + i, tUs: 20 + i, type: TraceEventTypes.userFeedback, data: {'kind': kind}),
  ],
);

Map<String, Object?> _metrics(EpisodeTrace trace) => MetricsRegistry.builtin().computeAll(MetricContext(trace: trace));

void main() {
  test('an undone field turn is a correction and nothing else', () {
    final metrics = _metrics(_trace(fieldRunId, ['undo']));
    expect(metrics['user_correction'], 1);
    expect(metrics['user_reask'], 0);
    expect(metrics['user_stopped'], 0);
    expect(metrics['user_abandoned'], 0);
  });

  test('stopping and asking again are told apart', () {
    final metrics = _metrics(_trace(fieldRunId, ['stop', 'reask']));
    expect(metrics['user_stopped'], 1);
    expect(metrics['user_reask'], 1);
    expect(metrics['user_correction'], 0);
  });

  test('a benchmark episode has nobody to react', () {
    expect(_metrics(_trace('run-1', ['undo']))['user_correction'], isNull);
  });
}
