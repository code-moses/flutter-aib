import 'dart:convert';

import 'package:aib_core/ports.dart';

import '../llm/llm_client.dart';
import 'agent_config.dart';

/// [description] followed by the examples an app published for the intent, when
/// [examples] says to show them.
///
/// An example is `{params, when?}`: the arguments of a good call and, optionally,
/// the request it answers.
String _describedWith(String description, Object? rawExamples, ExamplesConfig examples) {
  if (!examples.intents || rawExamples is! List || rawExamples.isEmpty) return description;
  final lines = [
    for (final raw in rawExamples.take(IntentStrategy.maxExamples))
      if (raw case {'params': final Map params, 'when': final String request})
        '- "$request" -> ${jsonEncode(params)}'
      else if (raw case {'params': final Map params})
        '- ${jsonEncode(params)}',
  ];
  return lines.isEmpty ? description : '$description\nExample arguments:\n${lines.join('\n')}';
}

/// One interaction strategy's tool surface, factored out of the agent that uses
/// it. Sharing these objects is what guarantees the hybrid agent offers the
/// same tools with the same descriptions as the single-strategy agents.
abstract base class ToolStrategy {
  /// Key prefix the strategy owns (`semantics`, `intents`, `genui`, `user`).
  /// Also the value recorded as `route=` in the trace.
  String get name;

  /// The strategy's tool surface. May change during an episode (the intent
  /// catalog does).
  List<LlmTool> get tools;

  /// Maps one of *this strategy's* tool calls to an envelope; null when the
  /// call belongs to another strategy.
  Envelope? map(LlmToolCall call);

  /// Deterministic first observation this strategy would make, if any.
  Envelope? get bootstrap => null;

  /// Lets the strategy learn from results (the intent catalog rebuilds its
  /// tools here).
  void onResult(Envelope sent, EnvelopeResult result) {}

  /// Optional custom rendering of a result for the model; null = default.
  String? describeResult(Envelope sent, EnvelopeResult result) => null;

  /// See [ToolLoopAgent.pinsResult].
  bool pins(Envelope sent, EnvelopeResult result) => false;

  void reset() {}
}

/// Drives the app through its accessibility tree.
final class SemanticsStrategy extends ToolStrategy {
  @override
  String get name => 'semantics';

  static const _targetProperties = {
    'nodeId': {'type': 'integer', 'description': 'Node id from the most recent tree observation.'},
    'label': {'type': 'string', 'description': 'Exact node label (or tooltip) — alternative to nodeId.'},
  };

  @override
  List<LlmTool> get tools => const [
    LlmTool(
      name: 'observe_tree',
      description:
          'Read the current semantics tree of the app '
          '(pruned to labelled and interactive nodes).',
    ),
    LlmTool(name: 'tap', description: 'Tap a node.', parameters: {'type': 'object', 'properties': _targetProperties}),
    LlmTool(
      name: 'set_text',
      description: 'Replace the content of a text field.',
      parameters: {
        'type': 'object',
        'properties': {
          ..._targetProperties,
          'text': {'type': 'string'},
        },
        'required': ['text'],
      },
    ),
    LlmTool(
      name: 'scroll',
      description: 'Scroll a scrollable node.',
      parameters: {
        'type': 'object',
        'properties': {
          ..._targetProperties,
          'direction': {
            'type': 'string',
            'enum': ['up', 'down', 'left', 'right'],
          },
        },
        'required': ['direction'],
      },
    ),
    LlmTool(
      name: 'show_on_screen',
      description:
          'Scroll a node into the visible viewport. Use it when a node '
          'reports "onScreen": false.',
      parameters: {'type': 'object', 'properties': _targetProperties},
    ),
  ];

  @override
  Envelope? get bootstrap => const Envelope(key: 'semantics.tree', kind: .observe);

  @override
  Envelope? map(LlmToolCall call) {
    JsonMap target() => {
      if (call.arguments['nodeId'] != null) 'nodeId': call.arguments['nodeId'],
      if (call.arguments['label'] != null) 'label': call.arguments['label'],
    };
    return switch (call.name) {
      'observe_tree' => const Envelope(key: 'semantics.tree', kind: .observe),
      'tap' => Envelope(key: 'semantics.tap', kind: .act, payload: target()),
      'set_text' => Envelope(key: 'semantics.setText', kind: .act, payload: {...target(), 'text': call.arguments['text']}),
      'scroll' => Envelope(key: 'semantics.scroll', kind: .act, payload: {...target(), 'direction': call.arguments['direction']}),
      'show_on_screen' => Envelope(key: 'semantics.showOnScreen', kind: .act, payload: target()),
      _ => null,
    };
  }
}

