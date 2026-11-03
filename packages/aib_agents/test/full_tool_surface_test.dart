/// `agent.toolSurface: full`: every intent a tool with its full schema from
/// the first call, described by the agent before the model is asked.
library;

import 'dart:convert';

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

const _budget = BudgetStatus(stepsUsed: 0, maxSteps: 10, elapsedMs: 0, maxWallClockMs: 60000, tokensUsed: 0);

const _full = AgentConfig(parallelToolCalls: false, toolSurface: .full);

const _descriptor = EnvironmentDescriptor(
  environmentId: 'env',
  envelopes: [
    EnvelopeSpec(key: 'intents.catalog', kind: .observe),
    EnvelopeSpec(key: 'intents.describe', kind: .observe),
    EnvelopeSpec(key: 'intents.invoke', kind: .act),
  ],
);

const _catalog = {
  'scope': 'Articles and forms.',
  'intents': [
    {'name': 'data.count', 'summary': 'Count records', 'kind': 'observe'},
    {
      'name': 'form.open',
      'summary': 'Open a form',
      'kind': 'act',
      'metadata': {'policy': 'confirm'},
    },
  ],
};

const _described = {
  'intents': [
    {
      'name': 'data.count',
      'description': 'Count records of an endpoint.',
      'kind': 'observe',
      'paramsSchema': {
        'type': 'object',
        'properties': {
          'endpointId': {'type': 'integer'},
        },
        'required': ['endpointId'],
      },
    },
    {'name': 'form.open', 'description': 'Open a form by assemblyId and maskId.', 'kind': 'act'},
  ],
};

/// Bootstrap, describe, then one model call answered by [responses].
Future<(HybridAgent, FakeLlmClient, List<Envelope>)> _boot(List<LlmResponse> responses) async {
  final llm = FakeLlmClient(responses: responses);
  final agent = HybridAgent(client: llm, config: _full);
  await agent.startEpisode(_task, _descriptor);
  final sent = [await agent.next(null, _budget), await agent.next(EnvelopeResult.ok(_catalog), _budget)];
  sent.add(await agent.next(EnvelopeResult.ok(_described), _budget));
  return (agent, llm, sent);
}

