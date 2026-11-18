import 'dart:convert';

import 'package:aib_core/ports.dart';

import 'llm_client.dart';
import 'llm_http.dart';
import 'openai_client.dart';

/// llama.cpp's `llama-server`, spoken to through its OpenAI-compatible
/// `/v1/chat/completions` and the few native endpoints that matter for a
/// benchmark.
///
/// Why a client of its own rather than `provider: openai` with a `baseUrl`:
/// the generic client cannot say what makes a llama.cpp run reproducible, and
/// cannot read what the server reports.
///
/// - **Prompt cache** is requested explicitly (`cache_prompt`), and the hit is
///   read from `timings.cache_n`; the OpenAI usage block of this server carries
///   no cached-token count.
/// - **Time to first token** is the server's own `timings.prompt_ms`.
/// - **Thinking** is a per-request template switch (`think`), not a server
///   flag, so the arm file says what was measured. `false`/`true` set
///   `enable_thinking`; a level string (`low`, `medium`, `high`, gpt-oss) sets
///   `reasoning_effort`.
/// - **Identity**: `/props` names the GGUF the server loaded, its build and
///   the context each slot has. An Ollama blob path ends in the SHA-256 of the
///   file, so the digest is recorded when the server was started from one.
/// - **Context**: [contextTokens] is what the arm *expects* the server to give
///   one request (`-c` divided by `--parallel`). [warmUp] fails the run if the
///   server gives less: a silent mismatch would truncate prompts and measure
///   the wrong thing.
///
/// The server is started by the operator (`tool/llama_server.sh`); this client
/// never launches a process, so an app on a device can use it too.
final class LlamaCppClient extends OpenAiClient implements LlmWarmUp, LlmPrefixWarmUp, LlmModelIdentity, LlmContextWindow, LlmStructuredOutput {
  LlamaCppClient({
    required super.model,
    super.baseUrl = defaultBaseUrl,
    this.contextTokens = 32768,
    this.think,
    this.cachePrompt = true,
    this.warmUpTimeout = const Duration(minutes: 10),
    super.retryPolicy,
    super.httpClient,
  }) : assert(think == null || think is bool || think is String, 'think must be a bool or a reasoning level string');

  static const defaultBaseUrl = 'http://localhost:8080';

  /// What one request may use. Checked against the server in [warmUp].
  @override
  final int contextTokens;

  /// `false` disables the reasoning phase, `true` forces it, `null` leaves the
  /// chat template's default; a string is a graded level.
  final Object? think;

  /// `cache_prompt`: reuse the slot's KV cache for a shared prefix. The server
  /// default; stated so the manifest records it and an arm can switch it off.
  final bool cachePrompt;

  /// How long [warmUp] waits for a server that is still loading its weights.
  final Duration warmUpTimeout;

  /// llama-server compiles a JSON schema to a grammar (`response_format`).
  @override
  bool get supportsResponseSchema => true;

  @override
  Uri get endpoint => Uri.parse('$baseUrl/v1/chat/completions');

  @override
  JsonMap buildBody(LlmRequest request) {
    final body = super.buildBody(request);
    // `max_tokens` is the name this server's own docs use; the newer OpenAI
    // spelling is not accepted by every build.
    body['max_tokens'] = body.remove('max_completion_tokens');
    body['stream'] = false;
    // A turn in which the model said nothing and called nothing stays in the
    // history, and the loop nudges it again. OpenAI's schema lets such an
    // assistant message omit both fields; llama-server answers HTTP 400
    // ("Assistant message must contain either 'content' or 'tool_calls'"), which
    // aborted the episode where Ollama carries on.
    for (final message in body['messages'] as List) {
      if (message is Map && message['role'] == 'assistant' && !message.containsKey('content') && !message.containsKey('tool_calls')) {
        message['content'] = '';
      }
    }
    body['cache_prompt'] = cachePrompt;
    final kwargs = switch (think) {
      final bool enabled => {'enable_thinking': enabled},
      final String level => {'reasoning_effort': level},
      _ => null,
    };
    if (kwargs != null) body['chat_template_kwargs'] = kwargs;
    final schema = request.responseSchema;
    if (schema != null) {
      body['response_format'] = {
        'type': 'json_schema',
        'json_schema': {'name': 'tool_call', 'strict': true, 'schema': schema},
      };
    }
    return body;
  }

