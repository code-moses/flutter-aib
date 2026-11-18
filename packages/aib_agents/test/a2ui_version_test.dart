import 'package:aib_agents/agents.dart';
import 'package:aib_agents/testing.dart';
import 'package:aib_core/ports.dart';
import 'package:test/test.dart';

const _task = TaskSpec(
  id: 't',
  title: 't',
  instruction: 'show the todos',
  fixture: FixtureRef(id: 'fx', data: {}),
  budget: Budget(maxSteps: 10, maxWallClockSeconds: 60),
);

const _budget = BudgetStatus(stepsUsed: 0, maxSteps: 10, elapsedMs: 0, maxWallClockMs: 60000, tokensUsed: 0);

EnvironmentDescriptor _env([String? version]) => EnvironmentDescriptor(
  environmentId: 'env',
  envelopes: [
    const EnvelopeSpec(key: 'data.context', kind: .observe),
    EnvelopeSpec(
      key: 'genui.render',
      kind: .act,
      payloadSchema: {
        'type': 'object',
        'properties': {
          'messages': {
            'type': 'array',
            'items': {
              'type': 'object',
              if (version != null)
                'properties': {
                  'version': {'const': version},
                },
            },
          },
        },
      },
    ),
  ],
);

Future<String> _systemPrompt(EnvironmentDescriptor environment) async {
  final client = FakeLlmClient(
    responses: [
      FakeLlmClient.calls([('done', <String, Object?>{})]),
    ],
  );
  final agent = GenUiAgent(client: client);
  await agent.startEpisode(_task, environment);
  await agent.next(null, _budget);
  await agent.next(EnvelopeResult.ok({'todos': []}), _budget);
  return client.requests.first.messages.first.content;
}

void main() {
  test('the version comes from the render spec, v0.9 when it says nothing', () {
    expect(a2uiVersionOf(_env()), 'v0.9');
    expect(a2uiVersionOf(_env('1.0')), '1.0');
  });

  test('v0.9 leaves tools and prompt untouched', () async {
    final strategy = GenUiStrategy()..bind(_env('v0.9'));
    final unbound = GenUiStrategy();
    expect(strategy.tools, same(unbound.tools));
    expect(a2uiDialect(Prompts.genuiV2, 'v0.9'), same(Prompts.genuiV2));
    expect(await _systemPrompt(_env()), Prompts.genuiV2);
  });

  test('a 1.0 host gets 1.0 wording in tools and prompt', () async {
    final render = (GenUiStrategy()..bind(_env('1.0'))).tools.firstWhere((t) => t.name == 'render_ui');
    expect(render.description, contains('A2UI 1.0'));
    expect(render.description, isNot(contains('v0.9')));
    expect('${render.parameters}', contains('version: "1.0"'));

    final prompt = await _systemPrompt(_env('1.0'));
    expect(prompt, contains('"version": "1.0"'));
    expect(prompt, isNot(contains('v0.9')));
  });
}
