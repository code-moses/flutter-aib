import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

EpisodeTrace _trace(List<({String key, JsonMap? extra})> envelopes) {
  var seq = 0;
  TraceEvent event(String type, JsonMap data) => TraceEvent(seq: seq++, tUs: seq * 1000, type: type, data: data);
  return EpisodeTrace(
    meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'a', environmentId: 'env', repetition: 1, startedAt: DateTime(2026)),
    events: [
      for (final (i, e) in envelopes.indexed) ...[
        event(TraceEventTypes.agentEnvelope, {
          'seq': i,
          'key': e.key,
          'kind': 'observe',
          'payload': <String, Object?>{},
          'decision': AgentDecision(extra: e.extra).toJson(),
        }),
        event(TraceEventTypes.envResult, {'seq': i, 'status': 'ok'}),
      ],
      event(TraceEventTypes.episodeEnd, {'reason': 'done', 'wallClockMs': 1}),
    ],
  );
}

EpisodeRecord _record(String task, int rep, bool success, List<String> path) => EpisodeRecord(
  runId: 'r',
  episodeId: '$task-$rep',
  taskId: task,
  agentId: 'a',
  repetition: rep,
  verdict: success ? Verdict.success() : Verdict.failure('no'),
  metrics: {'tokens_total': 100 * rep},
  features: {'trajectory': path},
);

void main() {
  test('counters under extra.counters become agent.<name>, summed', () {
    final metrics = MetricsRegistry.builtin().computeAll(
      MetricContext(
        trace: _trace([
          (
            key: 'x',
            extra: {
              'counters': {'prefetched': 3, 'label': 'no'},
            },
          ),
          (
            key: 'y',
            extra: {
              'counters': {'prefetched': 2},
            },
          ),
        ]),
      ),
    );
    expect(metrics['agent.prefetched'], 5);
    expect(metrics.keys, isNot(contains('agent.label')));
  });

  test('tool_surface_size is the mean over requests that reported it', () {
    final metrics = MetricsRegistry.builtin().computeAll(
      MetricContext(
        trace: _trace([
          (key: 'x', extra: {'tools': 4}),
          (key: 'y', extra: null),
          (key: 'z', extra: {'tools': 6}),
        ]),
      ),
    );
    expect(metrics['tool_surface_size'], 5);
  });

  test('a provider adds group metrics per task and for *', () {
    final records = [
      _record('stable', 1, true, ['a', 'b']),
      _record('stable', 2, true, ['a', 'b']),
      _record('flaky', 1, true, ['a', 'b', 'c']),
      _record('flaky', 2, false, ['a', 'x', 'c']),
    ];
    final registry = MetricsRegistry.builtin(providers: [consistencyMetrics]);
    expect(registry.providers, ['consistency']);
    final rows = Aggregator(aggregates: registry.aggregates).aggregate(records);
    double value(String task, String metric) => rows.firstWhere((r) => r.taskId == task && r.metric == metric).mean;

    expect(value('stable', 'outcome_consistency'), 1);
    expect(value('flaky', 'outcome_consistency'), 0);
    expect(value('*', 'outcome_consistency'), 0.5);
    expect(value('flaky', 'trajectory_consistency'), closeTo(2 / 3, 1e-9));
    expect(value('*', 'trajectory_consistency'), closeTo(5 / 6, 1e-9));
  });

  test('without the provider there are no group metrics', () {
    final rows = Aggregator().aggregate([_record('t', 1, true, const [])]);
    expect(rows.map((r) => r.metric), isNot(contains('outcome_consistency')));
  });
}
