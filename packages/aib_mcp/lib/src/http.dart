import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:aib_core/aib_core.dart';
import 'package:stream_channel/stream_channel.dart';

/// The MCP Streamable HTTP transport (protocol 2025-06-18), server side, for
/// a dedicated benchmark machine that clients reach over the network.
///
/// One endpoint. A POST carries one JSON-RPC message: a request is answered
/// on a server-sent-event stream that also carries what the server sends
/// while handling it (progress, an elicitation), and closes with the
/// response; a notification or a response is accepted with 202. A GET opens
/// a stream for messages that belong to no request. `initialize` opens a
/// session (`Mcp-Session-Id`), DELETE ends it.
///
/// Every request needs `Authorization: Bearer <token>`; a browser origin
/// other than the allowed ones is refused, against DNS rebinding.
final class McpHttpServer {
  McpHttpServer._(this._http, this._token, this._allowedOrigins, this._connect, this.path);

  final HttpServer _http;
  final String _token;
  final Set<String> _allowedOrigins;
  final void Function(StreamChannel<String> channel) _connect;
  final String path;
  final _sessions = <String, _Session>{};

  int get port => _http.port;
  InternetAddress get address => _http.address;

  /// Binds [host]:[port] and serves [path]. [connect] starts an MCP server
  /// on a session's channel; the channel closes when the session ends.
  static Future<McpHttpServer> serve({
    required String token,
    required void Function(StreamChannel<String> channel) connect,
    Object host = '127.0.0.1',
    int port = 8765,
    String path = '/mcp',
    Set<String> allowedOrigins = const {},
  }) async {
    if (token.length < 16) throw ArgumentError('the bearer token must be at least 16 characters');
    final http = await HttpServer.bind(host, port);
    final server = McpHttpServer._(http, token, allowedOrigins, connect, path);
    http.listen(server._handle);
    return server;
  }

  Future<void> close() async {
    for (final session in _sessions.values.toList()) {
      await session.close();
    }
    await _http.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.uri.path != path) return await _fail(response, HttpStatus.notFound, 'not found');
      if (!_authorized(request)) {
        response.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Bearer');
        return await _fail(response, HttpStatus.unauthorized, 'missing or wrong bearer token');
      }
      final origin = request.headers.value('origin');
      if (origin != null && !_originAllowed(origin)) return await _fail(response, HttpStatus.forbidden, 'origin $origin is not allowed');
      switch (request.method) {
        case 'POST':
          await _post(request);
        case 'GET':
          await _get(request);
        case 'DELETE':
          final session = _sessions.remove(request.headers.value(_sessionHeader));
          if (session == null) return await _fail(response, HttpStatus.notFound, 'no such session');
          await session.close();
          response.statusCode = HttpStatus.noContent;
          await response.close();
        default:
          response.headers.set(HttpHeaders.allowHeader, 'GET, POST, DELETE');
          return await _fail(response, HttpStatus.methodNotAllowed, 'method not allowed');
      }
    } on Object catch (error) {
      try {
        await _fail(response, HttpStatus.internalServerError, '$error');
      } on Object {
        // The response was already streaming; the client sees the stream end.
      }
    }
  }

  static const _sessionHeader = 'mcp-session-id';

  bool _authorized(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (!header.startsWith('Bearer ')) return false;
    return _constantTimeEquals(header.substring(7), _token);
  }

  static bool _constantTimeEquals(String a, String b) {
    final x = utf8.encode(a);
    final y = utf8.encode(b);
    var diff = x.length ^ y.length;
    for (var i = 0; i < x.length && i < y.length; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }

  bool _originAllowed(String origin) {
    final uri = Uri.tryParse(origin);
    if (uri == null) return false;
    if (uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '::1' || uri.host == '[::1]') return true;
    return _allowedOrigins.contains(origin);
  }

  Future<void> _post(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final Object? message;
    try {
      message = jsonDecode(body);
    } on FormatException {
      return await _fail(request.response, HttpStatus.badRequest, 'body is not JSON');
    }
    if (message is! Map) return await _fail(request.response, HttpStatus.badRequest, 'one JSON-RPC message per POST');
    final json = asJsonMap(message);
    final isRequest = json.containsKey('method') && json.containsKey('id');

    _Session? session;
    if (json['method'] == 'initialize') {
      session = _Session(_newId(), _connect);
      _sessions[session.id] = session;
    } else {
      final id = request.headers.value(_sessionHeader);
      if (id == null) return await _fail(request.response, HttpStatus.badRequest, 'missing $_sessionHeader header');
      session = _sessions[id];
      if (session == null) return await _fail(request.response, HttpStatus.notFound, 'no such session');
    }

    if (!isRequest) {
      session.toServer.add(body);
      request.response.statusCode = HttpStatus.accepted;
      return request.response.close();
    }
    final response = request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8')
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-cache')
      ..headers.set(_sessionHeader, session.id)
      ..bufferOutput = false;
    final stream = _EventStream(response);
    final done = session.expect(json['id'], stream, progressToken: asJsonMap(asJsonMap(json['params'])['_meta'])['progressToken']);
    session.toServer.add(body);
    await done;
    await stream.close();
  }

  Future<void> _get(HttpRequest request) async {
    final accept = request.headers.value(HttpHeaders.acceptHeader) ?? '';
    if (!accept.contains('text/event-stream')) return await _fail(request.response, HttpStatus.notAcceptable, 'GET opens an event stream');
    final session = _sessions[request.headers.value(_sessionHeader)];
    if (session == null) return await _fail(request.response, HttpStatus.notFound, 'no such session');
    final response = request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8')
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-cache')
      ..bufferOutput = false;
    final stream = _EventStream(response);
    await session.listen(stream);
  }

  static Future<void> _fail(HttpResponse response, int status, String message) async {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'error': message}));
    await response.close();
  }

  static final _random = Random.secure();
  static String _newId() => List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// One client's MCP session: a channel to its server, and the open streams
