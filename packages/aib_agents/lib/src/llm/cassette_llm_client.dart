import 'dart:convert';
import 'dart:io';

import 'package:aib_core/ports.dart';

import 'llm_client.dart';

/// What a [CassetteLlmClient] does with a request.
enum CassetteMode {
  /// Every call goes to the model and is appended to the cassette.
  record,

  /// Every call is answered from the cassette; a request it does not hold is
  /// an error. For a deterministic rerun: CI, a judge re-score, a check that a
  /// framework change did not move a single decision.
  replay,

  /// Answered from the cassette while the conversation matches what was
  /// recorded, then live (and recorded) from the first request it does not
  /// hold. For re-running an episode after an *environment* change with the
  /// same model decisions until the app answers differently. A key covers the
  /// whole conversation, so once one answer was live nothing later in that
  /// episode can match a recording by accident.
  replayThenLive,
}

/// Records LLM calls to a file and answers them from it again ("cassettes").
///
/// Keyed by a fingerprint of the canonical request — model, messages, tools,
/// sampling and response schema — so a request that differs in one byte is a
/// different request. The same request sent twice (two repetitions at
/// temperature 0, which a sampling runtime still answers differently) is
/// answered in the order it was recorded; past the last recording, by the
/// last one.
///
/// A decorator like `FaultInjectingLlmClient`. It sits *above* the retry
/// policy: what is recorded is the answer the agent got, not the attempts.
/// A failure is never recorded — a replay has no outage to reproduce.
///
/// A replayed answer takes no time, so latency metrics of a replayed run
/// measure the framework, not the model; the recorded `firstTokenMs` is kept
/// as the model's own. The cassette is named in the model identity, which
/// the manifest records.
base class CassetteLlmClient
    implements LlmClient, LlmStreamingClient, LlmWarmUp, LlmPrefixWarmUp, LlmModelIdentity, LlmStructuredOutput, LlmFallbackReport {
  CassetteLlmClient._(this.inner, this.file, this.mode) {
    // A missing cassette is an error only where nothing could ever be
    // answered; recording appends, so a resumed run keeps what it recorded.
    if (mode == .replay && !file.existsSync()) {
      throw ArgumentError('cassette ${file.path} does not exist; record it first (mode: record)');
    }
    if (file.existsSync()) {
      for (final line in file.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        final entry = asJsonMap(jsonDecode(line));
        _recorded.putIfAbsent(entry['key'] as String, () => []).add(responseFromJson(asJsonMap(entry['response'])));
      }
    }
  }

  /// [inner] answering through the cassette at [path].
  static LlmClient wrap(LlmClient inner, {required String path, CassetteMode mode = .record}) =>
      inner is LlmContextWindow ? _WindowedCassette(inner, File(path), mode) : CassetteLlmClient._(inner, File(path), mode);

  /// From a `cassette:` block: `{path, mode}`.
  static LlmClient fromJson(LlmClient inner, JsonMap block) {
    final path = block['path'] as String? ?? (throw ArgumentError('cassette: requires "path"'));
    final mode = switch (block['mode']) {
      null => CassetteMode.record,
      final String name when CassetteMode.values.any((m) => m.name == name) => CassetteMode.values.byName(name),
      final other => throw FormatException('cassette.mode must be one of ${CassetteMode.values.map((m) => m.name).join(', ')}, got $other'),
    };
    return wrap(inner, path: path, mode: mode);
  }

  final LlmClient inner;
  final File file;
  final CassetteMode mode;

  final Map<String, List<LlmResponse>> _recorded = {};
  final Map<String, int> _served = {};

  /// Requests answered from the cassette, and sent to the model.
  var replayed = 0;
  var live = 0;

  @override
  String get model => inner.model;

  /// A replayed answer fell back to nothing.
  @override
  List<String> takeFallbacks() => switch (inner) {
    final LlmFallbackReport report => report.takeFallbacks(),
    _ => const [],
  };

  @override
  bool get supportsResponseSchema => inner.honoursResponseSchema;

  /// Nothing to warm in a strict replay: the model is never asked.
  @override
  Future<void> warmUp() async {
    if (mode == .replay) return;
    if (inner case final LlmWarmUp warmable) await warmable.warmUp();
  }

  @override
  Future<void> warmPrefix(LlmRequest request) async {
    if (mode == .replay) return;
    if (inner case final LlmPrefixWarmUp warmable) await warmable.warmPrefix(request);
  }

  @override
  Future<JsonMap> modelIdentity() async => {
    ...await inner.identify(),
    'cassette': {'path': file.path, 'mode': mode.name},
  };

  @override
  Future<LlmResponse> complete(LlmRequest request, {CancellationToken? cancellation}) =>
      _answer(request, () => inner.complete(request, cancellation: cancellation));

  @override
  Future<LlmResponse> completeStreaming(LlmRequest request, {required void Function(String delta) onTextDelta, CancellationToken? cancellation}) =>
      _answer(request, () async {
        if (inner case final LlmStreamingClient streaming) {
          return streaming.completeStreaming(request, onTextDelta: onTextDelta, cancellation: cancellation);
        }
        final response = await inner.complete(request, cancellation: cancellation);
        if (response.text.isNotEmpty) onTextDelta(response.text);
        return response;
      });

  Future<LlmResponse> _answer(LlmRequest request, Future<LlmResponse> Function() send) async {
    final key = requestKey(request, model: inner.model);
    if (mode != .record) {
      final recorded = _recorded[key];
      if (recorded != null && recorded.isNotEmpty) {
        final index = _served.update(key, (n) => n + 1, ifAbsent: () => 0);
        replayed++;
        return recorded[index < recorded.length ? index : recorded.length - 1];
      }
      if (mode == .replay) {
        throw LlmClientException(
          'cassette ${file.path} holds no answer for this request (key $key): the conversation left the recording',
          kind: LlmErrorKind.badRequest,
        );
      }
    }
    final response = await send();
    live++;
    _recorded.putIfAbsent(key, () => []).add(response);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${jsonEncode({'key': key, 'model': inner.model, 'response': responseToJson(response)})}\n',
      mode: FileMode.append,
      flush: true,
    );
    return response;
  }

  /// The fingerprint a request is recorded under.
  static String requestKey(LlmRequest request, {required String model}) => jsonFingerprint({
    'model': model,
    'messages': [
      for (final m in request.messages)
        {
          'role': m.role.name,
          'content': m.content,
          if (m.toolCalls.isNotEmpty)
            'toolCalls': [
              for (final call in m.toolCalls) {'name': call.name, 'arguments': call.arguments, 'argumentsError': ?call.argumentsError},
            ],
          'toolCallId': ?m.toolCallId,
          'toolName': ?m.toolName,
        },
    ],
    'tools': [
      for (final tool in request.tools) {'name': tool.name, 'description': tool.description, 'parameters': tool.parameters},
    ],
    'temperature': request.temperature,
    'maxTokens': request.maxTokens,
    'parallelToolCalls': request.parallelToolCalls,
    'responseSchema': request.responseSchema,
  });

  static JsonMap responseToJson(LlmResponse response) => {
    'text': response.text,
    'toolCalls': [
      for (final call in response.toolCalls) {'id': call.id, 'name': call.name, 'arguments': call.arguments, 'argumentsError': ?call.argumentsError},
    ],
    'usage': {
      'promptTokens': response.usage.promptTokens,
      'completionTokens': response.usage.completionTokens,
      'cachedPromptTokens': response.usage.cachedPromptTokens,
      'cacheWriteTokens': response.usage.cacheWriteTokens,
      'reasoningTokens': response.usage.reasoningTokens,
    },
    'model': response.model,
    'stopReason': ?response.stopReason,
    'firstTokenMs': ?response.firstTokenMs,
    'thinking': ?response.thinking,
  };

  static LlmResponse responseFromJson(JsonMap json) {
    final usage = asJsonMap(json['usage']);
    int count(String name) => (usage[name] as num?)?.toInt() ?? 0;
    return LlmResponse(
      text: json['text'] as String? ?? '',
      toolCalls: [
        for (final raw in json['toolCalls'] as List? ?? const [])
          LlmToolCall(
            id: '${asJsonMap(raw)['id']}',
            name: '${asJsonMap(raw)['name']}',
            arguments: asJsonMap(asJsonMap(raw)['arguments']),
            argumentsError: asJsonMap(raw)['argumentsError'] as String?,
          ),
      ],
      usage: LlmUsage(
        promptTokens: count('promptTokens'),
        completionTokens: count('completionTokens'),
        cachedPromptTokens: count('cachedPromptTokens'),
        cacheWriteTokens: count('cacheWriteTokens'),
        reasoningTokens: count('reasoningTokens'),
      ),
      model: json['model'] as String? ?? '',
      stopReason: json['stopReason'] as String?,
      firstTokenMs: (json['firstTokenMs'] as num?)?.toInt(),
      thinking: json['thinking'] as String?,
    );
  }
}

final class _WindowedCassette extends CassetteLlmClient implements LlmContextWindow {
  _WindowedCassette(super.inner, super.file, super.mode) : super._();

  @override
  int get contextTokens => (inner as LlmContextWindow).contextTokens;
}