/// Drives the app through its declared capability catalog. Stateful: the tool
/// list *is* the catalog, rebuilt whenever an `intents.catalog` observation
/// comes back.
final class IntentStrategy extends ToolStrategy {
  IntentStrategy({this.examples = const ExamplesConfig()});

  /// Which worked examples this strategy adds to the tools it offers.
  final ExamplesConfig examples;

  @override
  String get name => 'intents';

  final Map<String, String> _toolToIntent = {};
  final Map<String, EnvelopeKind> _toolKind = {};
  final Map<String, LlmTool> _toolByName = {};
  List<LlmTool> _tools = const [];

  /// Intent names the catalog last reported in scope. A tool survives a
  /// re-observation only if its intent is still here.
  Set<String> _inScope = const {};

  /// Always offered: without it a described intent can never become a tool.
  static const describeTool = LlmTool(
    name: 'describe_intents',
    description:
        'Read the full description and parameter schema of one or more '
        'intents from the catalog. Each one you name becomes a callable tool '
        'from the next turn on. Name every intent you expect to need in one '
        'call.',
    parameters: {
      'type': 'object',
      'properties': {
        'names': {
          'type': 'array',
          'description': 'Catalog names, e.g. ["form.open", "form.set"]. Not tool names.',
          'items': {'type': 'string'},
        },
      },
      'required': ['names'],
    },
  );

  /// [describeTool] with a worked call naming two intents of different jobs, to
  /// stop a model describing one intent per turn.
  static const describeToolWithExample = LlmTool(
    name: 'describe_intents',
    description:
        'Read the full description and parameter schema of one or more '
        'intents from the catalog. Each one you name becomes a callable tool '
        'from the next turn on. Name every intent you expect to need in one '
        'call. Example: a task that must look something up and then act on '
        'it needs both — names ["<the lookup intent>", "<the intent that acts>"] '
        'in a single call, not one call each.',
    parameters: {
      'type': 'object',
      'properties': {
        'names': {
          'type': 'array',
          'description': 'Catalog names, e.g. ["form.open", "form.set"]. Not tool names.',
          'items': {'type': 'string'},
        },
      },
      'required': ['names'],
    },
  );

  /// The most examples one intent's description carries. They are re-sent every
  /// turn for as long as the tool is offered; three shows the shape of a call
  /// and its variants, a fourth shows the same thing again.
  static const maxExamples = 3;

  /// What every promoted intent's tool name starts with.
  static const toolPrefix = 'intent_';

  /// Tool names must be identifier-safe; catalog names are not. Providers accept
  /// `^[A-Za-z0-9_-]{1,64}$`. A longer name is cut and made unique with a stable
  /// hash of the intent name.
  static String toolNameFor(String intentName) {
    final safe = '$toolPrefix${intentName.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}';
    if (safe.length <= maxToolNameLength) return safe;
    final hash = jsonFingerprint(intentName).substring(0, 8);
    return '${safe.substring(0, maxToolNameLength - hash.length - 1)}_$hash';
  }

  static const maxToolNameLength = 64;

  @override
  List<LlmTool> get tools => [examples.tools ? describeToolWithExample : describeTool, ..._tools];

  @override
  Envelope? get bootstrap => const Envelope(key: 'intents.catalog', kind: .observe);

  @override
  void reset() {
    _toolToIntent.clear();
    _toolKind.clear();
    _toolByName.clear();
    _inScope = const {};
    _tools = const [];
  }

  /// Drops tools whose intent the catalog no longer reports in scope.
  void _retainInScope() {
    for (final toolName in _toolToIntent.keys.toList()) {
      if (!_inScope.contains(_toolToIntent[toolName])) {
        _toolToIntent.remove(toolName);
        _toolKind.remove(toolName);
        _toolByName.remove(toolName);
      }
    }
    _tools = List.unmodifiable(_toolByName.values);
  }

