import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

Map<String, num?> _metrics(List<Map<String, Object?>> decisions) {
  final trace = EpisodeTrace(
    meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'a', environmentId: 'mock', repetition: 0, startedAt: DateTime(2026)),
    events: [
      for (final (i, decision) in decisions.indexed)
        TraceEvent(
          seq: i,
          tUs: i,
          type: TraceEventTypes.agentEnvelope,
          data: {'seq': i, 'key': 'intents.invoke', 'kind': 'act', 'decision': decision},
        ),
    ],
  );
  return MetricsRegistry.builtin().computeAll(MetricContext(trace: trace));
}

void main() {
  test('a report in line with what was sent is not a discrepancy', () {
    final metrics = _metrics([
      {
        'tokensPrompt': 1000,
        'extra': {'requestChars': 4000},
      },
    ]);

    expect(metrics['token_report_ratio'], 1);
    expect(metrics['token_report_discrepancy'], 0);
  });

  test('a client that reports nothing for a real request is flagged', () {
    final metrics = _metrics([
      {
        'tokensPrompt': 0,
        'extra': {'requestChars': 4000},
      },
    ]);

    expect(metrics['token_report_ratio'], 0);
    expect(metrics['token_report_discrepancy'], 1);
  });

  test('no request size, no verdict on the report', () {
    final metrics = _metrics([
      {'tokensPrompt': 1000},
    ]);

    expect(metrics['token_report_ratio'], isNull);
    expect(metrics['token_report_discrepancy'], isNull);
  });
}
