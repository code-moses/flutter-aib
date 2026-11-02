import 'package:aib_core/ports.dart';
import 'package:aib_jev/aib_jev.dart';

import '../llm/llm_client.dart';

/// Which model an episode runs on.
enum ModelRoute { local, cloud }

/// What a [RouteDecider] said, and on what grounds. Rides on the episode's
/// first decision as `extra.modelRoute`, so routing metrics are a trace
/// derivation like every other metric.
final class RouteDecision {
  const RouteDecision({
    required this.route,
    required this.decider,
    this.reason,
    this.probabilityLocal,
    this.latencyMs = 0,
    this.deciderModel,
    this.deciderTokens = 0,
    this.fallback = false,
    this.language,
    this.askedIn,
  });

  final ModelRoute route;
  final String decider;
  final String? reason;

  /// The decider's belief that the local model will do, where it has one.
  /// Kept even when the route is fixed by a threshold, so a threshold sweep
  /// can be replayed from one run instead of re-run per threshold.
  final double? probabilityLocal;

  final int latencyMs;

  /// The model that decided (Jev's echoed release, the local model judging
  /// itself), for provenance (A3).
  final String? deciderModel;
  final int deciderTokens;

  /// True when the decider failed and [ModelRouterConfig.onError] chose.
  final bool fallback;

  /// The instruction's language (ISO 639-1), where it is clear: set by the
  /// router for every decider, so routing accuracy can be split by language on
  /// any arm.
  final String? language;

  /// The language a decision model was *asked* in — its instructions and
  /// criteria — where that is a choice (`jev.language`).
  final String? askedIn;

  RouteDecision withLanguage(String? language) => RouteDecision(
    route: route,
    decider: decider,
    reason: reason,
    probabilityLocal: probabilityLocal,
    latencyMs: latencyMs,
    deciderModel: deciderModel,
    deciderTokens: deciderTokens,
    fallback: fallback,
    language: language,
    askedIn: askedIn,
  );

  /// The decider's own spend, attributed to the decider's model so the price
  /// table costs it at that model's rate (`side_call_cost_usd`). Null for a
  /// decider that calls no model (`local`, `cloud`, `rules`).
  SideCall? get sideCall => deciderModel == null
      ? null
      : SideCall(
          purpose: 'route',
          model: deciderModel!,
          // A decision model reads a prompt and emits no tokens; a
          // self-assessing LLM emits the one word it was asked for, which
          // `deciderTokens` already includes.
          tokensPrompt: deciderTokens,
          latencyMs: latencyMs,
        );

  JsonMap toJson() => {
    'route': route.name,
    'decider': decider,
    'reason': ?reason,
    'probabilityLocal': ?probabilityLocal,
    'latencyMs': latencyMs,
    'deciderModel': ?deciderModel,
    if (deciderTokens > 0) 'deciderTokens': deciderTokens,
    if (fallback) 'fallback': true,
    'language': ?language,
    'askedIn': ?askedIn,
  };
}

/// Decides local or cloud, once per episode, from the instruction alone. A
/// [TaskSpec] also carries ground truth, and a decider that could read it would
/// route on the answer key.
abstract interface class RouteDecider {
  String get name;

  Future<RouteDecision> decide(String instruction, {CancellationToken? cancellation});
}

/// The two reference arms: every episode on one side.
final class FixedRouteDecider implements RouteDecider {
  const FixedRouteDecider(this.route);

  final ModelRoute route;

  @override
  String get name => 'always-${route.name}';

  @override
  Future<RouteDecision> decide(String instruction, {CancellationToken? cancellation}) async => RouteDecision(route: route, decider: name);
}

/// The baseline any learned decider has to beat: long instructions and
/// instructions that match a configured pattern go to the cloud.
///
/// Deterministic and free, so a Jev arm that does not beat it has bought
/// latency and a dependency for nothing.
final class RuleRouteDecider implements RouteDecider {
  RuleRouteDecider({this.maxLocalWords, List<String> cloudPatterns = const []})
    : cloudPatterns = [for (final p in cloudPatterns) RegExp(p, caseSensitive: false)];