  /// Folds catalog entries into the tool surface, in the order the app
  /// published them.
  void _ingest(List<Object?> intents) {
    for (final raw in intents) {
      final intent = asJsonMap(raw);
      final name = intent['name'] as String?;
      if (name == null) continue;
      final toolName = toolNameFor(name);
      _toolToIntent[toolName] = name;
      _toolKind[toolName] = switch (intent['kind']) {
        'observe' => EnvelopeKind.observe,
        _ => EnvelopeKind.act,
      };
      _toolByName[toolName] = LlmTool(
        name: toolName,
        description: _describedWith(intent['description'] as String? ?? name, intent['examples'], examples),
        parameters: objectSchema(intent['paramsSchema']),
      );
    }
    _tools = List.unmodifiable(_toolByName.values);
  }

  void _drop(List<Object?> names) {
    for (final raw in names) {
      final toolName = toolNameFor('$raw');
      _toolToIntent.remove(toolName);
      _toolKind.remove(toolName);
      _toolByName.remove(toolName);
    }
    _tools = List.unmodifiable(_toolByName.values);
  }

  @override
  void onResult(Envelope sent, EnvelopeResult result) {
    // The catalog lists what is in scope and carries no schemas, so it only
    // bounds which tools may survive.
    if (sent.key == 'intents.catalog') {
      if (result.status != .ok) return;
      _inScope = {
        for (final raw in result.payload['intents'] as List? ?? const [])
          if (asJsonMap(raw)['name'] case final String name) name,
      };
      _retainInScope();
      return;
    }

    // Asking about an intent is what makes it callable.
    if (sent.key == 'intents.describe') {
      if (result.status != .ok) return;
      final described = result.payload['intents'] as List? ?? const [];
      _inScope = {
        ..._inScope,
        for (final raw in described)
          if (asJsonMap(raw)['name'] case final String name) name,
      };
      _ingest(described);
      return;
    }

    // A capability delta may ride on *any* result, including another
    // strategy's: a semantics tap that opens a form grows the intent surface.
    // That is why the hybrid agent hands every result to every strategy.
    if (asJsonMap(result.payload['capabilities']) case final delta when delta.isNotEmpty) {
      final added = delta['added'] as List? ?? const [];
      final removed = delta['removed'] as List? ?? const [];
      // A delta still carries full entries and still becomes a tool without a
      // turn being spent (ADR 0013). It is already narrow — what the app just
      // made available — which is the filter the catalog listing lacks.
      _inScope = {
        ..._inScope,
        for (final raw in added)
          if (asJsonMap(raw)['name'] case final String name) name,
      }..removeAll([for (final name in removed) '$name']);
      _ingest(added);
      _drop(removed);
    }
  }

  /// An app's parameter schema as a tool schema every provider accepts.
  ///
  /// A parameterless intent publishes `paramsSchema: {}` or none at all, and
  /// Anthropic rejects the whole request for that. Normalised here rather than
  /// in that client so every provider sees the same tools.
  static JsonMap objectSchema(Object? schema) {
    final map = schema is Map ? asJsonMap(schema) : const <String, Object?>{};
    if (map['type'] != null) return map;
    return {'type': 'object', 'properties': const <String, Object?>{}, ...map};
  }

  /// Renders a capability delta as the tool names it produced, and nothing
  /// else. The schemas it carries go into the tool definitions; repeating them
  /// would send them twice.
  String _describeCapabilities(EnvelopeResult result, JsonMap delta) {
    final rest = {...result.payload}..remove('capabilities');
    return jsonEncode({
      if (result.status != .ok) 'status': result.status.name,
      'error': ?result.error?.toJson(),
      ...rest,
      'newCapabilities': {
        if (delta['added'] case final List added when added.isNotEmpty)
          'available': [
            for (final raw in added)
              if (asJsonMap(raw)['name'] case final String name) toolNameFor(name),
          ],
        if (delta['removed'] case final List removed when removed.isNotEmpty) 'gone': [for (final name in removed) toolNameFor('$name')],
        'note':
            'These tools are available from now on; their parameters are in '
            'their tool definitions.',
      },
    });
  }

