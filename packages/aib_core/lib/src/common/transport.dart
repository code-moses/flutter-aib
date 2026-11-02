/// Transport primitives shared by every client that talks to a model:
/// cancellation, error classification and the retry policy.
///
/// In the core because `aib_agents` and `aib_jev` both need them, and the retry
/// policy affects what a run measures (`wall_clock_ms`, `abort_rate`). `http` stays out of the core; `aib_jev` has the shared `postJson`.
library;

import 'dart:async';
import 'dart:math' as math;

/// Cooperative cancellation for in-flight model calls.
///
/// Not `dart:async`'s `CancelableOperation`: this token is passed down to
/// whichever transport the app supplies (dio, a platform channel, an on-device
/// runtime), each with its own cancellation primitive to bridge to.
final class CancellationToken {
  CancellationToken();

  final _completer = Completer<String>();

  bool get isCancelled => _completer.isCompleted;

  /// Completes with the reason when cancelled; never completes otherwise.
  /// Race it against the transport's own future.
  Future<String> get whenCancelled => _completer.future;

  void cancel([String reason = 'cancelled']) {
    if (!_completer.isCompleted) _completer.complete(reason);
  }

  void throwIfCancelled() {
    if (isCancelled) {
      throw const TransportException('cancelled', kind: .cancelled);
    }
  }
}

/// Why a model call failed. These end an episode in `abort`, where a context
/// overflow must stay distinguishable from an agent that gave up.
enum TransportErrorKind {
  /// Provider refused: too many requests. Retryable, usually with a
  /// `Retry-After` the provider supplies.
  rateLimit,

  /// The conversation no longer fits the model's context window. Never
  /// retryable as-is; the agent's observation window is the mitigation.
  contextLength,

  /// Network-level failure. Retryable.
  transport,

  /// Provider-side 5xx. Retryable.
  server,

  /// Missing or rejected credentials. Not retryable.
  auth,

  /// The request itself was malformed or the model rejected a parameter.
  badRequest,

  /// The per-call deadline elapsed.
  timeout,

  /// A [CancellationToken] fired.
  cancelled,

  unknown,
}

/// Transport or API failure of a model provider. The environment kept working,
/// so this is not a framework fault: the episode aborts with a structured
/// reason.
///
/// `aib_agents` exposes this as `LlmClientException`.
final class TransportException implements Exception {
  const TransportException(this.message, {this.statusCode, this.kind = .unknown, this.retryAfter});

  final String message;
  final int? statusCode;
  final TransportErrorKind kind;

  /// Honoured verbatim by the retry policy when the provider sends it;
  /// backing off less than a provider asked for is how a rate limit turns
  /// into a ban.
  final Duration? retryAfter;

  bool get isRetryable => switch (kind) {
    .rateLimit || .transport || .server || .timeout => true,
    _ => false,
  };

  /// Classifies an HTTP failure. Providers differ in wording but agree on
  /// status codes; the body is only consulted for the one case the status
  /// code cannot express (a 400 that is really a context overflow).
  factory TransportException.fromHttp({required int statusCode, required String body, Duration? retryAfter}) {
    final lower = body.toLowerCase();
    final kind = switch (statusCode) {
      429 => TransportErrorKind.rateLimit,
      401 || 403 => TransportErrorKind.auth,
      >= 500 => TransportErrorKind.server,
      400 || 413 || 422 =>
        lower.contains('context length') ||
                lower.contains('context_length') ||
                lower.contains('maximum context') ||
                lower.contains('too many tokens') ||
                lower.contains('prompt is too long')
            ? TransportErrorKind.contextLength
            : TransportErrorKind.badRequest,
      _ => TransportErrorKind.unknown,
    };
    return TransportException(body, statusCode: statusCode, kind: kind, retryAfter: retryAfter);
  }

  // The historical name, because abort reasons and logs already carry it.
  @override
  String toString() => 'LlmClientException(${kind.name}, ${statusCode ?? '-'}): $message';
}

