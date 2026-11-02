import 'package:aib_agents/aib_agents.dart';
import 'package:aib_agents/testing.dart';
import 'package:aib_core/ports.dart';
import 'package:test/test.dart';

TaskSpec _task([UserSimulatorSpec? spec]) => TaskSpec(
  id: 't',
  title: 't',
  instruction: 'x',
  budget: Budget(maxSteps: 5, maxWallClockSeconds: 10),
  fixture: const FixtureRef(id: 'f', data: <String, Object?>{}),
  userSimulator: spec,
);

const _spec = UserSimulatorSpec(goal: 'Eine Anforderung über 2 Stück Kabel', knows: {'Welcher Artikel': '4FFAE82D'}, mustNotReveal: ['27']);

LlmUserSimulator _simulator(List<String> replies) => LlmUserSimulator(
  client: FakeLlmClient(responses: [for (final reply in replies) LlmResponse(text: reply)]),
)..beginEpisode(_task(_spec));

void main() {
  test('a known answer is given verbatim, without the model', () async {
    final user = _simulator(const []);
    expect(await user.answer({'type': 'pick', 'prompt': 'Welcher Artikel ist es?'}), '4FFAE82D');
    expect(user.drain().single['source'], 'knows');
  });

  test('a record nobody named is refused, not invented', () async {
    final user = _simulator(const []);
    expect(await user.answer({'type': 'pick', 'prompt': 'Welcher Auftrag?'}), isNull);
    expect(user.drain().single['issues'], ['unknown_pick']);
  });

  test('a confirmation becomes a bool', () async {
    final user = _simulator(['Ja, schick sie ab.']);
    expect(await user.answer({'type': 'confirm', 'prompt': 'Abschicken?'}), true);
    expect(user.drain().single['valid'], isTrue);
  });

  test('leaving the role or naming ground truth is flagged', () async {
    final user = _simulator(['As an AI I would say there are 27.']);
    await user.answer({'type': 'text', 'prompt': 'Wie viele sind es?'});
    expect(user.drain().single['issues'], containsAll(['role_break', 'revealed:27']));
  });

  test('DONE ends the conversation, anything else continues it', () async {
    final user = _simulator(['Bitte noch die Menge auf 3.', 'DONE']);
    expect(await user.followUp('Angelegt.'), 'Bitte noch die Menge auf 3.');
    expect(await user.followUp('Geändert.'), isNull);
    expect([for (final r in user.drain()) r['satisfied']], [false, true]);
  });

  test('DONE while the goal does not hold is flagged', () async {
    final user = _simulator(['DONE']);
    expect(await user.followUp('Gespeichert.', goalMet: false), isNull);
    expect(user.drain().single['issues'], ['premature_done']);
  });

  test('asking for what the goal rules out is flagged', () async {
    // A reply that must not pass as valid.
    final user = LlmUserSimulator(
      client: FakeLlmClient(responses: [const LlmResponse(text: 'Ich möchte sie jetzt absenden.')]),
    )..beginEpisode(_task(const UserSimulatorSpec(goal: 'Ein Entwurf, nicht abgeschickt', mustNotAsk: ['Absenden'])));
    await user.followUp('Gespeichert.');
    expect(user.drain().single['issues'], ['contradicts_goal:Absenden']);
  });

  test('a task without a simulated user gets nothing', () async {
    final user = LlmUserSimulator(client: FakeLlmClient())..beginEpisode(_task());
    expect(user.isActive, isFalse);
    expect(await user.answer({'type': 'text', 'prompt': 'x'}), isNull);
    expect(await user.followUp('done'), isNull);
  });
}
