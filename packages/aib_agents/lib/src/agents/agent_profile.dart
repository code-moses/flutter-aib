import 'package:aib_core/ports.dart';

import '../llm/embedding_client.dart';
import '../llm/llm_client.dart';
import 'agent_config.dart';
import 'decisions.dart';
import 'genui_agent.dart';
import 'hybrid_agent.dart';
import 'intent_agent.dart';
import 'preparation_config.dart';
import 'preparing_agent.dart';
import 'router_config.dart';
import 'semantics_agent.dart';
import 'tool_loop_agent.dart';

/// Builds a reference agent from an agent config, with the clients supplied by
/// the caller. The harness and an application both build here, so the shipped
/// agent is the measured agent. dart:io-free.
abstract final class AgentProfile {
  static const agents = ['semantics', 'intent', 'genui', 'hybrid', 'prepared'];

  /// The `agent:` block, empty when absent.
  static JsonMap agentSection(JsonMap config) => asJsonMap(config['agent']);

  /// The `router:` block, empty when absent.
  static JsonMap routerSection(JsonMap config) => asJsonMap(config['router']);

  /// Every other map-valued block, for [ToolLoopAgent.configBlocks]: hashed
  /// into the manifest, which is what identifies the arm.
  static JsonMap otherSections(JsonMap config) => {
    for (final entry in config.entries)
      // `cassette` is where answers come from, not what the arm is: it is
      // recorded with the model identity instead.
      if (entry.value is Map && !const {'llm', 'agent', 'router', 'embedding', 'cassette'}.contains(entry.key)) entry.key: entry.value,
  };

  /// [agent] is one of [agents]. [decisions] is required when the config
  /// has a `decisions:` block — building it needs a [JevClient], which is the
  /// caller's to make — and refused when it has none, so a decision model
  /// can never ride along unrecorded.
  static ToolLoopAgent build(String agent, JsonMap config, {required LlmClient client, EmbeddingClient? embeddingClient, AgentDecisions? decisions}) {
    if (config['decisions'] != null && decisions == null) {
      throw ArgumentError('the config has a decisions: block; pass the AgentDecisions built from it');
    }
    if (config['decisions'] == null && decisions != null) {
      throw ArgumentError('decisions passed for a config without a decisions: block — the manifest would not record them');
    }
    final blocks = otherSections(config);
    // `agent.prompt` selects among the hybrid family's frozen prompts. The
    // single-strategy agents have one prompt each, and a config naming one
    // would record a name it did not use.
    if (agentSection(config)['prompt'] != null && agent != 'hybrid' && agent != 'prepared') {
      throw ArgumentError("agent.prompt is a choice among the hybrid and prepared agents' prompts; the $agent agent has one");
    }
    return switch (agent) {
      'semantics' => SemanticsAgent(
        client: client,
        configBlocks: blocks,
        embeddingClient: embeddingClient,
        decisions: decisions,
        config: _agentConfig(config),
      ),
      'intent' => IntentAgent(
        client: client,
        configBlocks: blocks,
        embeddingClient: embeddingClient,
        decisions: decisions,
        config: _agentConfig(config),
      ),
      'genui' => GenUiAgent(
        client: client,
        configBlocks: blocks,
        embeddingClient: embeddingClient,
        decisions: decisions,
        config: _agentConfig(config, defaultMaxCompletionTokens: GenUiAgent.defaultMaxCompletionTokens),
      ),
      'hybrid' => HybridAgent(
        client: client,
        router: RouterConfig.fromJson(routerSection(config)),
        configBlocks: blocks,
        embeddingClient: embeddingClient,
        decisions: decisions,
        config: _agentConfig(config, defaultParallelToolCalls: false),
      ),
      // The hybrid agent with a preparation pass in front of its loop.
      'prepared' => PreparingAgent(
        client: client,
        router: RouterConfig.fromJson(routerSection(config)),
        preparation: PreparationConfig.fromJson(asJsonMap(config['preparation'])),
        configBlocks: blocks,
        embeddingClient: embeddingClient,
        decisions: decisions,
        config: _agentConfig(config, defaultParallelToolCalls: false),
      ),
      _ => throw ArgumentError('unknown agent "$agent" (${agents.join(', ')})'),
    };
  }

  static AgentConfig _agentConfig(JsonMap config, {int? defaultMaxCompletionTokens, bool? defaultParallelToolCalls}) => AgentConfig.fromJson({
    'maxCompletionTokens': ?defaultMaxCompletionTokens,
    'parallelToolCalls': ?defaultParallelToolCalls,
    ...agentSection(config),
  });
}