/// How a client reacts to a failing provider. One policy, shared by every
/// adapter (see the library comment for why).
final class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = 3,
    this.initialBackoff = const Duration(milliseconds: 500),
    this.maxBackoff = const Duration(seconds: 30),
    this.timeout = const Duration(seconds: 120),
  });

  /// Total attempts including the first. 1 disables retrying.
  final int maxAttempts;

  final Duration initialBackoff;

  /// Ceiling for the exponential growth. A provider's own `Retry-After` is
  /// honoured even when it exceeds this.
  final Duration maxBackoff;

  /// Deadline for a single attempt. Without it a hung connection is only
  /// noticed by the engine's wall-clock timeout, which cannot stop the request.
  final Duration timeout;

  static const disabled = RetryPolicy(maxAttempts: 1);

  factory RetryPolicy.fromJson(Map<String, Object?> json) => RetryPolicy(
    maxAttempts: (json['maxAttempts'] as num?)?.toInt() ?? 3,
    initialBackoff: Duration(milliseconds: (json['initialBackoffMs'] as num?)?.toInt() ?? 500),
    maxBackoff: Duration(milliseconds: (json['maxBackoffMs'] as num?)?.toInt() ?? 30000),
    timeout: Duration(seconds: (json['timeoutSeconds'] as num?)?.toInt() ?? 120),
  );

  Map<String, Object?> toJson() => {
    'maxAttempts': maxAttempts,
    'initialBackoffMs': initialBackoff.inMilliseconds,
    'maxBackoffMs': maxBackoff.inMilliseconds,
    'timeoutSeconds': timeout.inSeconds,
  };
}

/// Runs [attempt] under [policy], retrying only what is worth retrying and
/// stopping the moment [cancellation] fires.
Future<T> withRetries<T>(Future<T> Function() attempt, {required RetryPolicy policy, CancellationToken? cancellation}) async {
  var backoff = policy.initialBackoff;
  TransportException? last;

  for (var i = 0; i < policy.maxAttempts; i++) {
    cancellation?.throwIfCancelled();
    try {
      return await _race(attempt(), policy.timeout, cancellation);
    } on TransportException catch (e) {
      last = e;
      final isLastAttempt = i == policy.maxAttempts - 1;
      if (!e.isRetryable || isLastAttempt) rethrow;

      // A provider that names a delay knows better than our curve does.
      final delay = e.retryAfter ?? backoff;
      await _sleep(delay, cancellation);
      backoff = Duration(milliseconds: math.min(backoff.inMilliseconds * 2, policy.maxBackoff.inMilliseconds));
    }
  }
  throw last ?? const TransportException('no attempt was made');
}

Future<T> _race<T>(Future<T> future, Duration timeout, CancellationToken? cancellation) async {
  final futures = <Future<T>>[
    future.timeout(timeout, onTimeout: () => throw TransportException('no response within ${timeout.inSeconds}s', kind: .timeout)),
    if (cancellation != null) cancellation.whenCancelled.then((reason) => throw TransportException(reason, kind: .cancelled)),
  ];
  return futures.length == 1 ? futures.first : Future.any(futures);
}

Future<void> _sleep(Duration delay, CancellationToken? cancellation) async {
  if (cancellation == null) return Future<void>.delayed(delay);
  await Future.any([Future<void>.delayed(delay), cancellation.whenCancelled]);
  cancellation.throwIfCancelled();
}

/// Parses a `Retry-After` header in either of its two legal forms (delta
/// seconds or an HTTP date).
Duration? parseRetryAfter(Map<String, String> headers) {
  final raw = headers['retry-after'];
  if (raw == null) return null;
  if (int.tryParse(raw.trim()) case final seconds?) {
    return Duration(seconds: seconds);
  }
  final at = DateTime.tryParse(raw.trim());
  if (at == null) return null;
  final delta = at.difference(DateTime.now().toUtc());
  return delta.isNegative ? Duration.zero : delta;
}
