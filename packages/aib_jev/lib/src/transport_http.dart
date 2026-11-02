import 'package:aib_core/transport.dart';
import 'package:http/http.dart' as http;

/// One POST, turned into either a body or a classified [TransportException].
/// Every backend of this package goes through here so classification is
/// uniform — and identical to the LLM adapters', which share the exception.
Future<String> postJson(http.Client client, {required Uri url, required Map<String, String> headers, required String body}) async {
  final http.Response response;
  try {
    response = await client.post(url, headers: headers, body: body);
  } on TransportException {
    rethrow;
  } catch (e) {
    throw TransportException('$e', kind: .transport);
  }
  if (response.statusCode != 200) {
    throw TransportException.fromHttp(statusCode: response.statusCode, body: response.body, retryAfter: parseRetryAfter(response.headers));
  }
  return response.body;
}

/// One GET, classified the same way.
Future<String> getText(http.Client client, Uri url, {Map<String, String> headers = const {}}) async {
  final http.Response response;
  try {
    response = await client.get(url, headers: headers);
  } catch (e) {
    throw TransportException('$e', kind: .transport);
  }
  if (response.statusCode != 200) {
    throw TransportException.fromHttp(statusCode: response.statusCode, body: response.body);
  }
  return response.body;
}
