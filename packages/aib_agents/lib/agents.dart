/// Everything needed to *run* an agent inside an application, and nothing that
/// only a benchmark harness needs.
///
/// `dart:io`-free and Flutter-free, so an app can depend on this package and
/// ship the agent the benchmark measured. Left out:
///
/// - `llm_config.dart` (`LlmClientFactory`) reads `Platform.environment` for API
///   keys. An app brings its own [LlmClient]; it must never carry provider keys.
/// - `llm_judge.dart` is evaluation machinery. Judging happens in the harness.
///
/// `aib_agents.dart` re-exports this file plus those two. CI enforces the
/// `dart:io`-freeness (`tool/check_app_safe_entrypoints.dart`).
library;

/// Decision models: the whole of `aib_jev`, so code that routes or checks
/// with Jev needs one import. The package stands alone too — an app that
/// only wants a decision model depends on `aib_jev` and nothing here.
export 'package:aib_jev/aib_jev.dart';
export 'src/agents/agent_config.dart';
export 'src/agents/compaction.dart';
export 'src/agents/agent_profile.dart';
export 'src/agents/decisions.dart';
export 'src/agents/genui_agent.dart';
export 'src/agents/hybrid_agent.dart';
export 'src/agents/intent_agent.dart';
export 'src/agents/preparation_config.dart';
export 'src/agents/preparing_agent.dart';
export 'src/agents/prompts.dart';
export 'src/agents/router_config.dart';
export 'src/agents/semantics_agent.dart';
export 'src/agents/strategies.dart';
export 'src/agents/tool_loop_agent.dart';
export 'src/conventions.dart';
export 'src/llm/anthropic_client.dart';
export 'src/llm/azure_openai_client.dart';
export 'src/llm/constrained_tool_calls.dart';
export 'src/llm/embedding_client.dart';
export 'src/llm/fallback_llm_client.dart';
export 'src/llm/llm_client.dart';
export 'src/llm/llm_http.dart';
export 'src/llm/ollama_client.dart';
export 'src/llm/openai_client.dart';
export 'src/routing/model_router.dart';
