import 'dart:math' as math;

import 'package:aib_core/ports.dart';

import 'llm_client.dart';
import 'llm_http.dart';

/// Seeded LLM failures: the model side of the chain, which channel faults never
/// reach.
///
/// Injected **beneath the retry policy**, the way a real outage arrives: a
/// retryable kind is retried with the configured back-off, drawing again on
/// every attempt, and only a fault that survives every attempt reaches
/// `ToolLoopAgent`. A non-retryable kind fails at once.
///
/// The draw hashes seed, the request's last message, how often that request was
/// sent and the attempt, so a trajectory meets the same faults in any episode
/// order.
base class FaultInjectingLlmClient implements LlmClient, LlmStreamingClient, LlmWarmUp, LlmPrefixWarmUp, LlmModelIdentity, LlmStructuredOutput {
  FaultInjectingLlmClient._(this.inner, this.seed, this.failureRate, this.kind, this.retryPolicy);

  /// [inner] with the `faults:` block applied; [inner] itself without a rate.
  /// [retryPolicy] is the `llm.retry` block the injected faults obey.
  static LlmClient wrap(LlmClient inner, JsonMap faults, {LlmRetryPolicy retryPolicy = const LlmRetryPolicy()}) {
    final rate = (faults['llmFailureRate'] as num?)?.toDouble() ?? 0;
    if (rate <= 0) return inner;
    final seed = (faults['seed'] as num?)?.toInt() ?? 1;
    final kind = LlmErrorKind.values.byName(faults['kind'] as String? ?? 'transport');
    return inner is LlmContextWindow
        ? _WindowedFaults(inner, seed, rate, kind, retryPolicy)
        : FaultInjectingLlmClient._(inner, seed, rate, kind, retryPolicy);
  }

  final LlmClient inner;
  final int seed;
  final double failureRate;
  final LlmErrorKind kind;
  final LlmRetryPolicy retryPolicy;
  final Map<String, int> _sends = {};

  @override
  String get model => inner.model;

  @override
  bool get supportsResponseSchema => inner.honoursResponseSchema;

  @override
  Future<void> warmUp() async {
    if (inner case final LlmWarmUp warmable) await warmable.warmUp();
  }

  /// Passed through without faults: it produces nothing the agent reads.
  @override
  Future<void> warmPrefix(LlmRequest request) async {
    if (inner case final LlmPrefixWarmUp warmable) await warmable.warmPrefix(request);
  }

  @override
  Future<JsonMap> modelIdentity() => inner.identify();

  @override
  Future<LlmResponse> complete(LlmRequest request, {CancellationToken? cancellation}) =>
      _withFaults(request, cancellation, () => inner.complete(request, cancellation: cancellation));

  /// Streams when [inner] can; otherwise answers in one piece.
  @override
  Future<LlmResponse> completeStreaming(LlmRequest request, {required void Function(String delta) onTextDelta, CancellationToken? cancellation}) =>
      _withFaults(
        request,
        cancellation,
        () => switch (inner) {
          final LlmStreamingClient streaming => streaming.completeStreaming(request, onTextDelta: onTextDelta, cancellation: cancellation),
          final client => client.complete(request, cancellation: cancellation),
        },
      );

  Future<LlmResponse> _withFaults(LlmRequest request, CancellationToken? cancellation, Future<LlmResponse> Function() send) async {
    final last = request.messages.isEmpty ? '' : request.messages.last.content;
    final key = '${request.messages.length}:$last';
    final sent = _sends.update(key, (n) => n + 1, ifAbsent: () => 0);
    var backoff = retryPolicy.initialBackoff;
    for (var attempt = 0; ; attempt++) {
      cancellation?.throwIfCancelled();
      if (stableUnitDraw('$seed:$sent:$attempt:$key') >= failureRate) {
        return send();
      }
      final fault = LlmClientException('Injected ${kind.name} failure', kind: kind);
      if (!fault.isRetryable || attempt >= retryPolicy.maxAttempts - 1) {
        throw fault;
      }
      await Future.any([Future<void>.delayed(backoff), if (cancellation != null) cancellation.whenCancelled]);
      backoff = Duration(milliseconds: math.min(backoff.inMilliseconds * 2, retryPolicy.maxBackoff.inMilliseconds));
    }
  }
}

final class _WindowedFaults extends FaultInjectingLlmClient implements LlmContextWindow {
  _WindowedFaults(super.inner, super.seed, super.failureRate, super.kind, super.retryPolicy) : super._();

  @override
  int get contextTokens => (inner as LlmContextWindow).contextTokens;
}