/// the server's messages are routed to.
final class _Session {
  _Session(this.id, void Function(StreamChannel<String>) connect) {
    connect(StreamChannel<String>.withCloseGuarantee(toServer.stream, _fromServer.sink));
    _fromServer.stream.listen(_route, onDone: _closeAll);
  }

  final String id;
  final toServer = StreamController<String>();
  final _fromServer = StreamController<String>();

  /// Request id → the POST stream waiting for its response.
  final _pending = <String, ({_EventStream stream, Completer<void> done, Object? progressToken})>{};

  /// The GET stream, for messages that belong to no open request.
  _EventStream? _standalone;
  final _backlog = <String>[];

  Future<void> expect(Object? id, _EventStream stream, {Object? progressToken}) {
    final done = Completer<void>();
    _pending[jsonEncode(id)] = (stream: stream, done: done, progressToken: progressToken);
    return done.future;
  }

  Future<void> listen(_EventStream stream) async {
    await _standalone?.close();
    _standalone = stream;
    for (final message in _backlog) {
      stream.send(message);
    }
    _backlog.clear();
    await stream.closed;
    if (identical(_standalone, stream)) _standalone = null;
  }

  void _route(String message) {
    final json = asJsonMap(jsonDecode(message));
    final key = jsonEncode(json['id']);
    // A response closes the stream of the request it answers.
    if (!json.containsKey('method') && _pending.containsKey(key)) {
      final target = _pending.remove(key)!;
      target.stream.send(message);
      target.done.complete();
      return;
    }
    // Progress goes to the request whose token it carries; anything else the
    // server sends while handling a request (an elicitation, a log line)
    // goes to the most recent open request, else to the GET stream.
    final token = asJsonMap(json['params'])['progressToken'];
    final byToken = token == null ? null : _pending.values.where((p) => p.progressToken == token).firstOrNull;
    final target = byToken?.stream ?? _pending.values.lastOrNull?.stream ?? _standalone;
    if (target == null) {
      _backlog.add(message);
    } else {
      target.send(message);
    }
  }

  void _closeAll() {
    for (final pending in _pending.values) {
      if (!pending.done.isCompleted) pending.done.complete();
    }
    _pending.clear();
    _standalone?.close();
  }

  Future<void> close() async {
    await toServer.close();
    _closeAll();
  }
}

final class _EventStream {
  _EventStream(this._response) {
    _response.done.then((_) => _closed.complete(), onError: (_) => _closed.complete());
  }

  final HttpResponse _response;
  final _closed = Completer<void>();
  var _open = true;

  Future<void> get closed => _closed.future;

  /// Writes wait for the previous flush: an HTTP response refuses a write
  /// while it is flushing.
  var _chain = Future<void>.value();

  void send(String message) {
    if (!_open) return;
    _chain = _chain
        .then((_) async {
          _response.write('event: message\ndata: $message\n\n');
          await _response.flush();
        })
        .catchError((Object _) {});
  }

  Future<void> close() async {
    if (!_open) return;
    _open = false;
    await _chain;
    await _response.close();
  }
}
