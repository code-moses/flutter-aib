import 'dart:async';
import 'dart:convert';

import 'package:aib_core/ports.dart';

export 'package:aib_core/transport.dart' show CancellationToken, TransportErrorKind, TransportException;

/// Provider-agnostic LLM port (spec §7). Shipped inside applications, so every
/// addition is a breaking change for a released app.
abstract interface class LlmClient {
  String get model;

  /// [cancellation], when supplied, aborts the call as soon as it is
  /// cancelled — the *only* way to stop an in-flight request. Without it a
  /// timed-out call keeps running and its response arrives during the next
  /// episode, where it is charged to the wrong agent.
  Future<LlmResponse> complete(LlmRequest request, {CancellationToken? cancellation});
}

/// What a wrapper or agent asks of a client it only knows as an [LlmClient].
extension LlmClientCapabilities on LlmClient {
  bool get honoursResponseSchema => switch (this) {
    LlmStructuredOutput(supportsResponseSchema: true) => true,
    _ => false,
  };

  /// [LlmModelIdentity.modelIdentity], or the model's name without one.
  Future<JsonMap> identify() async => switch (this) {
    final LlmModelIdentity identified => await identified.modelIdentity(),
    _ => {'model': model},
  };
}

/// Streams assistant text as it is produced. Optional: [ToolLoopAgent]
/// probes for it with `is` and falls back to [LlmClient.complete].
///
/// Telemetry is unaffected — usage is read from the final chunk — so a
/// streamed run and a non-streamed run stay comparable. Tool calls are not
/// streamed piecemeal: they arrive complete in the returned response, since
/// a half-parsed tool call is not something an agent can act on.
abstract interface class LlmStreamingClient implements LlmClient {
  /// Emits text deltas through [onTextDelta] and completes with the same
  /// response [LlmClient.complete] would have returned.
  Future<LlmResponse> completeStreaming(LlmRequest request, {required void Function(String delta) onTextDelta, CancellationToken? cancellation});
}

/// Loads whatever the client needs before it can answer at normal speed: an
/// Ollama model into RAM, an on-device runtime off flash. Probed with `is` by
/// the runner, which calls it once before the first episode.
abstract interface class LlmWarmUp {
  Future<void> warmUp();
}

/// A client whose server keeps a prompt cache it can be primed with: [warmPrefix]
/// evaluates [LlmRequest]'s messages and tools and generates nothing, so the
/// next request that starts with the same prefix only pays for what follows.
///
/// What an app does while the assistant is idle.
/// Probed with `is`; a hosted API caches on its own terms and has nothing to
/// prime.
abstract interface class LlmPrefixWarmUp {
  Future<void> warmPrefix(LlmRequest request);
}

/// A client that knows its context window (recorded as `contextWindow`).
abstract interface class LlmContextWindow {
  int get contextTokens;
}

/// A client that can constrain a completion to a JSON schema
/// ([LlmRequest.responseSchema]).
///
/// Probed with `is`; a getter rather than a marker because a wrapper supports
/// it only when every client behind it does. A client without it *ignores* the
/// schema, so [ToolLoopAgent] refuses to start an episode against one.
abstract interface class LlmStructuredOutput {
  bool get supportsResponseSchema;
}

/// Resolves the configured model to something immutable (a digest, a dated
/// id). Probed with `is`; recorded in the run manifest.
abstract interface class LlmModelIdentity {
  Future<JsonMap> modelIdentity();
}

/// A client that may answer from a model other than the one it was asked
/// for — a fallback chain after an outage. Probed with `is`; read once after
/// each call, so a trace says which model really answered and why.
abstract interface class LlmFallbackReport {
  /// The models that failed before the last call was answered, each with the
  /// error kind it failed with (`claude-sonnet-5: server`); empty when the
  /// first model answered. Cleared by reading.
  List<String> takeFallbacks();
}

enum LlmRole { system, user, assistant, tool }

final class LlmMessage {
  const LlmMessage._({required this.role, this.content = '', this.toolCalls = const [], this.toolCallId, this.toolName});

  final LlmRole role;
  final String content;

  /// Tool calls of an assistant turn.
  final List<LlmToolCall> toolCalls;

  /// For [LlmRole.tool]: which call this result answers.
  final String? toolCallId;
  final String? toolName;

  factory LlmMessage.system(String content) => LlmMessage._(role: .system, content: content);

  factory LlmMessage.user(String content) => LlmMessage._(role: .user, content: content);

  factory LlmMessage.assistant(String content, {List<LlmToolCall> toolCalls = const []}) =>
      LlmMessage._(role: .assistant, content: content, toolCalls: toolCalls);

  factory LlmMessage.toolResult({required String callId, required String name, required String content}) =>
      LlmMessage._(role: .tool, content: content, toolCallId: callId, toolName: name);

  /// Same message with different content — used by the observation window to
  /// replace a stale tool result with a stub.
  LlmMessage withContent(String newContent) =>
      LlmMessage._(role: role, content: newContent, toolCalls: toolCalls, toolCallId: toolCallId, toolName: toolName);
}

/// Tool definition presented to the model (function calling).
final class LlmTool {
  const LlmTool({required this.name, required this.description, this.parameters = const {'type': 'object', 'properties': {}}});

  final String name;
  final String description;
  final JsonMap parameters; // JSON schema
}

final class LlmToolCall {
  const LlmToolCall({required this.id, required this.name, this.arguments = const {}, this.argumentsError});