  /// Renders the catalog as what the model cannot read anywhere else: the tool
  /// name each intent is exposed under (see [Prompts.intentV3]), the name, the
  /// `kind`, and the app's `metadata`. Description and schema are already in
  /// the tool definitions.
  ///
  /// The *payload* is untouched: [onResult] builds tool definitions from it.
  @override
  String? describeResult(Envelope sent, EnvelopeResult result) {
    if (sent.key == 'intents.describe') {
      if (result.status != .ok) return null;
      // Names only: the descriptions and schemas just asked for arrive as
      // tool definitions, and saying them twice is what the split removes.
      return jsonEncode({
        'nowCallable': [
          for (final raw in result.payload['intents'] as List? ?? const [])
            if (asJsonMap(raw)['name'] case final String name) {'tool': toolNameFor(name), 'intent': name},
        ],
        if (result.payload['unknown'] case final List unknown when unknown.isNotEmpty) 'notAvailableHere': unknown,
        // ADR 0016: an intent named here was not asked for — it is what one
        // that was needs — and is already among nowCallable, at no extra turn.
        if (result.payload['autoIncluded'] case final List also when also.isNotEmpty) 'alsoCallable': also,
        'note':
            'Their parameters are in their tool definitions. Call the tool '
            'name, not the intent name.',
      });
    }
    if (sent.key != 'intents.catalog') {
      // Claimed from whichever strategy owns the envelope, because only this
      // one knows what a capability delta means. The rest of the payload is
      // rendered unchanged, so the owning strategy loses nothing.
      if (asJsonMap(result.payload['capabilities']) case final delta when delta.isNotEmpty) {
        return _describeCapabilities(result, delta);
      }
      return null;
    }
    if (result.status != .ok || result.payload['intents'] is! List) {
      return null;
    }
    final intents = result.payload['intents'] as List;
    final rest = {...result.payload}..remove('intents');
    return jsonEncode({
      ...rest,
      'note':
          'This is the whole catalog, summarised. None of these is callable '
          'yet: pass the names you need to describe_intents, in one call, and '
          'they become tools.',
      'intents': [
        for (final raw in intents)
          if (asJsonMap(raw)['name'] case final String name)
            {
              'name': name,
              if (asJsonMap(raw)['summary'] case final Object summary) 'summary': summary,
              if (asJsonMap(raw)['kind'] case final Object kind) 'kind': kind,
              if (asJsonMap(raw)['metadata'] case final Map<String, Object?> m when m.isNotEmpty) 'metadata': m,
            },
      ],
    });
  }

  @override
  Envelope? map(LlmToolCall call) {
    if (call.name == describeTool.name) {
      return Envelope(key: 'intents.describe', kind: .observe, payload: {'names': call.arguments['names'] ?? const []});
    }
    final intentName = _toolToIntent[call.name];
    if (intentName == null) return null;
    return Envelope(
      key: 'intents.invoke',
      // The agent declares what the catalog said. The environment decides
      // for real; this declaration is what `kind_integrity_violations`
      // checks it against, so a catalog that lies is visible in the report.
      kind: _toolKind[call.name] ?? EnvelopeKind.act,
      payload: {'intent': intentName, 'params': call.arguments},
    );
  }
}

/// [IntentStrategy] for runtimes that render tool definitions at the top of the
/// prompt, selected by `agent.toolSurface: fixed`.
///
/// Every catalog intent is a typed tool from the first model call, carrying its
/// one-line summary; `describe_intents` writes the parameters into the
/// conversation. Describing must not change the tool list, or all of the prompt
/// is re-prefilled. Only a capability delta adds tools.
final class FixedSurfaceIntentStrategy extends ToolStrategy {
  FixedSurfaceIntentStrategy({this.examples = const ExamplesConfig()});

  /// Which worked examples this strategy adds to what it describes.
  final ExamplesConfig examples;

  @override
  String get name => 'intents';

  /// Every intent this episode has heard of, with the kind the app declared.
  final Map<String, EnvelopeKind> _kinds = {};

  /// Tool name to intent, in the order the tools were first offered.
  final Map<String, String> _toolToIntent = {};
  final Map<String, LlmTool> _toolByName = {};

