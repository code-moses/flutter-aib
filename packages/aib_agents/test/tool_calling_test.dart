import 'package:aib_agents/aib_agents.dart';
import 'package:aib_agents/testing.dart';
import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

/// ADR 0015: constrained tool calls, worked examples, one call per turn, and
/// what a model wrote in the trace. Every knob is opt-in and absent from the
/// recorded config when off, so arms that do not set one keep their hashes.
void main() {
  _configTests();
  _constrainedDecodingTests();
  _parallelCallTests();
  _modelOutputTraceTests();
  _providerTests();
  _promptTests();
  _exampleTests();
}

const _emptyCatalog = EnvelopeResult(status: .ok, payload: {'intents': <Object?>[]});

final _task = TaskSpec(
  id: 't',
  title: 't',
  instruction: 'Wie viele Artikel gibt es?',
  budget: const Budget(maxSteps: 5, maxWallClockSeconds: 60),
  fixture: const FixtureRef(id: 'live'),
);

const _environment = EnvironmentDescriptor(
  environmentId: 'fake',
  version: '1',
  envelopes: [EnvelopeSpec(key: 'intents.catalog', kind: .observe, description: 'catalog')],
);

const _budget = BudgetStatus(stepsUsed: 0, maxSteps: 5, elapsedMs: 0, maxWallClockMs: 60000, tokensUsed: 0);

/// Past the bootstrap, so the next `next` asks the model.
Future<Envelope> _firstModelTurn(ToolLoopAgent agent) async {
  await agent.startEpisode(_task, _environment);
  await agent.next(null, _budget);
  return agent.next(_emptyCatalog, _budget);
}

LlmResponse _json(String text, {String? stopReason, String? thinking}) => LlmResponse(text: text, stopReason: stopReason, thinking: thinking);

void _configTests() {
  group('agent config', () {
    test('a config that sets none of the new knobs records exactly what it recorded before', () {
      final json = const AgentConfig(parallelToolCalls: false, observationWindow: 8).toJson();
      expect(json.keys.toSet(), {
        'maxCompletionTokens',
        'temperature',
        'supportsTemperature',
        'parallelToolCalls',
        'observationWindow',
        'observationStride',
        'maxUnknownToolRetries',
        'finishWarningTurns',
        'retry',
      });
    });

    test('the knobs round-trip and are recorded when set', () {
      final config = AgentConfig.fromJson({
        'toolCalling': 'constrained',
        'prompt': 'hybrid_v5',
        'examples': {'tools': true},
        'captureModelOutput': true,
      });
      expect(config.toolCalling, ToolCalling.constrained);
      expect(config.prompt, 'hybrid_v5');
      expect(config.examples.tools, isTrue);
      expect(config.examples.intents, isFalse);
      expect(config.toJson(), containsPair('toolCalling', 'constrained'));
      expect(config.toJson(), containsPair('examples', {'tools': true, 'intents': false}));
      expect(AgentConfig.fromJson(config.toJson()).toJson(), config.toJson());
    });

    test('a knob that would silently do nothing is an error', () {
      expect(() => AgentConfig.fromJson({'toolCalling': 'grammar'}), throwsFormatException);
      expect(
        () => AgentConfig.fromJson({
          'examples': {'prompt': true},
        }),
        throwsFormatException,
      );
      expect(() => AgentConfig.fromJson({'examples': true}), throwsFormatException);
    });

    test('capturing model output does not change the arm the release gate compares', () {
      const plain = AgentConfig(parallelToolCalls: false);
      const captured = AgentConfig(parallelToolCalls: false, captureModelOutput: true);
      expect(configHash(captured.identity), configHash(plain.identity));
      expect(configHash(captured.toJson()), isNot(configHash(plain.toJson())));
    });

    test('treatments do change the identity', () {
      final base = configHash(const AgentConfig().identity);
      expect(configHash(const AgentConfig(toolCalling: .constrained).identity), isNot(base));
      expect(configHash(const AgentConfig(prompt: 'hybrid_v5').identity), isNot(base));
      expect(configHash(const AgentConfig(examples: ExamplesConfig(intents: true)).identity), isNot(base));
    });
  });
}

