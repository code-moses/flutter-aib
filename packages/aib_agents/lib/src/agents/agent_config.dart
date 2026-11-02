import 'package:aib_core/ports.dart';

import '../llm/constrained_tool_calls.dart';
import '../llm/llm_client.dart';
import '../llm/llm_http.dart';
import 'compaction.dart';

/// How a tool call leaves the model.
enum ToolCalling {
  /// The provider's function calling: the runtime parses the model's output
  /// into `tool_calls`. What every arm before ADR 0015 used.
  native,

  /// The decoder is constrained to a JSON schema that admits only calls to the
  /// offered tools (see [ConstrainedToolCalls]). Needs a client that honours
  /// [LlmRequest.responseSchema].
  constrained,
}

/// How the intent strategy offers the app's catalog as tools.
enum ToolSurface {
  /// The catalog is a listing; an intent becomes a tool, with its full schema,
  /// once `describe_intents` names it or a preparer describes it before the
  /// first call.
  promoted,

  /// Every catalog intent is a tool from the first call, with a one-line
  /// summary and a loose schema; `describe_intents` writes the schemas into a
  /// result the observation window never stubs. The task line goes after the
  /// bootstrap observations and plan results carry no budget line. For runtimes
  /// that render tools at the top of the prompt (Ollama), where any change to
  /// the tool list re-prefills everything.
  fixed,
}

/// Which worked examples the agent is offered, each switched on separately so
/// an arm can vary one of them.
///
/// [tools] adds an example call to the description of the tools the framework
/// owns (`describe_intents`, `ask_user`, `done`); [intents] adds the example
/// calls an app publishes with an intent (`examples` in its catalogue entry) to
/// that intent's tool description once it is described. The example *prompt*
/// is a prompt version (`agent.prompt`), not a flag here: a prompt is frozen and
/// hashed as a whole.
final class ExamplesConfig {
  const ExamplesConfig({this.tools = false, this.intents = false});

  final bool tools;
  final bool intents;

  bool get any => tools || intents;

  factory ExamplesConfig.fromJson(Object? json) {
    if (json == null) return const ExamplesConfig();
    if (json is! Map) throw FormatException('agent.examples must be a map of {tools, intents}, got ${json.runtimeType}');
    final map = asJsonMap(json);
    for (final key in map.keys) {
      if (key != 'tools' && key != 'intents') throw FormatException('agent.examples has no key "$key" (tools, intents)');
    }
    return ExamplesConfig(tools: map['tools'] as bool? ?? false, intents: map['intents'] as bool? ?? false);
  }

  JsonMap toJson() => {'tools': tools, 'intents': intents};
}

/// Everything about an agent that is not its prompt and not its LLM connection:
/// the knobs that change *what is measured*, so they travel in the run manifest.
///
/// In an agent YAML this is the `agent:` block:
///
/// ```yaml
/// llm:                       # -> LlmClientFactory
///   provider: azure
///   deployment: sysco-gpt4o
/// agent:
///   maxCompletionTokens: 2048
///   supportsTemperature: true
///   parallelToolCalls: false
///   observationWindow: 6
///   observationStride: 6
///   maxUnknownToolRetries: 3
///   finishWarningTurns: 2
///   toolCalling: native            # native | constrained (ADR 0015)
///   toolSurface: promoted          # promoted | fixed
///   prompt: hybrid_v5              # a frozen prompt of the agent's family
///   examples: {tools: true, intents: true}
///   captureModelOutput: false      # trace what the model wrote (observability)
///   environmentInstructions: true  # append the app's instance text (ADR 0018)
///   warmPrefix: false              # prime the shared prefix between episodes
///   compaction: {after: 8, keep: 4} # summarise old turns (instead of the window)
///   retry: {maxAttempts: 3, timeoutSeconds: 120}
/// router: ...                # -> RouterConfig (hybrid agent only)
/// ```
final class AgentConfig {
  const AgentConfig({
    this.maxCompletionTokens = 1024,
    this.temperature = 0,
    this.supportsTemperature = true,
    this.parallelToolCalls,
    this.observationWindow,
    this.observationStride,
    this.maxUnknownToolRetries = 3,
    this.finishWarningTurns = 2,
    this.retry = const LlmRetryPolicy(),
    this.toolCalling = .native,
    this.toolSurface = .promoted,
    this.prompt,
    this.examples = const ExamplesConfig(),
    this.captureModelOutput = false,
    this.environmentInstructions = true,
    this.warmPrefix = false,
    this.compaction,
  });

  /// Ceiling on one completion. Was a per-agent constant (1024, and 4096 for
  /// GenUI) with no way to change it per run, which quietly capped what a
  /// verbose strategy could emit and made that cap invisible in the report.
  final int maxCompletionTokens;

  final double temperature;

  /// Some Azure model families accept only their default temperature and
  /// reject the parameter outright. Setting this false omits it — recorded
  /// in the manifest, because "temperature 0" and "whatever the model does"
  /// are not the same experiment.
  final bool supportsTemperature;

  /// See [LlmRequest.parallelToolCalls]. Null leaves the provider default.
  final bool? parallelToolCalls;

  /// Keep at most this many *recent* tool results in full; older ones are
  /// replaced by a one-line stub. Applied identically by every strategy. Null
  /// disables the window; on a real app the episode then ends in `llm_error:
  /// context length`.
  final int? observationWindow;

  /// How many results the window elides at once; null = the window itself.
  /// Larger steps keep the request prefix stable, and so cacheable, for longer.
  final int? observationStride;