  static const describeTool = LlmTool(
    name: 'describe_intents',
    description:
        'Read the full description and parameter schema of one or more '
        'intents from the catalog, before calling their intent_* tools. '
        'Name every intent you expect to need in one call.',
    parameters: {
      'type': 'object',
      'properties': {
        'names': {
          'type': 'array',
          'description': 'Catalog names, e.g. ["form.open", "form.set"].',
          'items': {'type': 'string'},
        },
      },
      'required': ['names'],
    },
  );

  /// [describeTool] with a worked call. The example names two intents of
  /// different jobs and says why they go together, because the failure it
  /// answers is a model that describes one intent per turn.
  static const describeToolWithExample = LlmTool(
    name: 'describe_intents',
    description:
        'Read the full description and parameter schema of one or more '
        'intents from the catalog, before calling their intent_* tools. '
        'Name every intent you expect to need in one call. Example: a task '
        'that must look something up and then act on it needs both — names '
        '["<the lookup intent>", "<the intent that acts>"] in a single call, '
        'not one call each.',
    parameters: {
      'type': 'object',
      'properties': {
        'names': {
          'type': 'array',
          'description': 'Catalog names, e.g. ["form.open", "form.set"].',
          'items': {'type': 'string'},
        },
      },
      'required': ['names'],
    },
  );

  @override
  List<LlmTool> get tools => [examples.tools ? describeToolWithExample : describeTool, ..._toolByName.values];

  @override
  Envelope? get bootstrap => const Envelope(key: 'intents.catalog', kind: .observe);

  @override
  void reset() {
    _kinds.clear();
    _toolToIntent.clear();
    _toolByName.clear();
  }

  /// Offers [intent] as a tool unless it already is one: a tool's definition
  /// never changes once offered.
  void _offer(JsonMap intent, {required bool withSchema}) {
    final name = intent['name'];
    if (name is! String) return;
    final toolName = IntentStrategy.toolNameFor(name);
    if (_toolByName.containsKey(toolName)) return;
    _toolToIntent[toolName] = name;
    _toolByName[toolName] = withSchema
        ? LlmTool(
            name: toolName,
            description: _describedWith(intent['description'] as String? ?? name, intent['examples'], examples),
            parameters: IntentStrategy.objectSchema(intent['paramsSchema']),
          )
        : LlmTool(
            name: toolName,
            description: '${intent['summary'] ?? name} Read its parameters with describe_intents first.',
            parameters: const {'type': 'object', 'properties': <String, Object?>{}, 'additionalProperties': true},
          );
  }

  void _learn(Iterable<Object?> intents) {
    for (final raw in intents) {
      final intent = asJsonMap(raw);
      if (intent['name'] case final String name) {
        _kinds[name] = intent['kind'] == 'observe' ? EnvelopeKind.observe : EnvelopeKind.act;
      }
    }
  }

  @override
  void onResult(Envelope sent, EnvelopeResult result) {
    if (result.status != .ok && sent.key != 'intents.invoke') return;
    if (sent.key == 'intents.catalog' || sent.key == 'intents.describe') {
      final intents = result.payload['intents'] as List? ?? const [];
      _learn(intents);
      if (sent.key == 'intents.catalog') {
        for (final raw in intents) {
          _offer(asJsonMap(raw), withSchema: false);
        }
      }
      return;
    }
    // A capability delta may ride on any result, another strategy's too (a
    // semantics tap that opens a form), which is why every strategy sees it.
    // It carries full entries, so its tools come with their schemas.
    if (asJsonMap(result.payload['capabilities']) case final delta when delta.isNotEmpty) {
      final added = delta['added'] as List? ?? const [];
      _learn(added);
      for (final raw in added) {
        _offer(asJsonMap(raw), withSchema: true);
      }
    }
  }

  /// A describe result is where a catalog intent's schema is written down,
  /// so it outlives the observation window.
  @override
  bool pins(Envelope sent, EnvelopeResult result) => sent.key == 'intents.describe' && result.status == .ok;

  /// One intent as the model reads it: the tool to call and its parameters.
  JsonMap _entry(Object? raw) {
    final intent = asJsonMap(raw);
    return {
      'tool': IntentStrategy.toolNameFor('${intent['name']}'),
      'intent': intent['name'],
      if (intent['kind'] != null) 'kind': intent['kind'],
      'description': _describedWith(intent['description'] as String? ?? '${intent['name']}', intent['examples'], examples),
      'params': IntentStrategy.objectSchema(intent['paramsSchema']),
      if (asJsonMap(intent['metadata']) case final m when m.isNotEmpty) 'metadata': m,
    };
  }

