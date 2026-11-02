import 'package:aib_core/field.dart';
import 'package:test/test.dart';

final _meta = EpisodeMeta(
  runId: 'field',
  episodeId: 'turn-1',
  taskId: 'live',
  agentId: 'hybrid',
  environmentId: 'sysco_mobile',
  repetition: 0,
  startedAt: DateTime.utc(2026, 9, 14),
);

TraceEvent _event(int seq, String type, [Map<String, Object?> data = const {}]) => TraceEvent(seq: seq, tUs: seq * 10, type: type, data: data);

void main() {
  group('JsonlTraceObserver', () {
    test('hands over a trace the evaluator reads back', () {
      final written = <String>[];
      final observer = JsonlTraceObserver((_, jsonl) => written.add(jsonl));

      observer
        ..onEvent(_meta, _event(0, TraceEventTypes.episodeStart))
        ..onEvent(_meta, _event(1, TraceEventTypes.episodeEnd, {'reason': 'done'}))
        ..onEpisodeEnd(_meta, EpisodeTrace(meta: _meta, events: const []));

      final trace = TraceCodec.decode(written.single);
      expect(trace.meta.episodeId, 'turn-1');
      expect(trace.isComplete, isTrue);
    });

    test('encodes what the redactor left, not the trace it is handed', () {
      final written = <String>[];
      final observers = TraceObservers([JsonlTraceObserver((_, jsonl) => written.add(jsonl))], redact: redactPayloadKeys(['Kontoname']));
      final raw = _event(0, TraceEventTypes.envResult, {
        'payload': {'Kontoname': 'Müller GmbH'},
      });

      observers
        ..onEvent(_meta, raw)
        ..onEpisodeEnd(_meta, EpisodeTrace(meta: _meta, events: [raw]));

      expect(written.single, isNot(contains('Müller')));
      expect(written.single, contains('[redacted]'));
    });

    test('past the cap keeps episode.end and says what it dropped', () {
      final written = <String>[];
      final observer = JsonlTraceObserver((_, jsonl) => written.add(jsonl), maxEvents: 2);

      for (var i = 0; i < 5; i++) {
        observer.onEvent(_meta, _event(i, TraceEventTypes.agentEnvelope));
      }
      observer
        ..onEvent(_meta, _event(5, TraceEventTypes.episodeEnd, {'reason': 'done'}))
        ..onEpisodeEnd(_meta, EpisodeTrace(meta: _meta, events: const []));

      final events = TraceCodec.decode(written.single).events;
      expect(events.map((e) => e.type), [
        TraceEventTypes.agentEnvelope,
        TraceEventTypes.agentEnvelope,
        TraceEventTypes.traceTruncated,
        TraceEventTypes.episodeEnd,
      ]);
      expect(events[2].data['dropped'], 3);
    });
  });
}
