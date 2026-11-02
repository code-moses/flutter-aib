import 'dart:io';

import 'package:aib_jev/aib_jev.dart';

import '../agents/agent_profile.dart';
import '../agents/decisions.dart';
import '../routing/model_router.dart';
import 'anthropic_client.dart';
import 'azure_openai_client.dart';
import 'cassette_llm_client.dart';
import 'embedding_client.dart';
import 'fallback_llm_client.dart';
import 'faulting_llm_client.dart';
import 'llm_client.dart';
import 'llm_http.dart';
import 'ollama_client.dart';
import 'openai_client.dart';

/// Builds an [LlmClient] from a declarative config (CLI agent configs,
/// spec §9 `--models`).
///
/// Two file shapes are accepted. The flat one is what the existing
/// `suites/agents/*.yaml` use:
///
/// ```yaml
/// provider: anthropic | openai | azure | ollama
/// model: claude-sonnet-4-6
/// apiKeyEnv: ANTHROPIC_API_KEY   # optional, provider default otherwise
/// baseUrl: http://localhost:11434 # optional
/// contextTokens: 32768            # ollama only: num_ctx
/// think: false                    # ollama only: bool, or 'low'|'medium'|'high'
/// ```
///
/// The layered one separates the connection from the knobs that change what
/// is measured, so the manifest can record them apart:
///
/// ```yaml
/// llm:
///   provider: azure
///   resourceUrl: https://sysco-eu.openai.azure.com
///   deployment: sysco-gpt4o          # Azure addresses deployments, not models
///   modelId: gpt-4o-2024-11-20       # what it actually is, for pricing
///   apiVersion: 2024-10-21
///   apiKeyEnv: AZURE_OPENAI_API_KEY
///   retry: {maxAttempts: 3, timeoutSeconds: 120}
/// agent:
///   maxCompletionTokens: 2048
///   supportsTemperature: false       # reasoning deployments reject it
///   observationWindow: 6
/// router:
///   router: union
///   strategies: [intents, genui, user, semantics]
/// faults:                            # harness only: seeded LLM failures
///   llmFailureRate: 0.1
/// cassette:                          # harness only: record/replay LLM calls
///   path: results/run-x/llm/cassette.jsonl
///   mode: record                     # record | replay | replayThenLive
/// ```
///
/// An `llm:` block may name a `fallback:` chain of further `llm:` blocks,
/// tried in order on an infrastructure error (see [FallbackLlmClient]);
/// `faults:` then fails the first model only, the way an outage would.
///
/// This file is deliberately outside `package:aib_agents/agents.dart`: it
/// reads `Platform.environment` for API keys, and an application must never
/// carry provider keys.
abstract final class LlmClientFactory {
  /// The `llm:` block of a layered config, or the whole map if it is flat.
  static JsonMap llmSection(JsonMap config) => config['llm'] == null ? config : asJsonMap(config['llm']);

  /// The `agent:` block, empty when absent.
  static JsonMap agentSection(JsonMap config) => AgentProfile.agentSection(config);

  /// The `router:` block, empty when absent.
  static JsonMap routerSection(JsonMap config) => AgentProfile.routerSection(config);

  /// Every other map-valued block, for [ToolLoopAgent.configBlocks].
  static JsonMap otherSections(JsonMap config) => AgentProfile.otherSections(config);

  /// The `decisions:` block as [AgentDecisions], its `client:` built by
  /// [jevFromConfig]; null when the config has none.
  static AgentDecisions? decisionsFromConfig(JsonMap config) =>
      config['decisions'] == null ? null : AgentDecisions.fromJson(asJsonMap(config['decisions']), clientFor: jevFromConfig);

  static const _defaultKeyEnv = {'anthropic': 'ANTHROPIC_API_KEY', 'openai': 'OPENAI_API_KEY', 'azure': 'AZURE_OPENAI_API_KEY'};

  /// The same keys as compile-time defines. A run launched by the Flutter tool
  /// sees the tool's `Platform.environment`, not the shell's.
  /// `String.fromEnvironment` is const, so the names have to be literals; any
  /// other `apiKeyEnv` resolves from the environment.
  static const _definedKeys = {
    'ANTHROPIC_API_KEY': String.fromEnvironment('ANTHROPIC_API_KEY'),
    'OPENAI_API_KEY': String.fromEnvironment('OPENAI_API_KEY'),
    'AZURE_OPENAI_API_KEY': String.fromEnvironment('AZURE_OPENAI_API_KEY'),
    'TYPESAFE_API_KEY': String.fromEnvironment('TYPESAFE_API_KEY'),
  };

  static String? _apiKey(String? name) {
    if (name == null) return null;
    final defined = _definedKeys[name];
    if (defined != null && defined.isNotEmpty) return defined;
    return Platform.environment[name];
  }

