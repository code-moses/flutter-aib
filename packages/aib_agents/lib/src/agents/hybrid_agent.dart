import 'package:aib_core/ports.dart';

import '../llm/llm_client.dart';
import 'agent_config.dart';
import 'prompts.dart';
import 'router_config.dart';
import 'strategies.dart';
import 'tool_loop_agent.dart';

/// The hybrid agent, the one an application ships.
///
/// It extends the same [ToolLoopAgent] as the three single-strategy agents, so
/// the only thing the comparison varies is the routing. It differs in three
/// ways:
///
/// 1. its tools are the union (or, in cascade mode, the current step) of the
/// enabled
///    strategies' tools, the same [ToolStrategy] objects the reference agents use;
/// 2. it records which strategy each envelope came from, and why, in
///    `AgentDecision.note`, which feeds the routing metrics;
/// 3. it rebuilds its tool list whenever an `intents.catalog` observation
/// arrives.
///
/// Everything instance-specific reaches it as an observation.
///
/// `base` rather than `final`: `PreparingAgent` extends it.
base class HybridAgent extends ToolLoopAgent {
  HybridAgent({
    required super.client,
    this.router = const RouterConfig(),
    // One tool call at a time: queued calls run back to back without the model
    // seeing the results in between. Explicit so the manifest records it.
    super.config = const AgentConfig(parallelToolCalls: false),
    super.configBlocks,
    super.embeddingClient,
    super.decisions,
  }) {
    // A prompt name that does not exist, or belongs to another agent, is a
    // config error to hear about now.
    systemPrompt;
  }

  final RouterConfig router;

  late final Map<String, ToolStrategy> _strategies = {
    for (final strategy in [intentStrategyFor(config), GenUiStrategy(), UserStrategy(examples: config.examples), SemanticsStrategy()])
      if (router.enables(strategy.name)) strategy.name: strategy,
  };

  /// Cascade mode only: the strategy currently offered.
  late String _activeStrategy = router.escalateFrom;

  /// Which strategy produced the envelope about to be emitted, and why.
  String? _route;
  String? _routeReason;

  @override
  String get agentId => 'hybrid';

  /// The prompt version used when `agent.prompt` names none.
  String get defaultPromptVersion => switch (config.toolSurface) {
    .promoted => 'hybrid_v4',
    .fixed => 'hybrid_v6',
  };

  /// The frozen prompts `agent.prompt` may name for this agent, under its
  /// tool surface.
  Map<String, String> get promptFamily => Prompts.hybridFamily[config.toolSurface]!;

  @override
  String get promptVersion => config.prompt ?? defaultPromptVersion;

  @override
  String get systemPrompt =>
      promptFamily[promptVersion] ??
      (throw ArgumentError(
        'agent.prompt "$promptVersion" is not a prompt of the $agentId agent '
        'under toolSurface ${config.toolSurface.name} (${promptFamily.keys.join(', ')})',
      ));

  @override
  JsonMap get manifestMetadata => {
    'routerConfigHash': router.hash,
    'routerConfig': router.toJson(),
    // The app's catalog is data, not code, so its *shape* is what has to
    // match between a benchmark run and a shipped build; the app fills this
    // in from the catalog it builds.
    'catalogSchemaVersion': catalogSchemaVersion,
  };

  /// Which catalogue contract the agent speaks. Overridden by the app to the
  /// version of its own catalog builder; a run whose two disagree is a run
  /// against an agent that cannot read what it was given.
  ///
  /// `2` added the capability delta: a result may carry `capabilities`
  /// `{added, removed}` and the tool surface moves during an episode
  /// (ADR 0013). `3` makes `intents.catalog` a summary listing and
  /// `intents.describe` the way to a schema. Neither compares with the one
  /// before it.
  String get catalogSchemaVersion => '3';

  Iterable<ToolStrategy> get _enabled =>
      router.mode == .cascade ? [?_strategies[_activeStrategy]] : router.strategies.map((name) => _strategies[name]).nonNulls;

  @override
  List<LlmTool> get strategyTools => [for (final strategy in _enabled) ...strategy.tools];

  @override
  Future<void> startEpisode(TaskSpec task, EnvironmentDescriptor environment) async {
    for (final strategy in _strategies.values) {
      strategy.reset();
    }
    _activeStrategy = router.escalateFrom;
    _route = null;
    _routeReason = null;
    await super.startEpisode(task, environment);
  }

  @override
  Envelope? bootstrapEnvelope() {
    for (final strategy in _enabled) {
      final bootstrap = strategy.bootstrap;
      if (bootstrap != null && bootstrap.key == router.bootstrap) {
        _route = strategy.name;
        _routeReason = 'bootstrap';
        return bootstrap;
      }
    }
    // The configured bootstrap key belongs to no enabled strategy — emit it
    // anyway rather than silently starting blind, so the mismatch shows up
    // as an `unsupported` in the trace instead of as a bad first move.
    _route = null;
    return Envelope(key: router.bootstrap, kind: .observe);
  }

  @override
  Envelope? mapToolCall(LlmToolCall call) {
    for (final strategy in _enabled) {
      final envelope = strategy.map(call);
      if (envelope != null) {
        _route = strategy.name;
        return envelope;
      }
    }
    return null;
  }

  @override
  String describeResult(Envelope sent, EnvelopeResult result) {
    for (final strategy in _strategies.values) {
      final rendered = strategy.describeResult(sent, result);
      if (rendered != null) return rendered;
    }
    return super.describeResult(sent, result);
  }

  @override
  bool pinsResult(Envelope sent, EnvelopeResult result) => _strategies.values.any((strategy) => strategy.pins(sent, result));

  @override
  void onResult(Envelope sent, EnvelopeResult result) {
    // Every strategy sees every result: the intent strategy has to rebuild
    // its catalog even when the last call was a semantics tap that navigated.
    for (final strategy in _strategies.values) {
      strategy.onResult(sent, result);
    }

    if (router.mode != .cascade) return;
    if (_activeStrategy != router.escalateFrom) return;
    if (!router.escalateOn.contains(result.status.name)) return;
    if (_strategies[router.escalateTo] == null) return;

    _activeStrategy = router.escalateTo;
    _routeReason =
        'escalation from ${router.escalateFrom} '
        'on ${result.status.name}';
  }

  /// Rides on every envelope, so the routing metric family
  /// (`strategy_share.*`, `strategy_switch_count`, `escalation_rate`) is a
  /// pure trace derivation and needs no extra instrumentation.
  @override
  String? get pendingNote {
    final route = _route;
    if (route == null && _routeReason == null) return null;
    final reason = _routeReason;
    _routeReason = null;
    return ['route=${route ?? 'none'}', if (reason != null) 'reason=$reason'].join(' ');
  }
}