  /// The tools a delta added — their schemas are in their definitions — and
  /// the intents it removed.
  String _describeCapabilities(EnvelopeResult result, JsonMap delta) {
    final rest = {...result.payload}..remove('capabilities');
    return jsonEncode({
      if (result.status != .ok) 'status': result.status.name,
      'error': ?result.error?.toJson(),
      ...rest,
      'newCapabilities': {
        if (delta['added'] case final List added when added.isNotEmpty)
          'available': [
            for (final raw in added)
              if (asJsonMap(raw)['name'] case final String name) IntentStrategy.toolNameFor(name),
          ],
        if (delta['removed'] case final List removed when removed.isNotEmpty)
          'gone': [for (final name in removed) IntentStrategy.toolNameFor('$name')],
        'note': 'These tools are available from now on; their parameters are in their tool definitions.',
      },
    });
  }

  /// The catalog as names, kinds and metadata; each summary is already the
  /// description of the intent's tool. Schemas come from describe_intents.
  @override
  String? describeResult(Envelope sent, EnvelopeResult result) {
    if (sent.key == 'intents.describe') {
      if (result.status != .ok) return null;
      return jsonEncode({
        'intents': [for (final raw in result.payload['intents'] as List? ?? const []) _entry(raw)],
        if (result.payload['unknown'] case final List unknown when unknown.isNotEmpty) 'notAvailableHere': unknown,
        // ADR 0016: an intent named here was not asked for — it is what one
        // that was needs — and is already described above, at no extra turn.
        if (result.payload['autoIncluded'] case final List also when also.isNotEmpty) 'alsoDescribed': also,
        'note': 'Call each by its tool name, with params matching its schema.',
      });
    }
    if (sent.key != 'intents.catalog') {
      // Claimed from whichever strategy owns the envelope, because only this
      // one knows what a capability delta means.
      if (asJsonMap(result.payload['capabilities']) case final delta when delta.isNotEmpty) {
        return _describeCapabilities(result, delta);
      }
      return null;
    }
    if (result.status != .ok || result.payload['intents'] is! List) {
      return null;
    }
    final intents = result.payload['intents'] as List;
    final rest = {...result.payload}..remove('intents');
    return jsonEncode({
      ...rest,
      'note':
          'This is the whole catalog. Every intent is already a tool (intent '
          '"form.set" is the tool "intent_form_set"), summarised in its tool '
          'definition. Pass the names you need to describe_intents, in one '
          'call, to read their parameters before calling them.',
      'intents': [
        for (final raw in intents)
          if (asJsonMap(raw)['name'] case final String name)
            {
              'name': name,
              if (asJsonMap(raw)['kind'] case final Object kind) 'kind': kind,
              if (asJsonMap(raw)['metadata'] case final Map<String, Object?> m when m.isNotEmpty) 'metadata': m,
            },
      ],
    });
  }

  @override
  Envelope? map(LlmToolCall call) {
    if (call.name == describeTool.name) {
      return Envelope(key: 'intents.describe', kind: .observe, payload: {'names': call.arguments['names'] ?? const []});
    }
    // A model sometimes calls an intent by its catalog name instead of its
    // tool name; if the episode knows the intent, that is what it means.
    final intent = _toolToIntent[call.name] ?? (_kinds.containsKey(call.name) ? call.name : null);
    if (intent == null) return null;
    return Envelope(
      key: 'intents.invoke',
      // The agent declares what the catalog said. The environment decides
      // for real; this declaration is what `kind_integrity_violations`
      // checks it against, so a catalog that lies is visible in the report.
      kind: _kinds[intent] ?? EnvelopeKind.act,
      payload: {'intent': intent, 'params': call.arguments},
    );
  }
}

/// The intent strategy [config] asks for ([AgentConfig.toolSurface]).
ToolStrategy intentStrategyFor(AgentConfig config) => switch (config.toolSurface) {
  .promoted => IntentStrategy(examples: config.examples),
  .fixed => FixedSurfaceIntentStrategy(examples: config.examples),
};

