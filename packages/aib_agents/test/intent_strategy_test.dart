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

EnvelopeResult _catalog(List<JsonMap> intents) => EnvelopeResult.ok({'intents': intents});

/// What `intents.describe` answers: full entries for the names asked about.
EnvelopeResult _described(List<JsonMap> intents) => EnvelopeResult.ok({'intents': intents});

const _describe = Envelope(key: 'intents.describe', kind: .observe);
const _catalogEnvelope = Envelope(key: 'intents.catalog', kind: .observe);

/// Tool names minus the always-present describe tool.
List<String> _intentTools(IntentStrategy strategy) => [
  for (final tool in strategy.tools)
    if (tool.name != IntentStrategy.describeTool.name) tool.name,
];

void main() {
  group('IntentStrategy', () {
    test('the catalog lists; describing is what builds a tool', () {
      final strategy = IntentStrategy();
      expect(_intentTools(strategy), isEmpty);
      // describe_intents is always offered, or nothing could ever be asked
      // about.
      expect(strategy.tools.map((t) => t.name), ['describe_intents']);

      // A summary listing carries no schema and must not produce a tool.
      strategy.onResult(
        _catalogEnvelope,
        _catalog([
          {'name': 'form.describe', 'summary': 's', 'kind': 'observe'},
          {'name': 'form.set', 'summary': 's', 'kind': 'act'},
        ]),
      );
      expect(_intentTools(strategy), isEmpty);

      strategy.onResult(
        _describe,
        _described([
          {'name': 'form.describe', 'description': 'd', 'kind': 'observe'},
          {'name': 'form.set', 'description': 'd', 'kind': 'act'},
        ]),
      );
      expect(_intentTools(strategy), ['intent_form_describe', 'intent_form_set']);

      // A read-only intent must not be declared as an action, or every
      // describe would be billed as a step.
      final observe = strategy.map(const LlmToolCall(id: '1', name: 'intent_form_describe'));
      expect(observe!.kind, EnvelopeKind.observe);
      final act = strategy.map(const LlmToolCall(id: '2', name: 'intent_form_set'));
      expect(act!.kind, EnvelopeKind.act);
    });

    test('a later catalog drops tools whose intent left scope', () {
      final strategy = IntentStrategy()
        ..onResult(
          _describe,
          _described([
            {'name': 'a.one', 'description': 'd'},
            {'name': 'b.two', 'description': 'd'},
          ]),
        );
      expect(_intentTools(strategy), ['intent_a_one', 'intent_b_two']);

      // Context changed; the old page's intent is gone, and a described tool
      // does not outlive the scope that offered it.
      strategy.onResult(
        _catalogEnvelope,
        _catalog([
          {'name': 'b.two', 'summary': 's'},
        ]),
      );
      expect(_intentTools(strategy), ['intent_b_two']);
    });

    test('a parameterless intent still gets an object schema', () {
      final strategy = IntentStrategy()
        ..onResult(
          _describe,
          _described([
            // The three ways an app says "no parameters". Anthropic rejects a tool
            // whose input_schema has no `type`.
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
        );

      for (final tool in strategy.tools) {
        expect(tool.parameters['type'], 'object', reason: tool.name);
      }
      expect(_intentTools(strategy), hasLength(3));
      // Normalising must not swallow what the app did say.
      expect(strategy.tools.last.parameters['properties'], containsPair('q', {'type': 'string'}));
    });
  });

  group('capability deltas reach the tool surface', () {
    EnvelopeResult catalogOf(List<String> names) => EnvelopeResult.ok({
      'intents': [
        for (final name in names)
          {
            'name': name,
            'description': 'does $name',
            'kind': 'act',
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

    test('a delta grows the tools without a re-observation', () {
      final strategy = IntentStrategy();
      strategy.onResult(_describe, catalogOf(['form.open']));
      expect(_intentTools(strategy), ['intent_form_open']);

      strategy.onResult(openForm, withDelta(['form.set'], const []));

      // No turn was spent, and no describe call either: a delta carries full
      // entries, so the tool is simply there on the next request with the
      // schema the app published.
      expect(_intentTools(strategy), ['intent_form_open', 'intent_form_set']);
      final added = strategy.tools.last;
      expect(asJsonMap(added.parameters)['properties'], contains('value'));
      expect(strategy.map(const LlmToolCall(id: '1', name: 'intent_form_set', arguments: {}))!.payload['intent'], 'form.set');
    });

    test('a delta on another strategy envelope counts too', () {
      // A semantics tap that opens a form grows the intent surface exactly as
      // `form.open` does; the hybrid agent hands every result to every
      // strategy for this reason.
      final strategy = IntentStrategy();
      strategy.onResult(_describe, catalogOf(['nav.open']));
      strategy.onResult(const Envelope(key: 'semantics.tap', kind: .act), withDelta(['form.set'], const []));
      expect(strategy.tools.map((t) => t.name), contains('intent_form_set'));
    });

    test('a tool that left scope stops being offered and callable', () {
      final strategy = IntentStrategy();
      strategy.onResult(_describe, catalogOf(['form.open', 'form.set']));
      strategy.onResult(openForm, withDelta(const [], ['form.set']));

      expect(_intentTools(strategy), ['intent_form_open']);
      expect(strategy.map(const LlmToolCall(id: '1', name: 'intent_form_set', arguments: {})), isNull);
    });

    test('the model is told the names, not the schemas again', () {
      final strategy = IntentStrategy();
      strategy.onResult(_describe, catalogOf(['form.open']));
      final result = withDelta(['form.set'], const []);
      final rendered = strategy.describeResult(openForm, result)!;

      expect(rendered, contains('intent_form_set'));
      expect(rendered, contains('draftId'));
      // The parameters travel as the tool definition; repeating them here
      // would send them twice.
      expect(rendered, isNot(contains('paramsSchema')));
      expect(rendered, isNot(contains('does form.set')));
    });
  });

  group('the tool surface', () {
    test('every tool, every word', () async {
      final agent = HybridAgent(client: FakeLlmClient());
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

      final rendered = IntentStrategy().describeResult(sent, catalog)!;

      // The listing carries no schema at all — that is what
      // describe_intents is for.
      expect(rendered, isNot(contains('paramsSchema')));
      // Kept: the name to describe by, and what is nowhere else.
      expect(rendered, contains('form.open'));
      expect(rendered, contains('Open a form by assemblyId'));
      expect(rendered, contains('"kind":"act"'));
      expect(rendered, contains('forms.write'));
      // No tool name: it is not callable until it has been described.
      expect(rendered, isNot(contains(IntentStrategy.toolNameFor('form.open'))));
    });
  });
}