void _constrainedDecodingTests() {
  const tools = [
    LlmTool(
      name: 'intent_todo_find',
      description: 'Finds todos.',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
        },
      },
    ),
    LlmTool(name: 'done', description: 'Done.'),
  ];

  group('ConstrainedToolCalls', () {
    test('the schema admits one object per tool, with the tool named first', () {
      final schema = ConstrainedToolCalls.schemaFor(tools);
      final branches = schema['anyOf'] as List;
      expect(branches, hasLength(2));
      final first = asJsonMap(branches.first);
      expect(asJsonMap(asJsonMap(first['properties'])['tool']), {'const': 'intent_todo_find'});
      expect(asJsonMap(first['properties']).keys.toList(), ['tool', 'arguments'], reason: 'the tool is decoded before its arguments');
      expect(first['required'], ['tool', 'arguments']);
      expect(asJsonMap(asJsonMap(first['properties'])['arguments']), tools.first.parameters);
    });

    test('decodes the constrained document as the call it is, and empties the text', () {
      final decoded = ConstrainedToolCalls.decode(_json('{"tool": "intent_todo_find", "arguments": {"query": "Steuer"}}'));
      expect(decoded.toolCalls.single.name, 'intent_todo_find');
      expect(decoded.toolCalls.single.arguments, {'query': 'Steuer'});
      expect(decoded.text, isEmpty, reason: 'the call would otherwise be in the history twice');
    });

    test('arguments missing from the document are an empty object', () {
      final decoded = ConstrainedToolCalls.decode(_json('{"tool": "done"}'));
      expect(decoded.toolCalls.single.arguments, isEmpty);
    });

    test('a native tool call passes through untouched', () {
      final native = FakeLlmClient.calls([('done', <String, Object?>{})]);
      expect(ConstrainedToolCalls.decode(native), same(native));
    });

    test('a completion cut off mid-document is left for the loop to nudge, with its stop reason', () {
      final cut = _json('{"tool": "intent_todo_find", "argum', stopReason: 'length');
      final decoded = ConstrainedToolCalls.decode(cut);
      expect(decoded.toolCalls, isEmpty);
      expect(decoded.text, cut.text);
      expect(decoded.stopReason, 'length');
    });

    test('prose and a document without a tool are not calls', () {
      expect(ConstrainedToolCalls.decode(_json('The answer is 27.')).toolCalls, isEmpty);
      expect(ConstrainedToolCalls.decode(_json('{"answer": 27}')).toolCalls, isEmpty);
    });
  });

  group('constrained agent', () {
    test('asks for the schema over every tool it offers, done and abort included', () async {
      final llm = FakeLlmClient(supportsResponseSchema: true, responses: [_json('{"tool": "done", "arguments": {"summary": "27"}}')]);
      final agent = IntentAgent(
        client: llm,
        config: const AgentConfig(toolCalling: .constrained),
      );
      final envelope = await _firstModelTurn(agent);

      expect(envelope.key, 'meta.done');
      final turn = (envelope.decision!.extra!['llm'] as List).single as Map;
      expect(turn, containsPair('calls', ['done']), reason: 'the call is the decoded one, not the runtime\'s empty tool_calls');
      expect(turn, containsPair('constrained', true));
      final request = llm.requests.single;
      final names = [
        for (final branch in request.responseSchema!['anyOf'] as List) asJsonMap(asJsonMap(asJsonMap(branch)['properties'])['tool'])['const'],
      ];
      expect(names, containsAll(['describe_intents', 'done', 'abort']));
      expect(names, [for (final tool in request.tools) tool.name], reason: 'the schema and the tools the model is told about are the same list');
      expect(request.tools, isNotEmpty, reason: 'tools still reach the template, so descriptions reach the model');
    });

    test('a native arm sends no schema', () async {
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      );
      await _firstModelTurn(IntentAgent(client: llm));
      expect(llm.requests.single.responseSchema, isNull);
    });

    test('is refused against a client that would ignore the schema', () {
      expect(
        () => IntentAgent(
          client: FakeLlmClient(),
          config: const AgentConfig(toolCalling: .constrained),
        ),
        throwsArgumentError,
      );
    });

    test('the model router supports it only when both sides do', () {
      ModelRouter router(LlmClient local, LlmClient cloud) =>
          ModelRouter(local: local, cloud: cloud, decider: const FixedRouteDecider(ModelRoute.local));
      expect(router(FakeLlmClient(supportsResponseSchema: true), FakeLlmClient(supportsResponseSchema: true)).supportsResponseSchema, isTrue);
      expect(router(FakeLlmClient(supportsResponseSchema: true), FakeLlmClient()).supportsResponseSchema, isFalse);
    });

    test('a truncated document is nudged like any turn without a call', () async {
      final llm = FakeLlmClient(
        supportsResponseSchema: true,
        responses: [
          _json('{"tool": "do', stopReason: 'length'),
          _json('{"tool": "done", "arguments": {"summary": "ok"}}'),
        ],
      );
      final agent = IntentAgent(
        client: llm,
        config: const AgentConfig(toolCalling: .constrained),
      );
      final envelope = await _firstModelTurn(agent);
      expect(envelope.key, 'meta.done');
      expect(llm.requests, hasLength(2));
      expect(llm.requests.last.messages.last.content, contains('no tool call'));
    });
  });
}

