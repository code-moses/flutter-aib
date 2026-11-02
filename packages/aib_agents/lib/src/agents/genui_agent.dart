import 'package:aib_core/ports.dart';

import '../llm/llm_client.dart';
import 'agent_config.dart';
import 'prompts.dart';
import 'strategies.dart';
import 'tool_loop_agent.dart';

/// Reference agent for the generative-UI strategy (spec §7): no UI control —
/// it observes the app's data context and renders a surface as a batch of
/// A2UI v0.9 messages (see aib_flutter GenUiBridge, ADR 0012). Evaluated via
/// `artifactRubric`.
final class GenUiAgent extends ToolLoopAgent {
  GenUiAgent({
    required super.client,
    super.config = const AgentConfig(maxCompletionTokens: defaultMaxCompletionTokens),
    super.configBlocks,
    super.embeddingClient,
    super.decisions,
  });

  /// Without an `agent.maxCompletionTokens`. A2UI batches are bigger than tool
  /// calls, and one cut off at the limit renders nothing, so a config for
  /// complex surfaces should set this high.
  static const defaultMaxCompletionTokens = 4096;

  final GenUiStrategy _strategy = GenUiStrategy();

  @override
  String get agentId => 'genui';

  @override
  String get promptVersion => 'genui_v2';

  @override
  String get systemPrompt => Prompts.genuiV2;

  @override
  List<LlmTool> get strategyTools => _strategy.tools;

  @override
  Envelope? bootstrapEnvelope() => _strategy.bootstrap;

  @override
  Envelope? mapToolCall(LlmToolCall call) => _strategy.map(call);
}
