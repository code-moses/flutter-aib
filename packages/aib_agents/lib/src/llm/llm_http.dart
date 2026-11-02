import 'dart:convert';

import 'package:aib_core/ports.dart';

import 'llm_client.dart';

export 'package:aib_core/transport.dart' show RetryPolicy, parseRetryAfter, withRetries;
export 'package:aib_jev/aib_jev.dart' show postJson;

/// How a client reacts to a failing provider — [RetryPolicy] under its
/// original name, so configs and manifest hashes stay as they were.
typedef LlmRetryPolicy = RetryPolicy;

/// A 200 body read by [parse], or a classified [LlmClientException] when it
/// cannot be: a proxy's HTML error page, a truncated body, a field of the wrong
/// type.
LlmResponse parseResponseBody(String body, LlmResponse Function(JsonMap json) parse) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw FormatException('expected a JSON object, got ${decoded.runtimeType}');
    return parse(asJsonMap(decoded));
  } on LlmClientException {
    rethrow;
  } on Object catch (e) {
    if (e is! FormatException && e is! TypeError && e is! ArgumentError) rethrow;
    final excerpt = body.length <= 200 ? body : '${body.substring(0, 200)}…';
    throw LlmClientException('malformed provider response ($e): $excerpt', kind: LlmErrorKind.server);
  }
}
