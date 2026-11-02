/// `agent.toolSurface: fixed`: every intent a tool from the first call, a
/// conversation laid out for a local server's prompt cache. The default
/// surface is covered by intent_strategy_test.dart.
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

const _fixed = AgentConfig(toolSurface: .fixed);

const _descriptor = EnvironmentDescriptor(
  environmentId: 'env',
  envelopes: [
    EnvelopeSpec(key: 'intents.catalog', kind: .observe),
    EnvelopeSpec(key: 'intents.invoke', kind: .act),
  ],
);

EnvelopeResult _catalog(List<JsonMap> intents) => EnvelopeResult.ok({'intents': intents});

/// What `intents.describe` answers: full entries for the names asked about.
EnvelopeResult _described(List<JsonMap> intents) => EnvelopeResult.ok({'intents': intents});

const _describe = Envelope(key: 'intents.describe', kind: .observe);
const _catalogEnvelope = Envelope(key: 'intents.catalog', kind: .observe);

List<String> _toolNames(ToolStrategy strategy) => [for (final tool in strategy.tools) tool.name];

JsonMap _decoded(String rendered) => asJsonMap(jsonDecode(rendered));

void main() {
  group('FixedSurfaceIntentStrategy', () {
    test('every catalog intent is a tool from the start; describing changes none', () {
      final strategy = FixedSurfaceIntentStrategy();
      expect(_toolNames(strategy), ['describe_intents']);

      strategy.onResult(
        _catalogEnvelope,
        _catalog([
          {'name': 'form.describe', 'summary': 'Reads a form.', 'kind': 'observe'},
          {'name': 'form.set', 'summary': 'Sets values.', 'kind': 'act'},
        ]),
      );
      final offered = [for (final tool in strategy.tools) tool];
      expect(offered.map((t) => t.name), ['describe_intents', 'intent_form_describe', 'intent_form_set']);
      expect(offered[1].description, startsWith('Reads a form.'));

      strategy.onResult(
        _describe,
        _described([
          {
            'name': 'form.set',
            'description': 'Sets values on the open form.',
            'kind': 'act',
            'paramsSchema': {
              'type': 'object',
              'properties': {
                'values': {'type': 'object'},
              },
            },
          },
        ]),
      );
      // A changed tool list re-prefills a local server's whole prompt.
      expect(strategy.tools, offered);

      // A read-only intent must not be declared as an action, or every
      // describe would be billed as a step.
      expect(strategy.map(const LlmToolCall(id: '1', name: 'intent_form_describe'))!.kind, EnvelopeKind.observe);
      expect(strategy.map(const LlmToolCall(id: '2', name: 'intent_form_set'))!.kind, EnvelopeKind.act);
    });

    test('a call by catalog name to an intent the episode knows still reaches it', () {
      final strategy = FixedSurfaceIntentStrategy()
        ..onResult(
          _catalogEnvelope,
          _catalog([
            {'name': 'form.set', 'summary': 's', 'kind': 'act'},
          ]),
        );

      expect(strategy.map(const LlmToolCall(id: '1', name: 'form.set', arguments: {'value': 'y'}))!.payload, {
        'intent': 'form.set',
        'params': {'value': 'y'},
      });
      expect(strategy.map(const LlmToolCall(id: '2', name: 'intent_never_heard_of')), isNull);
      expect(strategy.map(const LlmToolCall(id: '3', name: 'never.heard.of')), isNull);
    });

    test('a parameterless intent is described with an object schema', () {
      final rendered = FixedSurfaceIntentStrategy().describeResult(
        _describe,
        _described([
          // The three ways an app says "no parameters".
          {'name': 'a.none', 'description': 'd'},
          {'name': 'b.empty', 'description': 'd', 'paramsSchema': {}},
          {
            'name': 'c.propsOnly',
            'description': 'd',
            'paramsSchema': {
              'properties': {
                'q': {'type': 'string'},
              },
            },
          },
        ]),
      )!;

      final intents = _decoded(rendered)['intents'] as List;
      for (final raw in intents) {
        expect(asJsonMap(asJsonMap(raw)['params'])['type'], 'object');
      }
      expect(asJsonMap(intents.first)['tool'], 'intent_a_none');
      // Normalising must not swallow what the app did say.
      expect(asJsonMap(asJsonMap(asJsonMap(intents.last)['params'])['properties']), containsPair('q', {'type': 'string'}));
    });

    test('a description is pinned; other results are not', () {
      final strategy = FixedSurfaceIntentStrategy();
      expect(strategy.pins(_describe, _described(const [])), isTrue);
      expect(strategy.pins(_describe, EnvelopeResult.failed('x', 'x')), isFalse);
      expect(strategy.pins(_catalogEnvelope, _catalog(const [])), isFalse);
    });
  });

  group('capability deltas', () {
    EnvelopeResult catalogOf(List<String> names) => EnvelopeResult.ok({
      'intents': [
        for (final name in names)
          {
            'name': name,
            'description': 'does $name',
            'kind': 'observe',
            'paramsSchema': {
              'type': 'object',
              'properties': {
                'value': {'type': 'string'},
              },
            },
          },
      ],
    });

    EnvelopeResult withDelta(List<String> added, List<String> removed) => EnvelopeResult.ok({
      'result': {'draftId': 17},
      'capabilities': {if (added.isNotEmpty) 'added': catalogOf(added).payload['intents'], if (removed.isNotEmpty) 'removed': removed},
    });

    const openForm = Envelope(key: 'intents.invoke', kind: .act, payload: {'intent': 'form.open'});

    test('add tools with their schemas, from any strategy envelope', () {
      // A semantics tap that opens a form grows the intent surface exactly as
      // `form.open` does; the hybrid agent hands every result to every
      // strategy for this reason.
      final strategy = FixedSurfaceIntentStrategy()..onResult(const Envelope(key: 'semantics.tap', kind: .act), withDelta(['form.read'], const []));
      final added = strategy.tools.last;
      expect(added.name, 'intent_form_read');
      expect(asJsonMap(added.parameters)['properties'], contains('value'));
      expect(strategy.map(const LlmToolCall(id: '1', name: 'intent_form_read'))!.kind, EnvelopeKind.observe);
    });

    test('are rendered as tool names, the schemas being in the definitions', () {
      final rendered = FixedSurfaceIntentStrategy().describeResult(openForm, withDelta(['form.set'], ['form.close']))!;

      expect(rendered, contains('draftId'));
      final delta = asJsonMap(_decoded(rendered)['newCapabilities']);
      expect(delta['available'], ['intent_form_set']);
      expect(delta['gone'], ['intent_form_close']);
      expect(rendered, isNot(contains('does form.set')));
    });
  });

  group('the tool surface', () {
    test('every tool, every word', () async {
      final agent = HybridAgent(client: FakeLlmClient(), config: _fixed);
      await agent.startEpisode(_task, _descriptor);

      final tools = {for (final t in agent.strategyTools) t.name: t};
      expect(tools.keys, contains('show_on_screen'));
      expect(tools['ask_user']!.description, contains('never to avoid reading the app'));
    });

    test('the catalog is rendered without the words the tool list already carries', () async {
      const sent = Envelope(key: 'intents.catalog', kind: .observe);
      final catalog = EnvelopeResult.ok(const {
        'intents': [
          {
            'name': 'form.open',
            'kind': 'act',
            'summary': 'Open a form by assemblyId and maskId.',
            'takesParameters': true,
            'metadata': {
              'policy': 'confirm',
              'requiredPermissions': ['forms.write'],
            },
          },
        ],
      });

      final rendered = FixedSurfaceIntentStrategy().describeResult(sent, catalog)!;

      // The listing carries no schema at all — that is what
      // describe_intents is for.
      expect(rendered, isNot(contains('paramsSchema')));
      // Kept: the name to describe by, and what is nowhere else.
      expect(rendered, contains('form.open'));
      // The summary is the tool's description; saying it here would send it
      // twice on every turn.
      expect(rendered, isNot(contains('Open a form by assemblyId')));
      expect(rendered, contains('"kind":"act"'));
      expect(rendered, contains('forms.write'));
      expect(rendered, contains('describe_intents'));
    });
  });

  group('a cacheable conversation', () {
    const catalog = {
      'intents': [
        {'name': 'data.count', 'summary': 'Count records', 'kind': 'observe'},
      ],
    };
    const described = {
      'intents': [
        {
          'name': 'data.count',
          'description': 'Count records',
          'kind': 'observe',
          'paramsSchema': {
            'type': 'object',
            'properties': {
              'endpointId': {'type': 'integer'},
            },
          },
        },
      ],
    };

    Future<FakeLlmClient> twoTurns({int? observationWindow, int? observationStride}) async {
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([
            (
              'describe_intents',
              {
                'names': ['data.count'],
              },
            ),
          ]),
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      );
      final agent = HybridAgent(
        client: llm,
        config: AgentConfig(
          parallelToolCalls: false,
          observationWindow: observationWindow,
          observationStride: observationStride,
          toolSurface: .fixed,
        ),
      );
      await agent.startEpisode(_task, _descriptor);
      await agent.next(null, _budget);
      await agent.next(EnvelopeResult.ok(catalog), _budget);
      await agent.next(EnvelopeResult.ok(described), _budget);
      return llm;
    }

    List<String> names(LlmRequest request) => [for (final tool in request.tools) tool.name];

    test('puts the task after the briefing and the bootstrap observation', () async {
      final llm = await twoTurns();
      final users = [
        for (final m in llm.requests.first.messages)
          if (m.role == .user) m.content,
      ];

      expect(users.first, isNot(contains('do the thing')));
      expect(users[1], startsWith('Initial observation:'));
      expect(users[1], isNot(contains('[budget:')));
      expect(users.last, 'Task: do the thing');
    });

    test('describing an intent leaves the tool list byte for byte the same', () async {
      final llm = await twoTurns();

      expect(names(llm.requests[1]), names(llm.requests[0]));
      // Every catalog intent is a tool from the first call.
      expect(names(llm.requests[0]), containsAll(['describe_intents', 'intent_data_count']));
      expect(llm.requests[1].messages.last.content, contains('"endpointId"'));
    });

    test('a description outlives the observation window', () async {
      final llm = await twoTurns(observationWindow: 0, observationStride: 1);
      final described = llm.requests[1].messages.lastWhere((m) => m.role == .tool);

      expect(described.content, contains('"endpointId"'));
    });
  });

  group('the default surface is untouched', () {
    test('describing promotes an intent; the task comes first', () async {
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([
            (
              'describe_intents',
              {
                'names': ['data.count'],
              },
            ),
          ]),
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      );
      final agent = HybridAgent(client: llm, config: const AgentConfig(parallelToolCalls: false));
      await agent.startEpisode(_task, _descriptor);
      await agent.next(null, _budget);
      await agent.next(
        _catalog(const [
          {'name': 'data.count', 'summary': 'Count records', 'kind': 'observe'},
        ]),
        _budget,
      );
      await agent.next(
        _described(const [
          {'name': 'data.count', 'description': 'Count records', 'kind': 'observe'},
        ]),
        _budget,
      );

      final first = [for (final t in llm.requests[0].tools) t.name];
      final second = [for (final t in llm.requests[1].tools) t.name];
      expect(first, isNot(contains('intent_data_count')));
      expect(second, contains('intent_data_count'));
      expect(llm.requests[0].messages[1].content, startsWith('Task: do the thing'));
    });
  });

  group('prompts follow the surface', () {
    test('each surface has its own defaults', () {
      expect(HybridAgent(client: FakeLlmClient()).promptVersion, 'hybrid_v4');
      expect(HybridAgent(client: FakeLlmClient(), config: _fixed).promptVersion, 'hybrid_v6');
      expect(PreparingAgent(client: FakeLlmClient()).promptVersion, 'prepared_v1');
      expect(PreparingAgent(client: FakeLlmClient(), config: _fixed).promptVersion, 'prepared_v3');
      expect(IntentAgent(client: FakeLlmClient()).promptVersion, 'intent_v3');
      expect(IntentAgent(client: FakeLlmClient(), config: _fixed).systemPrompt, Prompts.intentV4);
    });

    test('a prompt written for the other surface is refused', () {
      expect(
        () => HybridAgent(
          client: FakeLlmClient(),
          config: const AgentConfig(prompt: 'hybrid_v7'),
        ),
        throwsArgumentError,
      );
      expect(
        () => HybridAgent(
          client: FakeLlmClient(),
          config: const AgentConfig(prompt: 'hybrid_v5', toolSurface: .fixed),
        ),
        throwsArgumentError,
      );
      expect(
        HybridAgent(
          client: FakeLlmClient(),
          config: const AgentConfig(prompt: 'hybrid_v7', toolSurface: .fixed),
        ).systemPrompt,
        Prompts.hybridV7,
      );
    });

    test('v6 is v4 with tools offered up front; v7 and the prepared prompts build on it', () {
      expect(Prompts.hybridV6, contains('offered from your first turn'));
      expect(Prompts.hybridV6, isNot(contains('None of them is callable yet')));
      expect(Prompts.hybridV7, startsWith(Prompts.hybridV6));
      expect(Prompts.preparedV3, startsWith(Prompts.hybridV6));
      expect(Prompts.preparedV4, startsWith(Prompts.hybridV7));
      expect(Prompts.intentV4, contains('is a tool from the start'));
    });
  });

  group('config', () {
    test('toolSurface is recorded only when it departs from the default', () {
      expect(const AgentConfig().toJson(), isNot(contains('toolSurface')));
      expect(AgentConfig.fromJson(const {'toolSurface': 'fixed'}).toJson(), containsPair('toolSurface', 'fixed'));
      expect(() => AgentConfig.fromJson(const {'toolSurface': 'typed'}), throwsFormatException);
    });
  });
}