  /// More words than this → cloud. Null = no length rule.
  final int? maxLocalWords;
  final List<RegExp> cloudPatterns;

  @override
  String get name => 'rules';

  @override
  Future<RouteDecision> decide(String instruction, {CancellationToken? cancellation}) async {
    final words = instruction.trim().split(RegExp(r'\s+')).length;
    if (maxLocalWords case final max? when words > max) {
      return RouteDecision(route: .cloud, decider: name, reason: 'words=$words>$max');
    }
    for (final pattern in cloudPatterns) {
      if (pattern.hasMatch(instruction)) {
        return RouteDecision(route: .cloud, decider: name, reason: 'pattern=${pattern.pattern}');
      }
    }
    return RouteDecision(route: .local, decider: name);
  }
}

/// A System One model reads the instruction and answers a `choice` between
/// `local` and `cloud`; the episode goes local when p(local) ≥ [threshold].
/// [language] decides which language the question is asked in; `auto` asks in
/// the task's language where [translations] has texts for it.
final class JevRouteDecider implements RouteDecider {
  JevRouteDecider({
    required this.client,
    this.threshold = 0.5,
    this.instructions = defaultInstructions,
    this.criteria = defaultCriteria,
    this.translations = const {},
    this.language = const JevLanguagePolicy.fixed('en'),
  });

  static const defaultInstructions =
      'The state is a task an assistant must complete by operating a business '
      'app through tool calls. Which model should handle it?';

  static const defaultCriteria = {
    'local':
        'The small local model is enough: the task names what to do, needs '
        'few steps and little judgement.',
    'cloud':
        'The stronger model is needed: the task is long, ambiguous, needs '
        'several dependent steps, a refusal, or careful reading of results.',
  };

  /// Criteria that name the two models the router actually holds. The decision
  /// model cannot know what it was wired to unless the question says so.
  static Map<String, String?> criteriaFor({required String localModel, required String cloudModel}) => {
    'local':
        'Run it on $localModel, a small local model: the task names what to '
        'do, needs few steps and little judgement, and a mistake is cheap.',
    'cloud':
        'Send it to $cloudModel, a much stronger model: the task is long or '
        'ambiguous, needs several dependent steps, a refusal, or careful '
        'reading of results — more than a small model reliably does.',
  };

  /// The same question in German, naming the two models. Option ids stay
  /// `local`/`cloud`: the model reads the labels `A`/`B`, the ids are
  /// what the answer is keyed by.
  static JevRouteTexts germanFor({required String localModel, required String cloudModel}) => JevRouteTexts(
    instructions:
        'Der Zustand ist eine Aufgabe, die ein Assistent erledigen muss, indem er '
        'eine Business-App über Tool-Aufrufe bedient. Welches Modell soll sie übernehmen?',
    criteria: {
      'local':
          'Auf $localModel ausführen, einem kleinen lokalen Modell: die Aufgabe sagt, was zu '
          'tun ist, braucht wenige Schritte und wenig Urteilsvermögen, und ein Fehler ist billig.',
      'cloud':
          'An $cloudModel senden, ein deutlich stärkeres Modell: die Aufgabe ist lang oder '
          'mehrdeutig, braucht mehrere abhängige Schritte, eine Ablehnung oder genaues Lesen '
          'von Ergebnissen — mehr, als ein kleines Modell zuverlässig schafft.',
    },
  );

  final JevClient client;
  final double threshold;

  /// The English question, and the one asked in any language without a
  /// translation.
  final String instructions;

  /// Must contain [localOption]; every other option routes to the cloud, so
  /// a criteria map may name several cloud tiers without this class knowing
  /// what they are.
  final Map<String, String?> criteria;

  /// Language code → the question in that language. Every translation must
  /// offer the same option ids as [criteria].
  final Map<String, JevRouteTexts> translations;

  final JevLanguagePolicy language;

  /// The option id that means "stay local".
  static const localOption = 'local';

  @override
  String get name => 'jev';

