import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aib_core/aib_core.dart';

import 'message.dart';

/// Bidirectional message channel. Implementations: [LineJsonTransport]
/// (newline-delimited JSON — stdio for a child process, the simplest way to
/// attach e.g. a Python agent), [SubprocessTransport], [SocketTransport] (a
/// TCP peer the engine connects to, for hosts that may not spawn processes)
/// and [InMemoryTransportPair] (tests).
///
/// A line that is not a JSON-RPC 2.0 message arrives on [incoming] as an
/// error event carrying a [ProtocolException]; the stream continues.
abstract interface class AibTransport {
  Stream<ProtocolMessage> get incoming;
  void send(ProtocolMessage message);
  Future<void> close();
}

/// Newline-delimited JSON-RPC 2.0 over arbitrary byte streams (spec §4.5
/// "stdio").
final class LineJsonTransport implements AibTransport {
  LineJsonTransport({required Stream<List<int>> input, required this.output}) {
    _incoming = input
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.trim().isNotEmpty)
        // A decoding failure becomes an error event, not the end of the
        // stream: one stray `print` in an agent must not kill the engine.
        .map(ProtocolMessage.decode)
        .asBroadcastStream();
  }

  factory LineJsonTransport.stdio() => LineJsonTransport(input: stdin, output: stdout);

  final IOSink output;
  late final Stream<ProtocolMessage> _incoming;

  @override
  Stream<ProtocolMessage> get incoming => _incoming;

  @override
  void send(ProtocolMessage message) => output.writeln(message.encode());

  @override
  Future<void> close() => output.close();
}

/// Starts an executable and speaks line-delimited JSON-RPC on its stdin and
/// stdout; its stderr is forwarded to the run log with a prefix, so a Python
/// traceback does not surface as a timeout (ADR 0007).
final class SubprocessTransport implements AibTransport {
  SubprocessTransport._(this._process, this._delegate);

  final Process _process;
  final LineJsonTransport _delegate;

  static Future<SubprocessTransport> spawn(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    IOSink? diagnostics,
  }) async {
    final process = await Process.start(executable, arguments, workingDirectory: workingDirectory, environment: environment);
    final log = diagnostics ?? stderr;
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => log.writeln('[${executable.split(Platform.pathSeparator).last}] $line'));
    return SubprocessTransport._(process, LineJsonTransport(input: process.stdout, output: process.stdin));
  }

  Future<int> get exitCode => _process.exitCode;

  @override
  Stream<ProtocolMessage> get incoming => _delegate.incoming;

  @override
  void send(ProtocolMessage message) => _delegate.send(message);

  @override
  Future<void> close() async {
    await _delegate.close();
    // The child terminates on EOF; kill only if it insists on staying.
    // (A real exit code can be negative — killed by signal — so the
    // timeout needs a sentinel that cannot collide with one.)
    final exited = await _process.exitCode.then<int?>((code) => code).timeout(const Duration(seconds: 5), onTimeout: () => null);
    if (exited == null) _process.kill();
  }
}

/// Line-delimited JSON-RPC over TCP: the engine connects out to an agent it
/// may not spawn (a sandboxed macOS test build has the network-client
/// entitlement and no way to start a process). ARTEMIS listens this way.
final class SocketTransport implements AibTransport {
  SocketTransport._(this._socket, this._delegate);

  final Socket _socket;
  final LineJsonTransport _delegate;

  static Future<SocketTransport> connect(String host, int port, {Duration timeout = const Duration(seconds: 10)}) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    return SocketTransport._(
      socket,
      // A Socket is a Stream<Uint8List>; the line decoder wants List<int>.
      LineJsonTransport(input: socket.cast<List<int>>(), output: socket),
    );
  }

  @override
  Stream<ProtocolMessage> get incoming => _delegate.incoming;

  @override
  void send(ProtocolMessage message) => _delegate.send(message);

  @override
  Future<void> close() async {
    await _delegate.close();
    await _socket.close();
  }
}

/// Two connected in-memory transports; every message is encoded and decoded
/// on the way, so in-memory behaves exactly like the wire.
final class InMemoryTransportPair {
  InMemoryTransportPair() {
    final aToB = StreamController<ProtocolMessage>.broadcast();
    final bToA = StreamController<ProtocolMessage>.broadcast();
    a = _InMemoryTransport(incoming: bToA.stream, outgoing: aToB);
    b = _InMemoryTransport(incoming: aToB.stream, outgoing: bToA);
  }

  late final AibTransport a;
  late final AibTransport b;
}

final class _InMemoryTransport implements AibTransport {
  _InMemoryTransport({required this.incoming, required this.outgoing});

  @override
  final Stream<ProtocolMessage> incoming;
  final StreamController<ProtocolMessage> outgoing;

  @override
  void send(ProtocolMessage message) {
    try {
      outgoing.add(ProtocolMessage.decode(message.encode()));
    } on ProtocolException catch (e) {
      outgoing.addError(e);
    }
  }

