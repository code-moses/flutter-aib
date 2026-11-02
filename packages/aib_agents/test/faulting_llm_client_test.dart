import 'package:aib_agents/aib_agents.dart';
import 'package:aib_agents/testing.dart';
import 'package:test/test.dart';

void main() {
  LlmRequest request(String text) => LlmRequest(messages: [LlmMessage.user(text)]);
  FakeLlmClient fake() => FakeLlmClient(responses: [for (var i = 0; i < 200; i++) const LlmResponse(text: 'ok')]);
  Future<bool> fails(LlmClient client, String text) => client.complete(request(text)).then((_) => false, onError: (Object _) => true);

  test('a block without a rate leaves the client unwrapped', () {
    final inner = fake();
    expect(FaultInjectingLlmClient.wrap(inner, {'seed': 1}), same(inner));
  });

  const noRetry = LlmRetryPolicy(maxAttempts: 1);
  const quickRetry = LlmRetryPolicy(maxAttempts: 3, initialBackoff: Duration.zero, maxBackoff: Duration.zero);

  test('the same requests meet the same faults', () async {
    Future<List<bool>> run() async {
      final client = FaultInjectingLlmClient.wrap(fake(), {'llmFailureRate': 0.5, 'seed': 7}, retryPolicy: noRetry);
      return [for (var i = 0; i < 40; i++) await fails(client, 'q$i')];
    }

    final first = await run();
    expect(await run(), first);
    expect(first.where((f) => f).length, inInclusiveRange(10, 30));
  });

  test('a failure carries its kind, and a retry draws again', () async {
    final client = FaultInjectingLlmClient.wrap(fake(), {'llmFailureRate': 0.5, 'seed': 3, 'kind': 'server'}, retryPolicy: noRetry);
    var failures = 0;
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        await client.complete(request('same'));
      } on LlmClientException catch (e) {
        expect(e.kind, LlmErrorKind.server);
        failures++;
      }
    }
    expect(failures, inExclusiveRange(0, 20));
  });

  test('a context window survives the wrapper, and only where it was', () {
    final ollama = FaultInjectingLlmClient.wrap(OllamaClient(model: 'qwen3:8b'), {'llmFailureRate': 0.1});
    expect(ollama, isA<LlmContextWindow>());
    expect(FaultInjectingLlmClient.wrap(fake(), {'llmFailureRate': 0.1}), isNot(isA<LlmContextWindow>()));
  });

  test('a retryable fault is retried beneath the policy', () async {
    Future<int> failuresOf(LlmRetryPolicy policy) async {
      final client = FaultInjectingLlmClient.wrap(fake(), {'llmFailureRate': 0.5, 'seed': 11}, retryPolicy: policy);
      var failures = 0;
      for (var i = 0; i < 60; i++) {
        if (await fails(client, 'r$i')) failures++;
      }
      return failures;
    }

    final once = await failuresOf(noRetry);
    final retried = await failuresOf(quickRetry);
    // Three attempts at 0.5 leave about an eighth of the calls failing.
    expect(retried, lessThan(once));
    expect(retried, inInclusiveRange(1, 20));
  });

  test('a fault the policy does not retry fails at once', () async {
    final inner = fake();
    final client = FaultInjectingLlmClient.wrap(inner, {'llmFailureRate': 1, 'kind': 'badRequest'}, retryPolicy: quickRetry);
    expect(await fails(client, 'x'), isTrue);
    expect(inner.requests, isEmpty);
  });
}