void _parallelCallTests() {
  group('one call per turn', () {
    LlmResponse two() => FakeLlmClient.calls([
      (
        'describe_intents',
        {
          'names': <String>['a'],
        },
      ),
      (
        'describe_intents',
        {
          'names': <String>['b'],
        },
      ),
    ]);

    test('a turn that answers with several calls runs the first and says what it dropped', () async {
      final llm = FakeLlmClient(
        responses: [
          two(),
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      );
      final agent = IntentAgent(client: llm, config: const AgentConfig(parallelToolCalls: false));
      final envelope = await _firstModelTurn(agent);

      expect(envelope.payload['names'], ['a']);
      expect(envelope.decision!.note, contains('parallel_dropped=1'));
      expect((envelope.decision!.extra!['llm'] as List).single, containsPair('droppedParallel', 1));

      // The next thing that happens is a model call, not the dropped call, and
      // the history it reads holds one call for that turn.
      final next = await agent.next(const EnvelopeResult(status: .ok, payload: {'intents': <Object?>[]}), _budget);
      expect(next.key, 'meta.done');
      expect(llm.requests, hasLength(2));
      final assistant = llm.requests.last.messages.lastWhere((m) => m.role == .assistant);
      expect(assistant.toolCalls, hasLength(1));
    });

    test('a provider default keeps the old behaviour: both calls run, in order', () async {
      final llm = FakeLlmClient(responses: [two()]);
      final agent = IntentAgent(client: llm);
      final first = await _firstModelTurn(agent);
      expect(first.payload['names'], ['a']);
      expect(first.decision!.note ?? '', isNot(contains('parallel_dropped')));
      final second = await agent.next(const EnvelopeResult(status: .ok, payload: {'intents': <Object?>[]}), _budget);
      expect(second.payload['names'], ['b'], reason: 'queued, no second model call');
      expect(llm.requests, hasLength(1));
    });
  });
}

void _modelOutputTraceTests() {
  Future<Envelope> emptyTurn({bool capture = false}) async {
    final llm = FakeLlmClient(
      responses: [
        _json('', stopReason: 'stop', thinking: 'Okay, the user wants the article count. I should look at the catalog.'),
        _json('', stopReason: 'stop', thinking: 'Still thinking.'),
        _json('', stopReason: 'stop'),
        _json('', stopReason: 'stop'),
      ],
    );
    final agent = IntentAgent(
      client: llm,
      config: AgentConfig(captureModelOutput: capture),
    );
    return _firstModelTurn(agent);
  }

  group('what the model wrote', () {
    test('every unusable turn says why it was unusable, without its text', () async {
      final abort = await emptyTurn();
      expect(abort.key, 'meta.abort');
      final turns = (abort.decision!.extra!['llm'] as List).cast<Map>();
      expect(turns, hasLength(4));
      expect(turns.first, containsPair('stopReason', 'stop'));
      expect(turns.first['thinkingChars'], greaterThan(0), reason: 'reasoned, then answered with nothing: not the same as silence');
      expect(turns.last['thinkingChars'], 0);
      expect(turns.first, isNot(contains('content')));
      expect(turns.first, isNot(contains('thinking')));
    });

    test('captureModelOutput adds the text and the reasoning', () async {
      final abort = await emptyTurn(capture: true);
      final first = (abort.decision!.extra!['llm'] as List).cast<Map>().first;
      expect(first['thinking'], contains('article count'));
      expect(first, containsPair('content', ''));
    });

    test('records the names it called', () async {
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      );
      final envelope = await _firstModelTurn(IntentAgent(client: llm));
      expect((envelope.decision!.extra!['llm'] as List).single, containsPair('calls', ['done']));
    });
  });
}