  @override
  Future<RouteDecision> decide(String instruction, {CancellationToken? cancellation}) async {
    final wanted = language.resolve(instruction);
    final translated = translations[wanted];
    final response = await client.decide(
      JevRequest(
        state: JevState.text(instruction),
        questions: {'route': JevChoice(instructions: translated?.instructions ?? instructions, criteria: translated?.criteria ?? criteria)},
      ),
      cancellation: cancellation,
    );
    final answer = response.answer<JevChoiceAnswer>('route');
    final pLocal = answer.probabilityOf(localOption);
    return RouteDecision(
      route: pLocal >= threshold ? ModelRoute.local : ModelRoute.cloud,
      decider: name,
      reason: 'p_local=${pLocal.toStringAsFixed(3)} threshold=$threshold',
      probabilityLocal: pLocal,
      latencyMs: response.latencyMs,
      deciderModel: response.model,
      deciderTokens: response.usage.inputTokens,
      askedIn: translated == null ? 'en' : wanted,
    );
  }
}

/// A [JevRouteDecider]'s question in one language.
final class JevRouteTexts {
  const JevRouteTexts({required this.instructions, required this.criteria});

  final String instructions;
  final Map<String, String?> criteria;
}

/// The local model judges whether it can do the task itself. Asked for one word
/// so a small model with thinking off can answer in a single call.
final class SelfAssessRouteDecider implements RouteDecider {
  SelfAssessRouteDecider({required this.client, this.prompt = defaultPrompt});

  static const defaultPrompt =
      'You are about to be given the task below and a set of tools to operate '
      'a business app. Answer with exactly one word: LOCAL if you are '
      'confident you can complete it correctly yourself, CLOUD if a stronger '
      'model should do it.';

  final LlmClient client;
  final String prompt;

  @override
  String get name => 'self';

  @override
  Future<RouteDecision> decide(String instruction, {CancellationToken? cancellation}) async {
    final watch = Stopwatch()..start();
    final response = await client.complete(
      LlmRequest(messages: [LlmMessage.system(prompt), LlmMessage.user('Task: $instruction')], maxTokens: 8),
      cancellation: cancellation,
    );
    final text = response.text.trim().toUpperCase();
    // Anything that is not a clear LOCAL goes up: a local model that cannot
    // follow a one-word format has answered the question anyway.
    final local = text.startsWith('LOCAL');
    return RouteDecision(
      route: local ? ModelRoute.local : ModelRoute.cloud,
      decider: name,
      reason: 'answer=${text.length > 20 ? text.substring(0, 20) : text}',
      latencyMs: watch.elapsedMilliseconds,
      deciderModel: response.model.isEmpty ? client.model : response.model,
      deciderTokens: response.usage.promptTokens + response.usage.completionTokens,
    );
  }
}

/// The `modelRouter:` block of an agent YAML, minus the client configs the
/// factory turns into clients. Hashed into the manifest with the rest of the
/// block by the generic config-block mechanism.
///
/// ```yaml
/// modelRouter:
///   decider: jev            # local | cloud | rules | self | jev
///   onError: cloud          # route when the decider fails
///   local: {provider: ollama, model: qwen3:8b, think: false}
///   cloud: {provider: anthropic, model: claude-sonnet-5,
///           supportsTemperature: false}
///   rules: {maxLocalWords: 40, cloudPatterns: ['\bunless\b']}
///   jev: {baseUrl: http://127.0.0.1:8000, model: Qwen/Qwen3.5-4B,
///         threshold: 0.5, language: en}   # en | de | auto
///   # or local through Ollama, no Python server (see JevConfig):
///   # jev: {backend: ollama, model: qwen3:8b, threshold: 0.5}
/// ```
final class ModelRouterConfig {
  const ModelRouterConfig({this.decider = 'local', this.onError = .cloud});

  static const deciders = ['local', 'cloud', 'rules', 'self', 'jev'];

  final String decider;
  final ModelRoute onError;

  factory ModelRouterConfig.fromJson(JsonMap json) {
    final decider = json['decider'] as String? ?? 'local';
    if (!deciders.contains(decider)) {
      throw FormatException(
        'modelRouter decider "$decider" is not implemented '
        '(${deciders.join(', ')})',
      );
    }
    return ModelRouterConfig(decider: decider, onError: _route(json['onError'] ?? 'cloud'));
  }

