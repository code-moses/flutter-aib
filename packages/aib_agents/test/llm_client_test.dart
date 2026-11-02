import 'dart:async';

import 'package:aib_agents/agents.dart';
import 'package:test/test.dart';

void main() {
  group('LlmClientException classification', () {
    test('maps status codes to kinds', () {
      LlmErrorKind kindOf(int status, [String body = '']) => LlmClientException.fromHttp(statusCode: status, body: body).kind;

      expect(kindOf(429), LlmErrorKind.rateLimit);
      expect(kindOf(401), LlmErrorKind.auth);
      expect(kindOf(503), LlmErrorKind.server);
      expect(kindOf(400, 'bad json'), LlmErrorKind.badRequest);
    });

    test('recognises a context overflow hiding inside a 400', () {
      final e = LlmClientException.fromHttp(statusCode: 400, body: 'This model\'s maximum context length is 128000 tokens');
      expect(e.kind, LlmErrorKind.contextLength);
      // Retrying an overflow re-sends the same oversized conversation.
      expect(e.isRetryable, isFalse);
    });

    test('rate limits and transport failures are retryable', () {
      expect(const LlmClientException('x', kind: LlmErrorKind.rateLimit).isRetryable, isTrue);
      expect(const LlmClientException('x', kind: LlmErrorKind.auth).isRetryable, isFalse);
    });
  });

  group('retry policy', () {
    test('retries a retryable failure and returns the later success', () async {
      var attempts = 0;
      final result = await withRetries(() async {
        attempts++;
        if (attempts < 3) {
          throw const LlmClientException('busy', kind: LlmErrorKind.rateLimit, retryAfter: Duration.zero);
        }
        return 'ok';
      }, policy: const LlmRetryPolicy(maxAttempts: 3, initialBackoff: Duration.zero));
      expect(result, 'ok');
      expect(attempts, 3);
    });

    test('does not retry what cannot succeed on a retry', () async {
      var attempts = 0;
      await expectLater(
        withRetries(() async {
          attempts++;
          throw const LlmClientException('too long', kind: LlmErrorKind.contextLength);
        }, policy: const LlmRetryPolicy(maxAttempts: 5, initialBackoff: Duration.zero)),
        throwsA(isA<LlmClientException>()),
      );
      expect(attempts, 1);
    });

    test('honours the provider\'s Retry-After over its own backoff', () {
      expect(parseRetryAfter({'retry-after': '7'}), const Duration(seconds: 7));
      expect(parseRetryAfter({}), isNull);
      expect(parseRetryAfter({'retry-after': 'nonsense'}), isNull);
    });

    test('a cancelled call stops instead of running on', () async {
      final token = CancellationToken();
      final future = withRetries(
        () => Completer<String>().future, // never completes
        policy: const LlmRetryPolicy(timeout: Duration(seconds: 30)),
        cancellation: token,
      );
      token.cancel('user closed the assistant');
      await expectLater(future, throwsA(isA<LlmClientException>().having((e) => e.kind, 'kind', LlmErrorKind.cancelled)));
    });

    test('a hung call fails on its own deadline', () async {
      await expectLater(
        withRetries(() => Completer<String>().future, policy: const LlmRetryPolicy(maxAttempts: 1, timeout: Duration(milliseconds: 20))),
        throwsA(isA<LlmClientException>().having((e) => e.kind, 'kind', LlmErrorKind.timeout)),
      );
    });
  });

  group('LlmUsage', () {
    test('adds up across tiers', () {
      const a = LlmUsage(promptTokens: 10, completionTokens: 2, cachedPromptTokens: 8, reasoningTokens: 1);
      final sum = a + a;
      expect(sum.promptTokens, 20);
      expect(sum.cachedPromptTokens, 16);
      expect(sum.reasoningTokens, 2);
    });
  });
}
