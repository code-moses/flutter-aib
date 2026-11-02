import 'dart:convert';

import 'package:aib_core/field.dart';
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' hide GenAi;

import 'semconv.dart';

/// One OpenTelemetry trace per episode: `aib.episode` holding an
/// `invoke_agent` span per decision, each holding the `execute_tool` span of
/// its envelope.
///
/// A decision span opens when the agent gets its turn and closes when its
/// envelope has been handled, so its duration is thinking plus acting.
/// Payloads stay out unless [captureContent].
final class OtelTraceObserver implements TraceObserver {
  OtelTraceObserver({Tracer? tracer, this.captureContent = false}) : _tracer = tracer ?? OTel.tracer();

  final Tracer _tracer;
  final bool captureContent;
  final Map<String, _Episode> _episodes = {};

  @override
  void onEvent(EpisodeMeta meta, TraceEvent event) {
    final data = event.data;
    if (event.type == TraceEventTypes.episodeStart) {
      _episodes[meta.episodeId] = _Episode(
        _tracer,
        _tracer.startSpan(
          Aib.episodeSpan,
          attributes: _attributes({
            Aib.semconvAsOf: GenAi.asOf,
            Aib.runId: meta.runId,
            Aib.episodeId: meta.episodeId,
            Aib.taskId: meta.taskId,
            GenAi.agentName: meta.agentId,
            Aib.environmentId: meta.environmentId,
            Aib.repetition: meta.repetition,
          }),
        ),
        captureContent,
      );
      return;
    }
    final episode = _episodes[meta.episodeId];
    if (episode == null) return;
    switch (event.type) {
      case TraceEventTypes.envDescriptor || TraceEventTypes.userTurn:
        episode.openDecision();
      case TraceEventTypes.agentEnvelope:
        episode.envelope(data);
      case TraceEventTypes.envResult:
        episode.result(data);
      case TraceEventTypes.episodeEnd:
        _episodes.remove(meta.episodeId);
        episode.end(data);
      default:
        episode.root.addEventNow(event.type, _attributes(_scalars(data)));
    }
  }

  @override
  void onEpisodeEnd(EpisodeMeta meta, EpisodeTrace trace) {}
}

final class _Episode {
  _Episode(this.tracer, this.root, this.captureContent);

  final Tracer tracer;
  final Span root;
  final bool captureContent;
  Span? _decision;
  Span? _tool;

  void openDecision() =>
      _decision ??= tracer.startSpan(GenAi.invokeAgent, parentSpan: root, attributes: _attributes({GenAi.operationName: GenAi.invokeAgent}));

  void envelope(Map<String, Object?> data) {
    openDecision();
    final decision = _decision!;
    final key = '${data['key']}';
    final made = _map(data['decision']);
    decision.addAttributes(
      _attributes({
        Aib.envelopeKey: key,
        Aib.envelopeKind: data['kind'],
        Aib.payloadBytes: data['payloadBytes'],
        GenAi.requestModel: made['model'],
        GenAi.inputTokens: made['tokensPrompt'],
        GenAi.outputTokens: made['tokensCompletion'],
        Aib.llmLatencyMs: made['llmLatencyMs'],
        if (captureContent) Aib.payload: jsonEncode(data['payload']),
      }),
    );
    if (key.startsWith('meta.')) {
      decision.end();
      _decision = null;
      return;
    }
    final payload = _map(data['payload']);
    _tool = tracer.startSpan(
      GenAi.executeTool,
      parentSpan: decision,
      attributes: _attributes({
        GenAi.operationName: GenAi.executeTool,
        GenAi.toolName: key == 'intents.invoke' ? payload['intent'] ?? key : key,
        Aib.envelopeKey: key,
      }),
    );
  }

  void result(Map<String, Object?> data) {
    final tool = _tool;
    if (tool != null) {
      tool.addAttributes(
        _attributes({
          Aib.status: data['status'],
          Aib.payloadBytes: data['payloadBytes'],
          Aib.handleMs: data['handleMs'],
          if (captureContent) Aib.payload: jsonEncode(data['payload']),
        }),
      );
      if (data['status'] != 'ok') {
        final code = switch (data['error']) {
          {'code': final code?} => code,
          _ => data['status'],
        };
        tool.setStatus(SpanStatusCode.Error, '$code');
      }
      tool.end();
      _tool = null;
    }
    _decision?.end();
    _decision = null;
    openDecision();
  }

  void end(Map<String, Object?> data) {
    _tool?.end();
    if (_decision case final open?) {
      open.setBoolAttribute(Aib.unfinished, true);
      open.end();
    }
    root.addAttributes(_attributes({Aib.terminationReason: data['reason'], Aib.wallClockMs: data['wallClockMs']}));
    if (data['reason'] == 'frameworkFault') {
      root.setStatus(SpanStatusCode.Error, '${data['message'] ?? ''}');
    }
    root.end();
  }
}

Map<String, Object?> _scalars(Map<String, Object?> data) => {
  for (final entry in data.entries)
    if (entry.value is String || entry.value is num || entry.value is bool) 'aib.${entry.key}': entry.value,
};

/// OTel attributes take no nulls and no nested values.
Attributes _attributes(Map<String, Object?> values) => OTel.attributesFromMap({
  for (final entry in values.entries)
    if (entry.value case final String v)
      entry.key: v
    else if (entry.value case final int v)
      entry.key: v
    else if (entry.value case final double v)
      entry.key: v
    else if (entry.value case final bool v)
      entry.key: v,
});

Map<String, Object?> _map(Object? value) => value is Map ? value.cast<String, Object?>() : const {};
