import '../common/json.dart';
import 'trace.dart';

/// Receives episode events as they happen, instead of only as a file at the
/// end: the shipped assistant's field traces and the OpenTelemetry exporter
/// need this.
///
/// Observers must not throw and must not block: the engine calls them inside
/// the measured loop, so a slow observer shows up as agent latency. One that
/// needs to do real work should buffer and flush elsewhere.
abstract interface class TraceObserver {
  void onEvent(EpisodeMeta meta, TraceEvent event);

  /// Called once the episode's events are complete.
  void onEpisodeEnd(EpisodeMeta meta, EpisodeTrace trace) {}
}

/// Rewrites events before anyone sees them. Field traces carry customer data
/// and what the user typed; benchmark traces are fixture data and stay
/// untouched. Returning null drops the event entirely.
typedef TraceRedactor = TraceEvent? Function(TraceEvent event);

/// Fans out to several observers and applies a redactor first.
final class TraceObservers implements TraceObserver {
  TraceObservers(this.observers, {this.redact});

  final List<TraceObserver> observers;
  final TraceRedactor? redact;

  @override
  void onEvent(EpisodeMeta meta, TraceEvent event) {
    final redacted = redact == null ? event : redact!(event);
    if (redacted == null) return;
    for (final observer in observers) {
      // An observer is instrumentation. Instrumentation that can end an
      // episode is worse than no instrumentation.
      try {
        observer.onEvent(meta, redacted);
      } catch (_) {}
    }
  }

  @override
  void onEpisodeEnd(EpisodeMeta meta, EpisodeTrace trace) {
    for (final observer in observers) {
      try {
        observer.onEpisodeEnd(meta, trace);
      } catch (_) {}
    }
  }
}

/// Redactor that blanks payload values whose key matches a pattern. Keys are
/// kept so the *shape* of the exchange stays analysable: metrics count
/// envelopes and bytes, not contents.
TraceRedactor redactPayloadKeys(Iterable<Pattern> patterns, {String placeholder = '[redacted]'}) {
  final list = patterns.toList();
  bool matches(String key) => list.any((p) => p.allMatches(key).isNotEmpty);

  Object? scrub(Object? value) => switch (value) {
    Map() => {for (final entry in value.entries) '${entry.key}': matches('${entry.key}') ? placeholder : scrub(entry.value)},
    List() => value.map(scrub).toList(),
    _ => value,
  };

  return (event) => TraceEvent(seq: event.seq, tUs: event.tUs, type: event.type, data: asJsonMap(scrub(event.data)));
}