/// Answers by rendering a surface rather than by operating the app.
final class GenUiStrategy extends ToolStrategy {
  @override
  String get name => 'genui';

  @override
  List<LlmTool> get tools => const [
    LlmTool(name: 'observe_data', description: 'Re-read the app data context.'),
    LlmTool(
      name: 'observe_ui_catalog',
      description:
          'Read the A2UI component catalog this app renders: catalog id, '
          'the component type names you may use and the app\'s own rules for '
          'them. Read it before rendering.',
    ),
    LlmTool(
      name: 'describe_ui_components',
      description:
          'Read the property schemas of the component types you intend to '
          'use. Name them all in one call.',
      parameters: {
        'type': 'object',
        'properties': {
          'components': {
            'type': 'array',
            'description': 'Component type names, e.g. ["Column", "Text"].',
            'items': {'type': 'string'},
          },
        },
        'required': ['components'],
      },
    ),
    LlmTool(
      name: 'render_ui',
      description:
          'Render a UI surface by sending a batch of A2UI v0.9 messages. '
          'One call carries the whole surface: a createSurface message '
          'followed by an updateComponents message whose components include '
          'the root.',
      parameters: {
        'type': 'object',
        'properties': {
          'messages': {
            'type': 'array',
            'description':
                'A2UI v0.9 messages, applied in order. Each is '
                '{version: "v0.9"} plus exactly one of createSurface '
                '{surfaceId, catalogId}, updateComponents {surfaceId, '
                'components: [{id, component, ...}]}, updateDataModel '
                '{surfaceId, path, value} or deleteSurface {surfaceId}.',
            'items': {'type': 'object'},
          },
        },
        'required': ['messages'],
      },
    ),
  ];

  @override
  Envelope? get bootstrap => const Envelope(key: 'data.context', kind: .observe);

  @override
  Envelope? map(LlmToolCall call) => switch (call.name) {
    'observe_data' => const Envelope(key: 'data.context', kind: .observe),
    'observe_ui_catalog' => const Envelope(key: 'genui.catalog', kind: .observe),
    'describe_ui_components' => Envelope(key: 'genui.describe', kind: .observe, payload: {'components': call.arguments['components'] ?? const []}),
    'render_ui' => Envelope(key: 'genui.render', kind: .act, payload: {'messages': call.arguments['messages']}),
    _ => null,
  };
}

/// Asks the person in front of the app. Its own tool, so the report shows how
/// often each configuration chose to ask.
final class UserStrategy extends ToolStrategy {
  UserStrategy({this.examples = const ExamplesConfig()});

  final ExamplesConfig examples;

  @override
  String get name => 'user';

  @override
  List<LlmTool> get tools => [
    LlmTool(
      name: 'ask_user',
      description:
          'Ask the user a question and wait for the answer. Use it when a '
          'value is genuinely ambiguous — never to avoid reading the app — '
          'and before any effect the user would want to approve.'
          '${examples.tools ? ' Example: two records match the name the user gave — '
                    'type "pick", prompt "Which one do you mean?", and in metadata the '
                    'source and text to search, so the user chooses from the real '
                    'records. Example: before deleting — type "confirm".' : ''}',
      parameters: {
        'type': 'object',
        'properties': {
          'type': {
            'type': 'string',
            'enum': ['confirm', 'choice', 'pick', 'text'],
            'description':
                'confirm = yes/no, choice = pick from "options", '
                'pick = choose a record from the app\'s data, text = free '
                'text.',
          },
          'prompt': {'type': 'string'},
          'options': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'metadata': {
            'type': 'object',
            'description':
                'App-specific context for the picker, e.g. which data '
                'source to search and with what text.',
          },
        },
        'required': ['type', 'prompt'],
      },
    ),
  ];

  @override
  Envelope? map(LlmToolCall call) => call.name == 'ask_user'
      ? Envelope(
          key: 'user.ask',
          kind: .act,
          payload: {
            'type': call.arguments['type'],
            'prompt': call.arguments['prompt'],
            if (call.arguments['options'] != null) 'options': call.arguments['options'],
            if (call.arguments['metadata'] != null) 'metadata': call.arguments['metadata'],
          },
        )
      : null;
}
