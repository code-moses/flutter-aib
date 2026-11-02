/// Scripted LLM double: lets the full agent stack (prompt building, tool
/// loop, telemetry, envelope mapping) run deterministically without network
/// or API keys — the agent-side counterpart of ScriptedAgent (spec §10).
library;

import 'agents.dart';

export 'package:aib_jev/testing.dart';

final class FakeLlmClient implements LlmClient, LlmStructuredOutput, LlmPrefixWarmUp {
  FakeLlmClient({
    this.model = 'fake-llm',
    this.supportsResponseSchema = false,
    List<LlmResponse> responses = const [],
    this.usagePerCall = const LlmUsage(promptTokens: 100, completionTokens: 20),
    this.delay,
  }) : _responses = List.of(responses);

  @override
  final String model;

  /// Whether this double claims to constrain output to a schema. It records the
  /// request either way, so a test can read `responseSchema` off it.
  @override
  final bool supportsResponseSchema;
  final List<LlmResponse> _responses;
  final LlmUsage usagePerCall;

  /// Optional real-async delay (verifies live-run harness mechanics).
  final Duration? delay;

  /// Every request the agent made — inspectable by tests.
  final List<LlmRequest> requests = [];

  /// Prefixes primed through [LlmPrefixWarmUp], in order.
  final List<LlmRequest> warmedPrefixes = [];

  @override
  Future<void> warmPrefix(LlmRequest request) async => warmedPrefixes.add(request);

  int _calls = 0;

  /// Convenience: a response consisting of tool calls only.
  static LlmResponse calls(List<(String name, JsonMap args)> toolCalls, {String text = ''}) => LlmResponse(
    text: text,
    toolCalls: [for (final (i, call) in toolCalls.indexed) LlmToolCall(id: 'fake-call-$i', name: call.$1, arguments: call.$2)],
  );

  @override
  Future<LlmResponse> complete(LlmRequest request, {CancellationToken? cancellation}) async {
    if (delay != null) await Future<void>.delayed(delay!);
    cancellation?.throwIfCancelled();
    requests.add(request);
    if (_calls >= _responses.length) {
      throw StateError('FakeLlmClient exhausted after ${_responses.length} responses');
    }
    final scripted = _responses[_calls++];
    return LlmResponse(
      text: scripted.text,
      toolCalls: scripted.toolCalls,
      usage: usagePerCall,
      model: model,
      stopReason: scripted.stopReason,
      thinking: scripted.thinking,
    );
  }
}

/// Deterministic vectors from the text alone; records every batch.
final class FakeEmbeddingClient implements EmbeddingClient {
  FakeEmbeddingClient({this.model = 'fake-embedding', this.dimensions = 8});

  @override
  final String model;
  final int dimensions;

  final List<List<String>> batches = [];

  @override
  Future<EmbeddingResponse> embed(List<String> texts, {CancellationToken? cancellation}) async {
    cancellation?.throwIfCancelled();
    batches.add(texts);
    return EmbeddingResponse(
      vectors: [
        for (final text in texts) [for (var i = 0; i < dimensions; i++) text.codeUnits.fold(i + 1, (a, c) => (a * 31 + c) % 1009) / 1009],
      ],
      promptTokens: texts.fold(0, (sum, text) => sum + text.length),
      model: model,
    );
  }
}

/// A [FakeLlmClient] that also streams, so the streaming path can be tested
/// without a model server.
///
/// Text arrives word by word; the response it completes with is the one the
/// non-streaming path would have returned. That equivalence is the point: a
/// streamed episode has to stay comparable to a buffered one.
final class FakeStreamingLlmClient extends FakeLlmClient implements LlmStreamingClient {
  FakeStreamingLlmClient({super.model, super.responses, super.usagePerCall, super.delay});

  /// True once [completeStreaming] was used, so a test can tell which path ran.
  bool didStream = false;

  @override
  Future<LlmResponse> completeStreaming(
    LlmRequest request, {
    required void Function(String delta) onTextDelta,
    CancellationToken? cancellation,
  }) async {
    didStream = true;
    final response = await complete(request, cancellation: cancellation);
    for (final word in response.text.split(RegExp(r'(?<= )'))) {
      if (word.isEmpty) continue;
      cancellation?.throwIfCancelled();
      onTextDelta(word);
    }
    return response;
  }
}
