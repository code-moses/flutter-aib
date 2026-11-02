import 'package:aib_core/ports.dart';

import '../llm/llm_client.dart';
import 'prompts.dart';
import 'strategies.dart';
import 'tool_loop_agent.dart';

/// Reference agent for the semantics strategy (spec §7): observes via
/// `semantics.tree`, acts via `semantics.tap/setText/scroll`. Tools and mapping
/// live in [SemanticsStrategy] so the hybrid agent offers the identical
/// surface.
final class SemanticsAgent extends ToolLoopAgent {
  SemanticsAgent({required super.client, super.config, super.configBlocks, super.embeddingClient, super.decisions});

  final SemanticsStrategy _strategy = SemanticsStrategy();

  @override
  String get agentId => 'semantics';

  @override
  String get promptVersion => 'semantics_v2';

  @override
  String get systemPrompt => Prompts.semanticsV2;

  @override
  List<LlmTool> get strategyTools => _strategy.tools;

  @override
  Envelope? bootstrapEnvelope() => _strategy.bootstrap;

  @override
  Envelope? mapToolCall(LlmToolCall call) => _strategy.map(call);
}
