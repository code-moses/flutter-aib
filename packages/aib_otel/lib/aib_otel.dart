/// Episode traces as OpenTelemetry spans (L4). A second reader of the event
/// stream; the JSONL trace stays the source of truth.
library;

export 'src/export.dart';
export 'src/otel_trace_observer.dart';
export 'src/semconv.dart';
