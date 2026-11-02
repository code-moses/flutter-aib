import 'trace.dart';
import 'trace_observer.dart';

/// Buffers an episode's events and hands them to [sink] as JSONL when it ends.
///
/// Encodes its own buffer rather than the trace [onEpisodeEnd] receives:
/// behind a [TraceObservers] redactor only [onEvent] sees redacted events.
final class JsonlTraceObserver implements TraceObserver {
  JsonlTraceObserver(this.sink, {this.maxEvents = 2000});

  /// Called once per episode, synchronously; slow work belongs behind it.
  final void Function(EpisodeMeta meta, String jsonl) sink;

  /// Events past this are dropped, except `episode.end`.
  final int maxEvents;

  final Map<String, List<TraceEvent>> _buffers = {};
  final Map<String, int> _dropped = {};

  @override
  void onEvent(EpisodeMeta meta, TraceEvent event) {
    final buffer = _buffers.putIfAbsent(meta.episodeId, () => []);
    if (buffer.length < maxEvents || event.type == TraceEventTypes.episodeEnd) {
      buffer.add(event);
    } else {
      _dropped.update(meta.episodeId, (n) => n + 1, ifAbsent: () => 1);
    }
  }

  @override
  void onEpisodeEnd(EpisodeMeta meta, EpisodeTrace trace) {
    final events = _buffers.remove(meta.episodeId) ?? const <TraceEvent>[];
    final dropped = _dropped.remove(meta.episodeId);
    if (events.isEmpty) return;
    if (dropped != null) {
      final end = events.last.type == TraceEventTypes.episodeEnd ? events.removeLast() : null;
      events.add(TraceEvent(seq: events.last.seq, tUs: events.last.tUs, type: TraceEventTypes.traceTruncated, data: {'dropped': dropped}));
      if (end != null) events.add(end);
    }
    sink(meta, TraceCodec.encode(EpisodeTrace(meta: meta, events: events)));
  }
}
