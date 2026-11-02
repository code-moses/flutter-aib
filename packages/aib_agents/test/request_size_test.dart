import 'package:aib_agents/aib_agents.dart';
import 'package:aib_agents/testing.dart';
import 'package:aib_core/ports.dart';
import 'package:test/test.dart';

void main() {
  test('a decision says how much its request sent', () async {
    final agent = IntentAgent(
      client: FakeLlmClient(
        responses: [
          FakeLlmClient.calls([
            ('done', {'summary': 'Erledigt.'}),
          ]),
        ],
      ),
    );
    await agent.startEpisode(
      const TaskSpec(
        id: 't',
        title: 't',
        instruction: 'Zähle die Artikel.',
        budget: Budget(maxSteps: 5, maxWallClockSeconds: 30),
        fixture: FixtureRef(id: 'f'),
      ),
      const EnvironmentDescriptor(environmentId: 'env'),
    );

    const budget = BudgetStatus(stepsUsed: 0, maxSteps: 5, elapsedMs: 0, maxWallClockMs: 30000, tokensUsed: 0);
    // Bootstrap envelopes come first and ask no model.
    var envelope = await agent.next(null, budget);
    for (var i = 0; i < 5 && (envelope.decision?.llmCalls ?? 0) == 0; i++) {
      envelope = await agent.next(EnvelopeResult.ok(), budget);
    }

    expect(envelope.decision?.llmCalls, 1, reason: 'last key: ${envelope.key}');
    // At least the instruction and the done tool's schema went out.
    expect(envelope.decision?.extra?['requestChars'], greaterThan('Zähle die Artikel.'.length));
  });
}
