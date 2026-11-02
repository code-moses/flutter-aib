/// Decision models ("System One", Jev) for Dart.
///
/// A decision model reads a state — text, JSON or a conversation — and
/// answers typed questions (`choice`, `score`, `noul`) with a distribution
/// instead of text. This package is everything around the forward pass:
///
/// - the typed request/answer model ([JevRequest], [JevQuestionSet],
///   [JevResponse]) and the [JevClient] port;
/// - remote backends: [HttpJevClient] for the hosted API, Featherless and
///   self-hosted System One servers (simple-jev, LiteVar, openjev);
/// - local backends: [LogitJevClient] — the v1 prompt template and scoring
///   ported from simple-jev and golden-tested against it — over a
///   [JevLogits] source: [OllamaJevLogits], [OpenAiCompletionsJevLogits]
///   (llama-server, vLLM, LM Studio), or an in-process runtime;
/// - ready-made decisions ([JevRouter], [JevCompletionCheck], [JevSelector],
///   [JevGuard]) with English and German texts and a [JevLanguagePolicy];
/// - [JevConfig], which builds any of these from a `jev:` block.
///
/// App-safe: no dart:io, no Flutter, and no dependency on the benchmark
/// beyond `aib_core`'s transport primitives ([CancellationToken],
/// [RetryPolicy], [TransportException]). Enforced by
/// `tool/check_app_safe_entrypoints.dart`.
library;

export 'package:aib_core/transport.dart' show CancellationToken, JsonMap, RetryPolicy, asJsonMap, TransportErrorKind, TransportException;

export 'src/answer.dart';
export 'src/backends/ollama.dart';
export 'src/backends/openai_completions.dart';
export 'src/chat_format.dart';
export 'src/client.dart';
export 'src/config.dart';
export 'src/decisions.dart';
export 'src/http_client.dart';
export 'src/language.dart';
export 'src/logits.dart';
export 'src/request.dart';
export 'src/scoring.dart';
export 'src/template.dart';
export 'src/transport_http.dart';
