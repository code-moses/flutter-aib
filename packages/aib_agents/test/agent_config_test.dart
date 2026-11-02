import 'package:aib_agents/agents.dart';
import 'package:aib_agents/testing.dart';
import 'package:aib_core/ports.dart';
import 'package:test/test.dart';

const _task = TaskSpec(
  id: 't1',
  title: 'Phase 0',
  instruction: 'do the thing',
  fixture: FixtureRef(id: 'fx', data: {}),
  budget: Budget(maxSteps: 10, maxWallClockSeconds: 60),
);

const _descriptor = EnvironmentDescriptor(
  environmentId: 'env',
  envelopes: [
    EnvelopeSpec(key: 'intents.catalog', kind: .observe),
    EnvelopeSpec(key: 'intents.invoke', kind: .act),
  ],
);

const _budget = BudgetStatus(stepsUsed: 0, maxSteps: 10, elapsedMs: 0, maxWallClockMs: 60000, tokensUsed: 0);

void main() {
  group('observation window', () {
    test('stubs old tool results but keeps the recent ones', () async {
      final client = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([('observe_tree', {})]),
          FakeLlmClient.calls([('observe_tree', {})]),
          FakeLlmClient.calls([('observe_tree', {})]),
        ],
      );
      final agent = SemanticsAgent(client: client, config: const AgentConfig(observationWindow: 1));
      await agent.startEpisode(_task, _descriptor);

      var result = EnvelopeResult.ok({'tree': 'A' * 200});
      await agent.next(null, _budget); // bootstrap, no LLM call
      for (var i = 0; i < 3; i++) {
        await agent.next(result, _budget);
        result = EnvelopeResult.ok({'tree': String.fromCharCode(66 + i) * 200});
      }

      final sent = client.requests.last.messages.where((m) => m.role == .tool).toList();
      expect(sent.length, greaterThan(1));
      // Only the newest result survives in full...
      expect(sent.last.content.length, greaterThan(200));
      // ...the older ones are stubbed, and the stub says so rather than
      // silently shrinking the conversation.
      for (final stale in sent.take(sent.length - 1)) {
        expect(stale.content, contains('elided'));
        expect(stale.content.length, lessThan(200));
      }
    });

    test('without a window nothing is touched', () async {
      final client = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([('observe_tree', {})]),
        ],
      );
      final agent = SemanticsAgent(client: client);
      await agent.startEpisode(_task, _descriptor);
      await agent.next(null, _budget);
      await agent.next(EnvelopeResult.ok({'tree': 'X' * 300}), _budget);

      expect(client.requests.last.messages.any((m) => m.content.contains('X' * 300)), isTrue);
    });
  });

  group('AgentConfig', () {
    test('omits temperature when the deployment rejects it', () {
      const config = AgentConfig(supportsTemperature: false);
      expect(config.toJson()['supportsTemperature'], isFalse);
      final agent = SemanticsAgent(client: FakeLlmClient(), config: config);
      // Recorded as null, not as 0: "the model's default" is not "zero".
      expect(agent.manifest.metadata['temperature'], isNull);
    });

    test('round-trips through json', () {
      const config = AgentConfig(maxCompletionTokens: 4096, observationWindow: 5, parallelToolCalls: false);
      final restored = AgentConfig.fromJson(config.toJson());
      expect(restored.maxCompletionTokens, 4096);
      expect(restored.observationWindow, 5);
      expect(restored.parallelToolCalls, isFalse);
    });
  });
}
