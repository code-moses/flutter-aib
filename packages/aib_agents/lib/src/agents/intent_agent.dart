import 'package:aib_core/ports.dart';

import '../llm/llm_client.dart';
import 'prompts.dart';
import 'strategies.dart';
import 'tool_loop_agent.dart';

/// Reference agent for the intent strategy (spec §7): discovers the app's
/// intent catalog at episode start, describes the intents it needs and
/// presents those to the model as function-calling tools
/// (`agent.toolSurface`). Acts exclusively via `intents.invoke`.
///
/// The catalog handling lives in [IntentStrategy], shared with the hybrid
/// agent.
final class IntentAgent extends ToolLoopAgent {
  IntentAgent({required super.client, super.config, super.configBlocks, super.embeddingClient, super.decisions});

  late final ToolStrategy _strategy = intentStrategyFor(config);

  @override
  String get agentId => 'intent';

  @override
  String get promptVersion => switch (config.toolSurface) {
    .promoted => 'intent_v3',
    .fixed => 'intent_v4',
  };

  @override
  String get systemPrompt => switch (config.toolSurface) {
    .promoted => Prompts.intentV3,
    .fixed => Prompts.intentV4,
  };

  /// tool name for an intent name (tool names must be identifier-safe).
  static String toolNameFor(String intentName) => IntentStrategy.toolNameFor(intentName);

  @override
  List<LlmTool> get strategyTools => _strategy.tools;

  @override
  Future<void> startEpisode(TaskSpec task, EnvironmentDescriptor environment) async {
    _strategy.reset();
    await super.startEpisode(task, environment);
  }

  @override
  Envelope? bootstrapEnvelope() => _strategy.bootstrap;

  @override
  String describeResult(Envelope sent, EnvelopeResult result) => _strategy.describeResult(sent, result) ?? super.describeResult(sent, result);

  @override
  void onResult(Envelope sent, EnvelopeResult result) => _strategy.onResult(sent, result);

  @override
  bool pinsResult(Envelope sent, EnvelopeResult result) => _strategy.pins(sent, result);

  @override
  Envelope? mapToolCall(LlmToolCall call) => _strategy.map(call);
}
