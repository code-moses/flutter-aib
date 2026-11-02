import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

import 'otel_trace_observer.dart';

/// The SDK set up for a run: batched OTLP/HTTP export.
abstract final class OtelExport {
  static Future<OtelTraceObserver> start(String endpoint, {bool captureContent = false}) async {
    await OTel.initialize(
      serviceName: 'aib',
      spanProcessor: BatchSpanProcessor(OtlpHttpSpanExporter(OtlpHttpExporterConfig(endpoint: endpoint))),
      detectPlatformResources: false,
      enableMetrics: false,
      enableLogs: false,
    );
    return OtelTraceObserver(captureContent: captureContent);
  }

  /// Flushes what is still batched. Call once the run is written.
  static Future<void> shutdown() => OTel.shutdown();
}