  /// The `embedding:` block, or null when the config has none.
  ///
  /// ```yaml
  /// embedding:
  ///   provider: ollama | openai
  ///   model: nomic-embed-text
  /// ```
  static EmbeddingClient? embeddingFromConfig(JsonMap config) {
    if (config['embedding'] == null) return null;
    final block = asJsonMap(config['embedding']);
    final provider = block['provider'] as String? ?? 'ollama';
    final model = block['model'] as String?;
    if (model == null || model.isEmpty) {
      throw ArgumentError('embedding config requires "model"');
    }
    final retry = block['retry'] == null ? const LlmRetryPolicy() : LlmRetryPolicy.fromJson(asJsonMap(block['retry']));
    final baseUrl = block['baseUrl'] as String?;
    return switch (provider) {
      'ollama' => OllamaEmbeddingClient(model: model, baseUrl: baseUrl ?? 'http://localhost:11434', retryPolicy: retry),
      'openai' => OpenAiEmbeddingClient(
        model: model,
        apiKey: _apiKey(block['apiKeyEnv'] as String? ?? _defaultKeyEnv['openai']),
        baseUrl: baseUrl ?? 'https://api.openai.com',
        retryPolicy: retry,
      ),
      _ => throw ArgumentError('unknown embedding provider "$provider" (ollama | openai)'),
    };
  }

  /// A [JevClient] from a `jev:` block — [JevConfig] with keys read from
  /// the environment (or a `--define`d key). Remote and local backends:
  ///
  /// ```yaml
  /// jev: {baseUrl: http://127.0.0.1:8000, model: Qwen/Qwen3.5-4B}   # simple-jev
  /// jev: {baseUrl: https://api.typesafe.ai}                         # hosted
  /// jev: {backend: ollama, model: qwen3:8b}   # template: v1-noul-decimal (default) | v1
  /// jev: {backend: llama-server, baseUrl: http://127.0.0.1:8080,
  ///       model: qwen3-8b, format: qwen3}
  /// ```
  static JevClient jevFromConfig(JsonMap block) => JevConfig.clientFromJson(block, secret: _apiKey);

  /// A [ModelRouter] from a `modelRouter:` block (see [ModelRouterConfig]).
  /// Each side is an ordinary `llm:` block; `faults:` wraps each side rather
  /// than the router, so the agent still recognises the router as one.
  static ModelRouter modelRouterFromConfig(JsonMap config) {
    final block = asJsonMap(config['modelRouter']);
    final settings = ModelRouterConfig.fromJson(block);
    LlmClient side(String name) {
      if (block[name] == null) {
        throw ArgumentError('modelRouter requires a "$name" llm block');
      }
      return _build(asJsonMap(block[name]), faults: config['faults']);
    }

    final local = side('local');
    final cloud = side('cloud');
    final rules = asJsonMap(block['rules']);
    final jev = asJsonMap(block['jev']);
    final self = asJsonMap(block['self']);
    final RouteDecider decider = switch (settings.decider) {
      'local' => const FixedRouteDecider(ModelRoute.local),
      'cloud' => const FixedRouteDecider(ModelRoute.cloud),
      'rules' => RuleRouteDecider(
        maxLocalWords: (rules['maxLocalWords'] as num?)?.toInt(),
        cloudPatterns: [for (final p in rules['cloudPatterns'] as List? ?? const []) '$p'],
      ),
      'self' => SelfAssessRouteDecider(client: local, prompt: self['prompt'] as String? ?? SelfAssessRouteDecider.defaultPrompt),
      'jev' => JevRouteDecider(
        client: jevFromConfig(jev),
        threshold: (jev['threshold'] as num?)?.toDouble() ?? 0.5,
        instructions: jev['instructions'] as String? ?? JevRouteDecider.defaultInstructions,
        // Without explicit criteria, describe the two models this router
        // actually holds rather than a generic "small local model".
        criteria: jev['criteria'] == null
            ? JevRouteDecider.criteriaFor(localModel: local.model, cloudModel: cloud.model)
            : {for (final e in asJsonMap(jev['criteria']).entries) e.key: e.value as String?},
        // `language: en` (default) asks in English whatever the task says;
        // `de` or `auto` asks in German where the task is German. Built-in
        // German texts go with the built-in criteria; explicit criteria
        // bring their own `translations`, or stay English.
        language: JevLanguagePolicy.parse(jev['language'] as String? ?? 'en'),
        translations: jev['translations'] != null
            ? {
                for (final e in asJsonMap(jev['translations']).entries)
                  e.key: JevRouteTexts(
                    instructions: asJsonMap(e.value)['instructions'] as String? ?? JevRouteDecider.defaultInstructions,
                    criteria: {for (final c in asJsonMap(asJsonMap(e.value)['criteria']).entries) c.key: c.value as String?},
                  ),
              }
            : jev['criteria'] == null
            ? {'de': JevRouteDecider.germanFor(localModel: local.model, cloudModel: cloud.model)}
            : const {},
      ),
      final other => throw ArgumentError('unknown decider "$other"'),
    };
    return ModelRouter(
      local: local,
      cloud: cloud,
      decider: decider,
      onError: settings.onError,
      localSupportsTemperature: asJsonMap(block['local'])['supportsTemperature'] as bool? ?? true,
      cloudSupportsTemperature: asJsonMap(block['cloud'])['supportsTemperature'] as bool? ?? true,
    );
  }