  final int maxUnknownToolRetries;

  /// Warn the agent in words once the tokens left will not pay for this many
  /// more turns; 0 switches the warning off. An agent cannot feel the token
  /// budget: the prefix is re-sent every turn, so the cost per turn rises while
  /// `stepsUsed` barely moves.
  final int finishWarningTurns;

  final LlmRetryPolicy retry;

  /// See [ToolCalling]. Changes what the model is asked to do, so it is part
  /// of the arm's identity.
  final ToolCalling toolCalling;

  /// See [ToolSurface]. Part of the arm's identity, and it decides which
  /// prompts `agent.prompt` may name.
  final ToolSurface toolSurface;

  /// The frozen prompt to use, by version (`hybrid_v5`); null means the
  /// agent's own current one. A prompt of another agent's family is refused when
  /// the agent is built, not silently replaced.
  final String? prompt;

  final ExamplesConfig examples;

  /// Record what the model wrote, its text and its reasoning, on every
  /// decision.
  ///
  /// Observability, not a treatment: left out of [identity] and the hash the
  /// release gate compares. Off by default because a product must not log a
  /// user's conversation.
  final bool captureModelOutput;

  /// Append [EnvironmentDescriptor.instructions] to the system prompt (ADR
  /// 0018). Off is the ablation arm: the same agent without what the instance
  /// says about itself.
  final bool environmentInstructions;

  /// After each episode, off its clock, prime a local server's prompt cache
  /// with the prefix the next episode will start with (`LlmPrefixWarmUp`; a
  /// no-op on a client without one). Opt-in, because it changes the latency
  /// being measured; the preparing agent's `layout: shared` primes its own
  /// prefix regardless.
  final bool warmPrefix;

  /// Old turns folded into one model-written summary once a stride is
  /// crossed ([CompactionConfig]); null keeps the conversation (and the
  /// observation window, which still applies to what compaction keeps).
  final CompactionConfig? compaction;

  static T _option<T extends Enum>(List<T> values, Object? raw, T fallback, String field) {
    if (raw == null) return fallback;
    return values.asNameMap()[raw] ?? (throw FormatException('$field must be one of ${values.map((v) => v.name).join(', ')}, got $raw'));
  }

  factory AgentConfig.fromJson(JsonMap json) => AgentConfig(
    maxCompletionTokens: (json['maxCompletionTokens'] as num?)?.toInt() ?? 1024,
    temperature: (json['temperature'] as num?)?.toDouble() ?? 0,
    supportsTemperature: json['supportsTemperature'] as bool? ?? true,
    parallelToolCalls: json['parallelToolCalls'] as bool?,
    observationWindow: (json['observationWindow'] as num?)?.toInt(),
    observationStride: (json['observationStride'] as num?)?.toInt(),
    maxUnknownToolRetries: (json['maxUnknownToolRetries'] as num?)?.toInt() ?? 3,
    finishWarningTurns: (json['finishWarningTurns'] as num?)?.toInt() ?? 2,
    retry: json['retry'] == null ? const LlmRetryPolicy() : LlmRetryPolicy.fromJson(asJsonMap(json['retry'])),
    toolCalling: _option(ToolCalling.values, json['toolCalling'], ToolCalling.native, 'agent.toolCalling'),
    toolSurface: _option(ToolSurface.values, json['toolSurface'], ToolSurface.promoted, 'agent.toolSurface'),
    prompt: json['prompt'] as String?,
    examples: ExamplesConfig.fromJson(json['examples']),
    captureModelOutput: json['captureModelOutput'] as bool? ?? false,
    environmentInstructions: json['environmentInstructions'] as bool? ?? true,
    warmPrefix: json['warmPrefix'] as bool? ?? false,
    compaction: json['compaction'] == null ? null : CompactionConfig.fromJson(asJsonMap(json['compaction'])),
  );

  JsonMap toJson() => {
    'maxCompletionTokens': maxCompletionTokens,
    'temperature': temperature,
    'supportsTemperature': supportsTemperature,
    if (parallelToolCalls != null) 'parallelToolCalls': parallelToolCalls,
    if (observationWindow != null) 'observationWindow': observationWindow,
    if (observationWindow != null) 'observationStride': observationStride ?? observationWindow,
    'maxUnknownToolRetries': maxUnknownToolRetries,
    'finishWarningTurns': finishWarningTurns,
    'retry': retry.toJson(),
    // Only what departs from the default: `configHash` runs over this, and a
    // new knob must not change the hash of arms that do not set it.
    if (toolCalling != .native) 'toolCalling': toolCalling.name,
    if (toolSurface != .promoted) 'toolSurface': toolSurface.name,
    if (prompt != null) 'prompt': prompt,
    if (examples.any) 'examples': examples.toJson(),
    if (captureModelOutput) 'captureModelOutput': true,
    if (!environmentInstructions) 'environmentInstructions': false,
    if (warmPrefix) 'warmPrefix': true,
    'compaction': ?compaction?.toJson(),
  };

  /// What identifies the arm: [toJson] without the settings that only change
  /// what is written down. This is what `agentConfigHash` covers.
  JsonMap get identity => toJson()..remove('captureModelOutput');
}

/// Stable content hash used for the manifest fields the release gate compares
///. Stable across runs and machines: keys are sorted
/// before hashing, so a reordered YAML file is still the same configuration.
String configHash(Object? value) => jsonFingerprint(value).substring(0, 16);
