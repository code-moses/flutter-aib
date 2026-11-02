/// AI Interaction Benchmark — Layer 3 reference agents (spec §7).
///
/// All strategies share the ToolLoopAgent skeleton; differences are limited to
/// envelope keys, tool set and system prompt.
///
/// The *harness* entry point: adds the config factory and the LLM judge to the
/// app-safe surface in `agents.dart`. Code that ships inside an application
/// imports `package:aib_agents/agents.dart` instead.
library;

export 'agents.dart';

/// Reads `AgentDecision.extra`, so it needs the evaluation side of `aib_core`
/// and stays out of the app-safe entry point.
export 'src/metrics/decision_metrics.dart';
export 'src/metrics/intent_conventions.dart';
export 'src/metrics/prefetch_metrics.dart';
export 'src/metrics/routing_metrics.dart';
export 'src/perturbation/catalog_shuffle.dart';
export 'src/judge/llm_judge.dart';
export 'src/llm/cassette_llm_client.dart';
export 'src/llm/faulting_llm_client.dart';
export 'src/llm/llm_config.dart';
export 'src/llm/llm_user_simulator.dart';