  static LlmClient fromConfig(JsonMap config) {
    if (config['modelRouter'] != null) {
      if (config['llm'] != null || config['provider'] != null) {
        throw ArgumentError(
          'a config with "modelRouter" names its models in modelRouter.local '
          'and modelRouter.cloud, not in "llm"',
        );
      }
      return _withCassette(modelRouterFromConfig(config), config);
    }
    return _withCassette(_build(llmSection(config), faults: config['faults']), config);
  }

  /// Outermost, so what is recorded is what the agent got.
  static LlmClient _withCassette(LlmClient client, JsonMap config) =>
      config['cassette'] == null ? client : CassetteLlmClient.fromJson(client, asJsonMap(config['cassette']));

  static LlmClient _withFaults(LlmClient client, Object? faults, JsonMap llm) =>
      faults == null ? client : FaultInjectingLlmClient.wrap(client, asJsonMap(faults), retryPolicy: _retry(llm));

  static LlmRetryPolicy _retry(JsonMap llm) => llm['retry'] == null ? const LlmRetryPolicy() : LlmRetryPolicy.fromJson(asJsonMap(llm['retry']));

  /// One `llm:` block, with its `fallback:` chain when it has one; [faults]
  /// fail the first model only.
  static LlmClient _build(JsonMap llm, {Object? faults}) {
    final primary = _withFaults(_buildOne(llm), faults, llm);
    final fallback = llm['fallback'];
    if (fallback == null) {
      if (llm['fallbackOn'] != null) throw ArgumentError('llm.fallbackOn without llm.fallback');
      return primary;
    }
    if (fallback is! List || fallback.isEmpty) throw ArgumentError('llm.fallback must be a non-empty list of llm blocks');
    final on = switch (llm['fallbackOn']) {
      null => FallbackLlmClient.defaultOn,
      final List kinds => {
        for (final kind in kinds)
          LlmErrorKind.values.firstWhere((k) => k.name == '$kind', orElse: () => throw ArgumentError('llm.fallbackOn: unknown error kind "$kind"')),
      },
      final other => throw ArgumentError('llm.fallbackOn must be a list of error kinds, got $other'),
    };
    return FallbackLlmClient([primary, for (final next in fallback) _buildOne(asJsonMap(next))], on: on);
  }

  static LlmClient _buildOne(JsonMap llm) {
    final provider = llm['provider'] as String? ?? 'anthropic';
    final retry = llm['retry'] == null ? const LlmRetryPolicy() : LlmRetryPolicy.fromJson(asJsonMap(llm['retry']));
    final apiKeyEnv = llm['apiKeyEnv'] as String? ?? _defaultKeyEnv[provider];
    final apiKey = _apiKey(apiKeyEnv);
    final baseUrl = llm['baseUrl'] as String?;

    // Azure names the thing it serves a "deployment"; everyone else calls it
    // a model. Accepting both spellings here keeps the config readable in
    // either vocabulary.
    final model = (llm['model'] ?? llm['deployment']) as String?;
    if (model == null || model.isEmpty) {
      throw ArgumentError('llm config requires "model" (or "deployment")');
    }

    final client = switch (provider) {
      'anthropic' => AnthropicClient(model: model, apiKey: apiKey, baseUrl: baseUrl ?? 'https://api.anthropic.com', retryPolicy: retry),
      'openai' => OpenAiClient(model: model, apiKey: apiKey, baseUrl: baseUrl ?? 'https://api.openai.com', retryPolicy: retry),
      'azure' => AzureOpenAiClient(
        deployment: model,
        resourceUrl:
            (llm['resourceUrl'] ?? baseUrl) as String? ??
            (throw ArgumentError(
              'azure provider requires "resourceUrl" '
              '(e.g. https://my-resource.openai.azure.com)',
            )),
        apiVersion: llm['apiVersion'] as String? ?? AzureOpenAiClient.defaultApiVersion,
        modelId: llm['modelId'] as String?,
        apiKey: apiKey,
        retryPolicy: retry,
      ),
      'ollama' => OllamaClient(
        model: model,
        baseUrl: baseUrl ?? 'http://localhost:11434',
        contextTokens: (llm['contextTokens'] as num?)?.toInt() ?? OllamaClient.defaultContextTokens,
        think: llm['think'],
        retryPolicy: retry,
      ),
      _ => throw ArgumentError(
        'unknown provider "$provider" '
        '(anthropic | openai | azure | ollama)',
      ),
    };
    return client;
  }
}