  /// Sends raw text as a peer would put it on the wire — for tests of what
  /// an endpoint does with a malformed line.
  void sendRaw(String line) {
    try {
      outgoing.add(ProtocolMessage.decode(line));
    } on ProtocolException catch (e) {
      outgoing.addError(e);
    }
  }

  @override
  Future<void> close() => outgoing.close();
}

/// Test hook: [sendRaw] on an in-memory transport.
extension RawInMemorySend on AibTransport {
  void sendRaw(String line) => (this as _InMemoryTransport).sendRaw(line);
}

/// Request/response correlation over a transport, both directions. Every
/// request ends: with its response, with a timeout, or with
/// [RpcErrorCodes.connectionClosed] when the transport ends or fails.
final class RpcPeer {
  RpcPeer(this.transport, {this.requestTimeout = const Duration(minutes: 5)}) {
    _subscription = transport.incoming.listen(
      _onMessage,
      onError: _onError,
      onDone: () => _failPending(const ProtocolException(RpcErrorCodes.connectionClosed, 'the peer closed the connection')),
    );
  }

  final AibTransport transport;
  final Duration requestTimeout;
  final Map<Object, Completer<ProtocolMessage>> _pending = {};
  Future<JsonMap> Function(String method, JsonMap params)? onRequest;
  StreamSubscription<ProtocolMessage>? _subscription;
  int _nextId = 0;

  Future<JsonMap> request(String method, [JsonMap params = const {}]) async {
    final id = _nextId++;
    final completer = Completer<ProtocolMessage>();
    _pending[id] = completer;
    transport.send(ProtocolMessage.request(id, method, params));
    final ProtocolMessage response;
    try {
      response = await completer.future.timeout(requestTimeout);
    } on TimeoutException {
      throw ProtocolException(RpcErrorCodes.timeout, '$method: no response within ${requestTimeout.inSeconds}s');
    } finally {
      _pending.remove(id);
    }
    final error = response.error;
    if (error != null) {
      throw ProtocolException(error.code, error.message, data: error.data);
    }
    return response.result ?? const {};
  }

  void notify(String method, [JsonMap params = const {}]) => transport.send(ProtocolMessage.notification(method, params));

  void _onError(Object error, [StackTrace? _]) {
    if (error is ProtocolException) {
      // JSON-RPC 2.0: an unreadable message is answered with an error whose
      // id is the message's own, or null when it could not be read.
      transport.send(ProtocolMessage.errorResponse(error.id, error.toError()));
      return;
    }
    _failPending(ProtocolException(RpcErrorCodes.connectionClosed, 'transport: $error'));
  }

  void _failPending(ProtocolException error) {
    final waiting = _pending.values.toList();
    _pending.clear();
    for (final completer in waiting) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }

  Future<void> _onMessage(ProtocolMessage message) async {
    if (message.isResponse) {
      final id = message.id;
      if (id != null) _pending.remove(id)?.complete(message);
      return;
    }
    if (message.isNotification) return; // none defined yet
    final handler = onRequest;
    if (handler == null) {
      transport.send(ProtocolMessage.errorResponse(message.id, const ProtocolError(code: RpcErrorCodes.methodNotFound, message: 'No handler')));
      return;
    }
    try {
      final result = await handler(message.method!, message.params);
      transport.send(ProtocolMessage.response(message.id, result));
    } on ProtocolException catch (e) {
      transport.send(ProtocolMessage.errorResponse(message.id, e.toError()));
    } catch (e) {
      transport.send(ProtocolMessage.errorResponse(message.id, ProtocolError(code: RpcErrorCodes.internalError, message: e.toString())));
    }
  }

  Future<void> close() async {
    await _subscription?.cancel();
    _failPending(const ProtocolException(RpcErrorCodes.connectionClosed, 'the connection was closed'));
    await transport.close();
  }
}

/// The handshake both sides run: protocol version and optional capabilities.
abstract final class Handshake {
  /// Params of the engine's `aib.handshake` request.
  static JsonMap request({required String role}) => {'protocolVersion': aibProtocolVersion, 'role': role};

  /// The server side: refuses another major version, else accepts and lists
  /// the optional methods it serves.
  static JsonMap answer(JsonMap params, {required String role, required List<String> capabilities}) {
    final version = params['protocolVersion'];
    if (version is! String || version.split('.').first != aibProtocolVersion.split('.').first) {
      throw ProtocolException(
        RpcErrorCodes.versionMismatch,
        'peer speaks AIB protocol $version, this endpoint speaks '
        '$aibProtocolVersion',
      );
    }
    return {'protocolVersion': aibProtocolVersion, 'accepted': true, 'role': role, 'capabilities': capabilities};
  }

  /// The client side: the capabilities the server accepted with.
  static Future<Set<String>> perform(RpcPeer peer, {required String role}) async {
    final answer = await peer.request(Methods.handshake, request(role: role));
    if (answer['accepted'] != true) {
      throw const ProtocolException(RpcErrorCodes.handshakeRejected, 'Peer rejected the handshake');
    }
    return {for (final c in answer['capabilities'] as List? ?? const []) '$c'};
  }
}
