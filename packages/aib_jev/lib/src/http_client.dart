import 'dart:convert';

import 'package:aib_core/transport.dart';
import 'package:http/http.dart' as http;

import 'answer.dart';
import 'client.dart';
import 'request.dart';
import 'transport_http.dart';

/// The System One wire format over HTTP.
///
/// simple-jev serves the same body at `/v1/systemone` as at
/// `/v1/classifier`, so one path reaches it, the hosted API and Featherless.
/// What differs is that a self-hosted server *requires* `model` (the id it
/// was started with) and a hosted one wants a bearer key.
final class HttpJevClient implements JevClient, JevServerInfo {
  HttpJevClient({
    required this.model,
    this.baseUrl = 'http://127.0.0.1:8000',
    this.path = '/v1/systemone',
    String? apiKey,
    this.headers = const {},
    this.retryPolicy = const RetryPolicy(timeout: Duration(seconds: 30)),
    http.Client? httpClient,
  }) : _apiKey = apiKey ?? '',
       _http = httpClient ?? http.Client();

  /// TypeSafe's hosted System One API.
  static const hostedBaseUrl = 'https://api.typesafe.ai';

  @override
  final String model;
  final String baseUrl;
  final String path;

  /// Extra headers (a proxy's tenant id, a trace header). Not a place for
  /// the key: that is `apiKey`, so redaction has one known target.
  final Map<String, String> headers;

  final RetryPolicy retryPolicy;
  final String _apiKey;
  final http.Client _http;

  JsonMap buildBody(JevRequest request) => request.toJson(model: model);

  @override
  Future<JevResponse> decide(JevRequest request, {CancellationToken? cancellation}) => withRetries(
    () async {
      final watch = Stopwatch()..start();
      final raw = await postJson(
        _http,
        url: Uri.parse('$baseUrl$path'),
        headers: {'content-type': 'application/json', if (_apiKey.isNotEmpty) 'authorization': 'Bearer $_apiKey', ...headers},
        body: jsonEncode(buildBody(request)),
      );
      return parseResponse(asJsonMap(jsonDecode(raw)), latencyMs: watch.elapsedMilliseconds);
    },
    policy: retryPolicy,
    cancellation: cancellation,
  );

  /// The hosted API names the model per answer, simple-jev once at the top;
  /// either is accepted, and the whole reply is kept for the fields no
  /// version of this client models.
  JevResponse parseResponse(JsonMap json, {int latencyMs = 0}) {
    final answers = asJsonMap(json['answers']);
    return JevResponse(
      answers: {for (final entry in answers.entries) entry.key: JevAnswer.fromJson(asJsonMap(entry.value))},
      model:
          json['model'] as String? ??
          [
            for (final raw in answers.values)
              if (asJsonMap(raw)['model'] case final String m) m,
          ].firstOrNull ??
          model,
      usage: JevUsage.fromJson(asJsonMap(json['usage'])),
      metadata: JevMetadata(raw: asJsonMap(json['metadata'])),
      latencyMs: latencyMs,
      raw: json,
    );
  }

  @override
  Future<List<String>> models() async {
    final json = jsonDecode(await _get(Uri.parse('$baseUrl/v1/models')));
    // OpenAI's `{data: [{id}]}`, or a bare list.
    final data = json is Map ? asJsonMap(json)['data'] : json;
    return [
      for (final entry in data as List? ?? const [])
        if (entry is Map) '${asJsonMap(entry)['id'] ?? asJsonMap(entry)['model']}' else '$entry',
    ];
  }

  @override
  Future<JsonMap?> health() async {
    try {
      return asJsonMap(jsonDecode(await _get(Uri.parse('$baseUrl/health'))));
    } on TransportException catch (e) {
      // A hosted API has no /health; that is not a failure of the backend.
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<String> _get(Uri url) => getText(_http, url, headers: {if (_apiKey.isNotEmpty) 'authorization': 'Bearer $_apiKey', ...headers});
}