void _providerTests() {
  const request = LlmRequest(messages: [], parallelToolCalls: false, responseSchema: {'type': 'object'});

  group('providers', () {
    test('Ollama sends the schema as format, and the parallel switch it will ignore', () {
      final body = OllamaClient(model: 'qwen3:8b', think: false).buildBody(request);
      expect(body['format'], {'type': 'object'});
      expect(body['parallel_tool_calls'], isFalse);
      expect(OllamaClient(model: 'x').supportsResponseSchema, isTrue);
      expect(OllamaClient(model: 'x').buildBody(const LlmRequest(messages: [])).containsKey('format'), isFalse);
    });

    test('Ollama reads the reasoning and the done reason', () {
      final response = OllamaClient.parseResponse({
        'message': {'content': '', 'thinking': 'let me see', 'role': 'assistant'},
        'done_reason': 'stop',
      });
      expect(response.thinking, 'let me see');
      expect(response.stopReason, 'stop');
      expect(
        OllamaClient.parseResponse({
          'message': {'content': 'x'},
        }).thinking,
        isNull,
      );
    });

    test('an OpenAI-compatible server\'s reasoning is read from either name it uses', () {
      expect(
        OpenAiClient.parseResponse({
          'choices': [
            {
              'message': {'content': 'x', 'reasoning_content': 'why'},
              'finish_reason': 'stop',
            },
          ],
        }).thinking,
        'why',
      );
      expect(
        OpenAiClient.parseResponse({
          'choices': [
            {
              'message': {'content': 'x', 'reasoning': 'because'},
            },
          ],
        }).thinking,
        'because',
      );
    });

    test('Anthropic thinking blocks are read, and never sent as text', () {
      final response = AnthropicClient.parseResponse({
        'content': [
          {'type': 'thinking', 'thinking': 'hmm'},
          {'type': 'text', 'text': 'answer'},
        ],
      });
      expect(response.thinking, 'hmm');
      expect(response.text, 'answer');
    });

    test('hosted providers do not claim to constrain', () {
      expect(OpenAiClient(model: 'x') is LlmStructuredOutput, isFalse);
      expect(AnthropicClient(model: 'x') is LlmStructuredOutput, isFalse);
    });
  });
}

void _promptTests() {
  group('prompts', () {
    test('the frozen prompts are byte for byte what the recorded runs hashed', () {
      // The hashes stored run manifests recorded.
      expect(configHash(Prompts.hybridV4), '52ef31242ab8a27b');
      expect(configHash(Prompts.preparedV1), '955fc9df39376dda');
    });

    test('v5 is v4 plus patterns, and the prepared v2 is v5 plus the briefing paragraph', () {
      expect(Prompts.hybridV5, startsWith(Prompts.hybridV4));
      expect(Prompts.hybridV5, contains('Look up, then act'));
      expect(Prompts.preparedV2, startsWith(Prompts.hybridV5));
      expect(Prompts.preparedV2, contains('Your first message contains a briefing'));
      expect(Prompts.preparedV1, isNot(contains('Working patterns')), reason: 'a frozen prompt is not edited');
    });

    test('agent.prompt picks the version, and the manifest says which', () {
      final agent = HybridAgent(
        client: FakeLlmClient(),
        config: const AgentConfig(prompt: 'hybrid_v5'),
      );
      expect(agent.promptVersion, 'hybrid_v5');
      expect(agent.systemPrompt, Prompts.hybridV5);
      expect(agent.manifest.metadata['promptHash'], configHash(Prompts.hybridV5));
      expect(HybridAgent(client: FakeLlmClient()).promptVersion, 'hybrid_v4');
    });

    test('a prompt of another family, or one that does not exist, is refused at build time', () {
      expect(
        () => HybridAgent(
          client: FakeLlmClient(),
          config: const AgentConfig(prompt: 'prepared_v2'),
        ),
        throwsArgumentError,
      );
      expect(
        () => HybridAgent(
          client: FakeLlmClient(),
          config: const AgentConfig(prompt: 'hybrid_v9'),
        ),
        throwsArgumentError,
      );
      expect(
        () => AgentProfile.build('intent', {
          'agent': {'prompt': 'hybrid_v5'},
        }, client: FakeLlmClient()),
        throwsArgumentError,
      );
    });

    test('the prepared agent takes its own family', () {
      final agent = AgentProfile.build('prepared', {
        'agent': {'prompt': 'prepared_v2'},
        'preparation': {
          'strategy': 'lexical',
          'prepare': ['tools'],
        },
      }, client: FakeLlmClient());
      expect(agent.promptVersion, 'prepared_v2');
      expect(agent.systemPrompt, Prompts.preparedV2);
    });
  });
}

