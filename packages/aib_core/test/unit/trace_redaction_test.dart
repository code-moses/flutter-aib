import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

EpisodeTrace _trace(List<TraceEvent> events) => EpisodeTrace(
  meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'hybrid', environmentId: 'env', repetition: 1, startedAt: DateTime(2026, 9, 3)),
  events: events,
);

void main() {
  group('trace redaction', () {
    test('blanks matching keys and keeps the shape', () {
      final redact = redactPayloadKeys([RegExp('Kontoname'), 'iban']);
      final event = redact(
        TraceEvent(
          seq: 1,
          tUs: 0,
          type: TraceEventTypes.envResult,
          data: {
            'seq': 1,
            'payload': {
              'entries': [
                {'Kontonummer': 'K0123', 'Kontoname': 'Müller GmbH'},
              ],
              'iban': 'AT00',
            },
          },
        ),
      )!;

      final payload = asJsonMap(event.data['payload']);
      expect(payload['iban'], '[redacted]');
      final entry = asJsonMap((payload['entries'] as List).first);
      expect(entry['Kontoname'], '[redacted]');
      // Non-confidential fields stay: the metrics count shape, not content,
      // and a trace with nothing left in it is not evaluable.
      expect(entry['Kontonummer'], 'K0123');
      expect(event.seq, 1);
    });

    test('observers are fanned out to and cannot break the episode', () {
      final good = _RecordingObserver();
      final observers = TraceObservers([_ThrowingObserver(), good]);
      final meta = _trace(const []).meta;
      observers.onEvent(meta, const TraceEvent(seq: 0, tUs: 0, type: 'x', data: {}));
      expect(good.events, hasLength(1));
    });
  });
}

final class _RecordingObserver implements TraceObserver {
  final List<TraceEvent> events = [];

  @override
  void onEvent(EpisodeMeta meta, TraceEvent event) => events.add(event);

  @override
  void onEpisodeEnd(EpisodeMeta meta, EpisodeTrace trace) {}
}

final class _ThrowingObserver implements TraceObserver {
  @override
  void onEvent(EpisodeMeta meta, TraceEvent event) => throw StateError('exporter down');

  @override
  void onEpisodeEnd(EpisodeMeta meta, EpisodeTrace trace) => throw StateError('exporter down');
}