  final String id;
  final String name;
  final JsonMap arguments;

  /// The raw argument text when the provider sent something that is not a
  /// JSON object; [arguments] is then empty. The agent tells the model rather
  /// than running the tool with nothing.
  final String? argumentsError;

  /// Arguments as a provider sends them — an object, or an object encoded as
  /// a string — decoded without throwing.
  static ({JsonMap arguments, String? error}) decodeArguments(Object? raw) {
    if (raw == null) return (arguments: const {}, error: null);
    if (raw is Map) return (arguments: asJsonMap(raw), error: null);
    if (raw is String) {
      if (raw.trim().isEmpty) return (arguments: const {}, error: null);
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return (arguments: asJsonMap(decoded), error: null);
      } on FormatException {
        // Falls through to the error below.
      }
      return (arguments: const {}, error: raw);
    }
    return (arguments: const {}, error: '$raw');
  }
}

final class LlmUsage {
  const LlmUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.cachedPromptTokens = 0,
    this.cacheWriteTokens = 0,
    this.reasoningTokens = 0,
  });

  final int promptTokens;
  final int completionTokens;

  /// Prompt tokens served from the provider's cache, billed at a fraction of
  /// the normal rate. Included in [promptTokens], not additional to it.
  final int cachedPromptTokens;

  /// Prompt tokens written into the provider's cache on this call, billed
  /// slightly above the normal rate. Included in [promptTokens].
  final int cacheWriteTokens;

  /// Completion tokens spent on reasoning the caller never sees. Included in
  /// [completionTokens]. Priced separately by some providers, and the reason
  /// a reasoning model can look cheap per visible token and be expensive.
  final int reasoningTokens;

  LlmUsage operator +(LlmUsage other) => LlmUsage(
    promptTokens: promptTokens + other.promptTokens,
    completionTokens: completionTokens + other.completionTokens,
    cachedPromptTokens: cachedPromptTokens + other.cachedPromptTokens,
    cacheWriteTokens: cacheWriteTokens + other.cacheWriteTokens,
    reasoningTokens: reasoningTokens + other.reasoningTokens,
  );
}

final class LlmRequest {
  const LlmRequest({
    required this.messages,
    this.tools = const [],
    this.temperature = 0,
    this.maxTokens = 1024,
    this.parallelToolCalls,
    this.responseSchema,
  });

  final List<LlmMessage> messages;
  final List<LlmTool> tools;

  /// temperature=0 wherever supported (reproducibility, spec §5.3).
  ///
  /// Null means "do not send it". Some Azure model families reject the
  /// parameter outright and accept only their default, so the choice is
  /// between omitting it and not being able to run those models at all. It
  /// changes what is measured, so the agent config records it.
  final double? temperature;
  final int maxTokens;

  /// Ask the provider not to return several tool calls in one turn. Default for
  /// the hybrid agent, because the loop executes queued calls back to back
  /// without the model seeing the results in between. Null leaves the provider
  /// default.
  final bool? parallelToolCalls;

  /// JSON schema the completion must satisfy, enforced while decoding: the
  /// portable form of what llama.cpp calls a grammar. Only a client that
  /// reports [LlmStructuredOutput.supportsResponseSchema] honours it; hosted
  /// providers already enforce a tool's schema natively. Used by
  /// `agent.toolCalling: constrained` (ADR 0015).
  final JsonMap? responseSchema;

  LlmRequest copyWith({List<LlmMessage>? messages, JsonMap? responseSchema, bool dropTemperature = false}) => LlmRequest(
    messages: messages ?? this.messages,
    tools: tools,
    temperature: dropTemperature ? null : temperature,
    maxTokens: maxTokens,
    parallelToolCalls: parallelToolCalls,
    responseSchema: responseSchema ?? this.responseSchema,
  );
}

final class LlmResponse {
  const LlmResponse({
    this.text = '',
    this.toolCalls = const [],
    this.usage = const LlmUsage(),
    this.model = '',
    this.stopReason,
    this.firstTokenMs,
    this.thinking,
  });

  final String text;
  final List<LlmToolCall> toolCalls;
  final LlmUsage usage;
  final String model;
  final String? stopReason;

  /// Time to the first generated token, where the provider says. Null
  /// otherwise.
  final int? firstTokenMs;

  /// The reasoning the model produced before it answered, where the provider
  /// returns it. Null where there is none, which is not the same as empty.
  ///
  /// Never sent back to the model and never scored. It tells a turn that is
  /// empty except for this from a model that said nothing.
  final String? thinking;

  /// Same response, attributed to [model].
  LlmResponse withModel(String model) => LlmResponse(
    text: text,
    toolCalls: toolCalls,
    usage: usage,
    model: model,
    stopReason: stopReason,
    firstTokenMs: firstTokenMs,
    thinking: thinking,
  );

  LlmResponse copyWith({String? text, List<LlmToolCall>? toolCalls}) => LlmResponse(
    text: text ?? this.text,
    toolCalls: toolCalls ?? this.toolCalls,
    usage: usage,
    model: model,
    stopReason: stopReason,
    firstTokenMs: firstTokenMs,
    thinking: thinking,
  );
}

/// Why an LLM call failed — [TransportErrorKind] under its original name.
typedef LlmErrorKind = TransportErrorKind;

/// Transport/API failure of the LLM provider — [TransportException] under
/// its original name. The class moved to `aib_core` so the decision-model
/// clients (`aib_jev`) share one classification with the LLM adapters.
typedef LlmClientException = TransportException;