void _exampleTests() {
  const describeSent = Envelope(key: 'intents.describe', kind: .observe);

  EnvelopeResult described(List<JsonMap> intents) => EnvelopeResult(status: .ok, payload: {'intents': intents});

  LlmTool tool(IntentStrategy strategy, String name) => strategy.tools.firstWhere((t) => t.name == name);

  final withExamples = {
    'name': 'todo.find',
    'description': 'Finds todos.',
    'kind': 'observe',
    'examples': [
      {
        'when': 'Show me what is overdue',
        'params': {'overdue': true},
      },
      {
        'params': {'query': 'Steuer'},
      },
      {
        'params': {'tag': 'home'},
      },
      {
        'params': {'priority': 'high'},
      },
    ],
  };

  group('examples', () {
    test('an intent\'s published examples join its tool description when switched on', () {
      final strategy = IntentStrategy(examples: const ExamplesConfig(intents: true));
      strategy.onResult(describeSent, described([withExamples]));
      final description = tool(strategy, 'intent_todo_find').description;
      expect(description, startsWith('Finds todos.'));
      expect(description, contains('- "Show me what is overdue" -> {"overdue":true}'));
      expect(description, contains('- {"query":"Steuer"}'));
    });

    test('at most three, because they are re-sent every turn', () {
      final strategy = IntentStrategy(examples: const ExamplesConfig(intents: true));
      strategy.onResult(describeSent, described([withExamples]));
      expect(tool(strategy, 'intent_todo_find').description, isNot(contains('high')));
    });

    test('switched off, the description is the app\'s own, byte for byte', () {
      final strategy = IntentStrategy();
      strategy.onResult(describeSent, described([withExamples]));
      expect(tool(strategy, 'intent_todo_find').description, 'Finds todos.');
    });

    test('a malformed example is skipped, not fatal', () {
      final strategy = IntentStrategy(examples: const ExamplesConfig(intents: true));
      strategy.onResult(
        describeSent,
        described([
          {
            'name': 'x.y',
            'description': 'Does y.',
            'examples': [
              'not a map',
              {'when': 'no params'},
            ],
          },
        ]),
      );
      expect(tool(strategy, 'intent_x_y').description, 'Does y.');
    });

    test('the framework\'s own tools carry a worked call only when asked to', () async {
      final plain = IntentStrategy().tools.first.description;
      final shown = IntentStrategy(examples: const ExamplesConfig(tools: true)).tools.first.description;
      expect(shown, startsWith(plain));
      expect(shown, contains('Example'));
      expect(UserStrategy().tools.single.description, isNot(contains('Example')));
      expect(UserStrategy(examples: const ExamplesConfig(tools: true)).tools.single.description, contains('Example'));

      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      );
      await _firstModelTurn(
        IntentAgent(
          client: llm,
          config: const AgentConfig(examples: ExamplesConfig(tools: true)),
        ),
      );
      expect(llm.requests.single.tools.firstWhere((t) => t.name == 'done').parameters.toString(), contains('overdue invoices'));
    });

    test('the hybrid agent hands its examples setting to the strategies it owns', () async {
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([('done', <String, Object?>{})]),
        ],
      );
      final agent = HybridAgent(
        client: llm,
        config: const AgentConfig(parallelToolCalls: false, examples: ExamplesConfig(tools: true)),
      );
      await _firstModelTurn(agent);
      final byName = {for (final tool in llm.requests.single.tools) tool.name: tool};
      expect(byName['describe_intents']!.description, contains('Example'));
      expect(byName['ask_user']!.description, contains('Example'));
    });
  });
}