void main() {
  group('the bootstrap', () {
    test('describes every catalog intent before the first model call', () async {
      final (_, llm, sent) = await _boot([
        FakeLlmClient.calls([('done', <String, Object?>{})]),
      ]);

      expect(sent[0].key, 'intents.catalog');
      expect(sent[1].key, 'intents.describe');
      expect(sent[1].payload['names'], ['data.count', 'form.open']);
      expect(llm.requests, hasLength(1));
    });

    test('a capped description is followed by one for what it left out', () {
      final strategy = FullSurfaceIntentStrategy();
      const sent = Envelope(
        key: 'intents.describe',
        kind: .observe,
        payload: {
          'names': ['data.count', 'form.open', 'nav.open'],
        },
      );
      final capped = EnvelopeResult.ok(const {
        'intents': [
          {'name': 'data.count', 'description': 'Count.', 'kind': 'observe'},
        ],
        'truncated': true,
      });
      final whole = EnvelopeResult.ok(const {
        'intents': [
          {'name': 'data.count', 'description': 'Count.', 'kind': 'observe'},
        ],
      });

      expect(strategy.planAfter(sent, capped).single.payload['names'], ['form.open', 'nav.open']);
      expect(strategy.planAfter(sent, whole), isEmpty);
    });

    test('an empty catalog is not described', () async {
      final agent = HybridAgent(
        client: FakeLlmClient(
          responses: [
            FakeLlmClient.calls([('done', <String, Object?>{})]),
          ],
        ),
        config: _full,
      );
      await agent.startEpisode(_task, _descriptor);
      await agent.next(null, _budget);
      final next = await agent.next(EnvelopeResult.ok(const {'intents': <Object?>[]}), _budget);

      expect(next.key, isNot('intents.describe'));
    });
  });

  group('the first request', () {
    test('offers every intent with its schema and no describe_intents', () async {
      final (_, llm, _) = await _boot([
        FakeLlmClient.calls([('done', <String, Object?>{})]),
      ]);
      final tools = {for (final tool in llm.requests.single.tools) tool.name: tool};

      expect(tools.keys, containsAll(['intent_data_count', 'intent_form_open']));
      expect(tools.keys, isNot(contains('describe_intents')));
      expect(tools['intent_data_count']!.parameters['required'], ['endpointId']);
      expect(tools['intent_form_open']!.parameters['type'], 'object');
    });

    test('puts the task last, after observations without a budget line', () async {
      final (_, llm, _) = await _boot([
        FakeLlmClient.calls([('done', <String, Object?>{})]),
      ]);
      final users = [
        for (final m in llm.requests.single.messages)
          if (m.role == .user) m.content,
      ];

      expect(users.first, isNot(contains('do the thing')));
      expect(users.last, 'Task: do the thing');
      expect(users.where((u) => u.contains('[budget:')), isEmpty);
    });

    test('renders the catalog as names, kinds and metadata, and describe as tool names', () async {
      final (_, llm, _) = await _boot([
        FakeLlmClient.calls([('done', <String, Object?>{})]),
      ]);
      final users = [
        for (final m in llm.requests.single.messages)
          if (m.role == .user) m.content,
      ];
      final catalog = users.firstWhere((u) => u.contains('"intents"'));
      final described = users.firstWhere((u) => u.contains('"callable"'));

      expect(catalog, contains('Articles and forms.'));
      expect(catalog, contains('"policy":"confirm"'));
      expect(catalog, isNot(contains('Count records')));
      expect(catalog, isNot(contains('describe_intents')));
      expect(described, isNot(contains('endpointId')));
      expect(jsonDecode(described.substring(described.indexOf('{')))['callable'], ['intent_data_count', 'intent_form_open']);
    });
  });

  group('calls', () {
    test('a tool call invokes its intent', () async {
      final (_, _, sent) = await _boot([
        FakeLlmClient.calls([
          ('intent_data_count', {'endpointId': 10}),
        ]),
      ]);

      expect(sent.last.key, 'intents.invoke');
      expect(sent.last.payload, {
        'intent': 'data.count',
        'params': {'endpointId': 10},
      });
      expect(sent.last.kind, EnvelopeKind.observe);
    });

    test('a call by catalog name reaches the intent', () async {
      final (_, _, sent) = await _boot([
        FakeLlmClient.calls([
          ('form.open', {'assemblyId': 1}),
        ]),
      ]);

      expect(sent.last.key, 'intents.invoke');
      expect(sent.last.payload['intent'], 'form.open');
    });

    test('describe_intents is not a tool', () {
      final strategy = FullSurfaceIntentStrategy();
      expect(strategy.map(const LlmToolCall(id: '1', name: 'describe_intents')), isNull);
    });
  });

  group('capability deltas', () {
    test('add tools with their schemas and drop removed ones', () {
      final strategy = FullSurfaceIntentStrategy()
        ..onResult(const Envelope(key: 'intents.catalog', kind: .observe), EnvelopeResult.ok(_catalog))
        ..onResult(const Envelope(key: 'intents.describe', kind: .observe), EnvelopeResult.ok(_described))
        ..onResult(
          const Envelope(key: 'intents.invoke', kind: .act),
          EnvelopeResult.ok(const {
            'capabilities': {
              'added': [
                {
                  'name': 'form.set',
                  'description': 'Set values.',
                  'kind': 'act',
                  'paramsSchema': {
                    'type': 'object',
                    'properties': {
                      'values': {'type': 'object'},
                    },
                  },
                },
              ],
              'removed': ['form.open'],
            },
          }),
        );

      final names = [for (final tool in strategy.tools) tool.name];
      expect(names, ['intent_data_count', 'intent_form_set']);
    });
  });

  group('prompts and agents', () {
    test('the hybrid defaults to v8 and accepts v9 only under full', () {
      expect(HybridAgent(client: FakeLlmClient(), config: _full).promptVersion, 'hybrid_v8');
      expect(
        HybridAgent(
          client: FakeLlmClient(),
          config: const AgentConfig(prompt: 'hybrid_v9', toolSurface: .full),
        ).systemPrompt,
        Prompts.hybridV9,
      );
      expect(
        () => HybridAgent(
          client: FakeLlmClient(),
          config: const AgentConfig(prompt: 'hybrid_v9'),
        ),
        throwsArgumentError,
      );
    });

    test('the full prompts never mention describe_intents', () {
      expect(Prompts.hybridV8, isNot(contains('describe_intents')));
      expect(Prompts.hybridV9, isNot(contains('describe_intents')));
      expect(Prompts.hybridV9, startsWith(Prompts.hybridV8));
      expect(Prompts.intentV5, isNot(contains('describe_intents')));
    });

    test('the intent agent describes the catalog too', () async {
      final agent = IntentAgent(
        client: FakeLlmClient(
          responses: [
            FakeLlmClient.calls([('done', <String, Object?>{})]),
          ],
        ),
        config: _full,
      );
      await agent.startEpisode(_task, _descriptor);
      await agent.next(null, _budget);
      final next = await agent.next(EnvelopeResult.ok(_catalog), _budget);

      expect(agent.promptVersion, 'intent_v5');
      expect(next.key, 'intents.describe');
    });

    test('the preparing agent refuses full', () {
      expect(() => PreparingAgent(client: FakeLlmClient(), config: _full), throwsArgumentError);
    });

    test('toolSurface full is recorded in the config', () {
      expect(AgentConfig.fromJson(const {'toolSurface': 'full'}).toJson(), containsPair('toolSurface', 'full'));
    });
  });
}
