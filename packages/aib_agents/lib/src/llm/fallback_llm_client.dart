import 'package:aib_core/ports.dart';

import 'llm_client.dart';

/// A chain of models: the first answers, and on an infrastructure error that
/// survived its own retries the next one does instead of the episode
/// aborting.
///
/// ```yaml
/// llm:
///   provider: anthropic
///   model: claude-sonnet-5
///   fallback:
///     - {provider: azure, deployment: sysco-gpt5, resourceUrl: …}
///     - {provider: ollama, model: gemma4:26b}
///   fallbackOn: [transport, server, rateLimit, timeout]   # the default
/// ```
///
/// Only what is not the model's fault moves down the chain: a context
/// overflow or a rejected request would fail the same way on the next model
/// and is the agent's finding, not an outage. [model] is the model that
/// answered the last call, so a decision is priced at the model it was billed
/// by, and [takeFallbacks] says which models failed first.
base class FallbackLlmClient
    implements LlmClient, LlmStreamingClient, LlmWarmUp, LlmPrefixWarmUp, LlmModelIdentity, LlmStructuredOutput, LlmFallbackReport {
  FallbackLlmClient(this.chain, {this.on = defaultOn}) {
    if (chain.length < 2) throw ArgumentError('a fallback chain needs at least two models');
  }

  /// The error kinds that move to the next model.
  static const defaultOn = {LlmErrorKind.transport, LlmErrorKind.server, LlmErrorKind.rateLimit, LlmErrorKind.timeout};

  final List<LlmClient> chain;
  final Set<LlmErrorKind> on;

  LlmClient? _answered;
  final List<String> _fallbacks = [];

  @override
  String get model => (_answered ?? chain.first).model;

  @override
  List<String> takeFallbacks() {
    final taken = List.of(_fallbacks);
    _fallbacks.clear();
    return taken;
  }

  /// Every model of the chain has to honour a response schema, or a fallback
  /// would answer unconstrained what was asked constrained.
  @override
  bool get supportsResponseSchema => chain.every((client) => client.honoursResponseSchema);

  /// Only the first model: the others are loaded when an outage reaches them.
  @override
  Future<void> warmUp() async {
    if (chain.first case final LlmWarmUp warmable) await warmable.warmUp();
  }

  @override
  Future<void> warmPrefix(LlmRequest request) async {
    if (chain.first case final LlmPrefixWarmUp warmable) await warmable.warmPrefix(request);
  }

  @override
  Future<JsonMap> modelIdentity() async {
    return {
      ...await chain.first.identify(),
      'fallback': [for (final client in chain.skip(1)) await client.identify()],
      'fallbackOn': [for (final kind in on) kind.name],
    };
  }

  @override
  Future<LlmResponse> complete(LlmRequest request, {CancellationToken? cancellation}) =>
      _down((client) => client.complete(request, cancellation: cancellation));

  @override
  Future<LlmResponse> completeStreaming(LlmRequest request, {required void Function(String delta) onTextDelta, CancellationToken? cancellation}) =>
      _down(
        (client) => client is LlmStreamingClient
            ? client.completeStreaming(request, onTextDelta: onTextDelta, cancellation: cancellation)
            : client.complete(request, cancellation: cancellation),
      );

  Future<LlmResponse> _down(Future<LlmResponse> Function(LlmClient client) send) async {
    _fallbacks.clear();
    for (final (index, client) in chain.indexed) {
      try {
        final response = await send(client);
        _answered = client;
        return response.model.isEmpty ? response.withModel(client.model) : response;
      } on LlmClientException catch (e) {
        if (!on.contains(e.kind) || index == chain.length - 1) rethrow;
        _fallbacks.add('${client.model}: ${e.kind.name}');
      }
    }
    throw StateError('unreachable');
  }
}