  static ModelRoute _route(Object? value) =>
      ModelRoute.values.firstWhere((route) => route.name == value, orElse: () => throw FormatException('unknown route "$value"'));
}

/// An [LlmClient] that is one of two clients per episode. Routing lives in the
/// client so every agent can be routed unchanged. [model] names the active
/// side, so a routed run is costed per decision at the rate of the model that
/// made it.
final class ModelRouter implements LlmStreamingClient, LlmWarmUp, LlmModelIdentity, LlmStructuredOutput {
  ModelRouter({
    required this.local,
    required this.cloud,
    required this.decider,
    this.onError = .cloud,
    this.localSupportsTemperature = true,
    this.cloudSupportsTemperature = true,
  });

  final LlmClient local;
  final LlmClient cloud;
  final RouteDecider decider;
  final ModelRoute onError;

  /// Per side, because the two sides rarely agree on `temperature`. The agent
  /// config can only switch it off for both.
  final bool localSupportsTemperature;
  final bool cloudSupportsTemperature;

  RouteDecision? _decision;

  /// This episode's decision; null between episodes.
  RouteDecision? get decision => _decision;

  LlmClient? get _active => switch (_decision?.route) {
    .local => local,
    .cloud => cloud,
    null => null,
  };

  /// Between episodes (where the manifest reads it) both, so the manifest
  /// says this is a routed arm rather than naming whichever side came first.
  @override
  String get model => _active?.model ?? '${local.model}|${cloud.model}';

  /// Decides the episode's route. A failing decider does not abort the
  /// episode: it routes to [onError] and says so, because an unreachable
  /// Jev server is a finding about the decider, not about the task.
  Future<RouteDecision> beginEpisode(String instruction, {CancellationToken? cancellation}) async {
    final watch = Stopwatch()..start();
    try {
      final decision = await decider.decide(instruction, cancellation: cancellation);
      return _decision = decision.withLanguage(detectLanguage(instruction));
    } on Exception catch (e) {
      if (cancellation?.isCancelled ?? false) rethrow;
      return _decision = RouteDecision(
        route: onError,
        decider: decider.name,
        reason: 'error: $e',
        latencyMs: watch.elapsedMilliseconds,
        fallback: true,
        language: detectLanguage(instruction),
      );
    }
  }

  void endEpisode() => _decision = null;

  LlmClient _require() => _active ?? (throw StateError('ModelRouter called outside an episode: beginEpisode was not awaited'));

  LlmRequest _adapt(LlmRequest request) {
    final supports = identical(_active, cloud) ? cloudSupportsTemperature : localSupportsTemperature;
    if (supports || request.temperature == null) return request;
    return request.copyWith(dropTemperature: true);
  }

  /// Only when both sides can: the route is decided per episode, so a schema
  /// the chosen side would ignore is a constrained arm that ran unconstrained.
  @override
  bool get supportsResponseSchema => local.honoursResponseSchema && cloud.honoursResponseSchema;

  @override
  Future<LlmResponse> complete(LlmRequest request, {CancellationToken? cancellation}) =>
      _require().complete(_adapt(request), cancellation: cancellation);

  @override
  Future<LlmResponse> completeStreaming(
    LlmRequest request, {
    required void Function(String delta) onTextDelta,
    CancellationToken? cancellation,
  }) async {
    final client = _require();
    if (client is LlmStreamingClient) {
      return client.completeStreaming(_adapt(request), onTextDelta: onTextDelta, cancellation: cancellation);
    }
    final response = await client.complete(_adapt(request), cancellation: cancellation);
    if (response.text.isNotEmpty) onTextDelta(response.text);
    return response;
  }

  /// Warms the local side: it is the one with a model to load, and the
  /// first local episode would otherwise pay for it.
  @override
  Future<void> warmUp() async {
    for (final client in [local, cloud]) {
      if (client case final LlmWarmUp warmable) await warmable.warmUp();
    }
  }

  @override
  Future<JsonMap> modelIdentity() async {
    return {
      'model': model,
      'local': await local.identify(),
      'cloud': await cloud.identify(),
      'decider': decider.name,
      if (decider case JevRouteDecider(:final client)) 'jev': client.model,
    };
  }
}