  @override
  Future<LlmResponse> complete(LlmRequest request, {CancellationToken? cancellation}) => withRetries(
    () async =>
        parseResponseBody(await postJson(httpClient, url: endpoint, headers: headers, body: jsonEncode(buildBody(request))), parseLlamaCppResponse),
    policy: retryPolicy,
    cancellation: cancellation,
  );

  /// [OpenAiClient.parseResponse] plus what only llama-server reports.
  static LlmResponse parseLlamaCppResponse(JsonMap json) {
    final base = OpenAiClient.parseResponse(json);
    final timings = asJsonMap(json['timings']);
    final cached = (timings['cache_n'] as num?)?.toInt() ?? base.usage.cachedPromptTokens;
    final promptMs = (timings['prompt_ms'] as num?)?.round();
    return LlmResponse(
      text: base.text,
      thinking: base.thinking,
      toolCalls: base.toolCalls,
      usage: LlmUsage(
        // `usage.prompt_tokens` of this server is the whole prompt, cached
        // part included: the same contract as every other client.
        promptTokens: base.usage.promptTokens,
        completionTokens: base.usage.completionTokens,
        cachedPromptTokens: cached,
        reasoningTokens: base.usage.reasoningTokens,
      ),
      model: base.model,
      stopReason: base.stopReason,
      firstTokenMs: promptMs,
    );
  }

  /// Waits until the server has loaded the model (`/health` is 503 while it
  /// does), then checks the context it gives a request.
  @override
  Future<void> warmUp() async {
    final deadline = DateTime.now().add(warmUpTimeout);
    while (true) {
      try {
        final response = await httpClient.get(Uri.parse('$baseUrl/health'));
        if (response.statusCode == 200) break;
      } on Object {
        // Not listening yet: the operator may have started it a moment ago.
      }
      if (DateTime.now().isAfter(deadline)) {
        throw LlmClientException('llama-server at $baseUrl not ready after ${warmUpTimeout.inSeconds}s', kind: LlmErrorKind.server);
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    final props = await _props();
    // Ollama keeps the chat template outside the GGUF; a blob without one makes
    // llama-server fall back to ChatML, which renders no tools. The model then
    // answers a prompt that never mentions them.
    if (props['supports_tools'] == false) {
      throw LlmClientException(
        'the chat template of the model llama-server loaded renders no tools '
        '(${props['model_path']}): use the vendor GGUF, or --chat-template-file',
        kind: LlmErrorKind.badRequest,
      );
    }
    final perSlot = props['n_ctx'];
    if (perSlot is int && perSlot < contextTokens) {
      throw LlmClientException(
        'llama-server gives one request $perSlot tokens of context, the arm expects $contextTokens '
        '(start it with -c $contextTokens --parallel 1)',
        kind: LlmErrorKind.badRequest,
      );
    }
  }

  /// Evaluates the prompt and stops after one token, so the slot's cache holds
  /// the prefix when the next request arrives.
  @override
  Future<void> warmPrefix(LlmRequest request) async {
    try {
      await postJson(httpClient, url: endpoint, headers: headers, body: jsonEncode({...buildBody(request), 'max_tokens': 1}));
    } on LlmClientException {
      // A failed warm-up costs the next call its cache, nothing more.
    }
  }

  /// `/props`: the loaded GGUF, build and slot context.
  Future<JsonMap> _props() async {
    final response = await httpClient.get(Uri.parse('$baseUrl/props'));
    final decoded = jsonDecode(response.body);
    final props = decoded is Map ? asJsonMap(decoded) : const <String, Object?>{};
    final settings = asJsonMap(asJsonMap(props['default_generation_settings'])['n_ctx'] == null ? null : props['default_generation_settings']);
    return {
      'n_ctx': (settings['n_ctx'] as num?)?.toInt(),
      'model_path': props['model_path'],
      'build_info': props['build_info'],
      'total_slots': props['total_slots'],
      'modalities': props['modalities'],
      'supports_tools': asJsonMap(props['chat_template_caps'])['supports_tools'],
    };
  }

  @override
  Future<JsonMap> modelIdentity() async {
    final props = await _props();
    final path = props['model_path'] as String?;
    final file = path?.split('/').last;
    // Ollama names its blobs `sha256-<digest>`.
    final digest = file != null && file.startsWith('sha256-') ? file.substring(7) : null;
    return {
      'provider': 'llamacpp',
      'model': model,
      'digest': digest,
      'file': file,
      'build': props['build_info'],
      'ctxPerSlot': props['n_ctx'],
      'slots': props['total_slots'],
      'supportsTools': props['supports_tools'],
      'cachePrompt': cachePrompt,
    };
  }
}
