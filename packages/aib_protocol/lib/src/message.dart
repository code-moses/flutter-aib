import 'dart:convert';

import 'package:aib_core/aib_core.dart';

/// Version of the AIB Agent and Environment Protocol, negotiated in the
/// `aib.handshake` exchange. `2.0` moved the framing to JSON-RPC 2.0.
const String aibProtocolVersion = '2.0';

/// Framing version every message carries (JSON-RPC 2.0).
const String jsonRpcVersion = '2.0';

abstract final class Methods {
  // Handshake (version + capability negotiation).
  static const handshake = 'aib.handshake';

  // Agent Protocol.
  static const agentManifest = 'agent.manifest';
  static const agentStartEpisode = 'agent.startEpisode';
  static const agentNext = 'agent.next';
  static const agentEndEpisode = 'agent.endEpisode';

  /// Optional, advertised in the handshake.
  static const agentWarmUp = 'agent.warmUp';

  /// Optional, advertised in the handshake.
  static const agentModelIdentity = 'agent.modelIdentity';

  // Environment Protocol.
  static const envDescribe = 'env.describe';
  static const envReset = 'env.reset';
  static const envHandle = 'env.handle';
  static const envCaptureFinalState = 'env.captureFinalState';

  /// Optional, advertised in the handshake: keeps state-diff metrics
  /// (`kind_integrity_violations`, the repeat guard for acts) over the wire.
  static const envStateFingerprint = 'env.stateFingerprint';

  /// Optional, advertised in the handshake.
  static const envSampleResources = 'env.sampleResources';
}

/// JSON-RPC 2.0 error codes, plus the AIB range (-32000 … -32099).
abstract final class RpcErrorCodes {
  static const parseError = -32700;
  static const invalidRequest = -32600;
  static const methodNotFound = -32601;
  static const invalidParams = -32602;
  static const internalError = -32603;

  /// The peer speaks an incompatible major version of the AIB protocol.
  static const versionMismatch = -32001;

  /// The handshake was refused.
  static const handshakeRejected = -32002;

  /// The connection ended before the request was answered.
  static const connectionClosed = -32003;

  /// No answer within the request timeout.
  static const timeout = -32004;
}

final class ProtocolError {
  const ProtocolError({required this.code, required this.message, this.data});

  final int code;
  final String message;
  final Object? data;

  JsonMap toJson() => {'code': code, 'message': message, if (data != null) 'data': data};

  factory ProtocolError.fromJson(JsonMap json) => ProtocolError(
    code: (json['code'] as num?)?.toInt() ?? RpcErrorCodes.internalError,
    message: json['message'] as String? ?? '',
    data: json['data'],
  );
}

/// One JSON-RPC 2.0 message: a request (method and id), a notification
/// (method, no id) or a response (id, and result or error).
///
/// Params and results are always objects in this protocol. Unknown members
/// are ignored, which is the forward-compatibility rule.
final class ProtocolMessage {
  const ProtocolMessage._({this.id, this.method, this.params = const {}, this.result, this.error});

  /// `String` or `int`; null for a notification, and for the error response
  /// to a message whose id could not be read.
  final Object? id;
  final String? method;
  final JsonMap params;
  final JsonMap? result;
  final ProtocolError? error;

  bool get isRequest => method != null && id != null;
  bool get isNotification => method != null && id == null;
  bool get isResponse => method == null;

  factory ProtocolMessage.request(Object id, String method, [JsonMap params = const {}]) => ProtocolMessage._(id: id, method: method, params: params);

  factory ProtocolMessage.notification(String method, [JsonMap params = const {}]) => ProtocolMessage._(method: method, params: params);

  factory ProtocolMessage.response(Object? id, JsonMap result) => ProtocolMessage._(id: id, result: result);

  factory ProtocolMessage.errorResponse(Object? id, ProtocolError error) => ProtocolMessage._(id: id, error: error);

  JsonMap toJson() => {
    'jsonrpc': jsonRpcVersion,
    if (id != null || isResponse) 'id': id,
    if (method != null) 'method': method,
    if (method != null) 'params': params,
    if (isResponse && error == null) 'result': result ?? const {},
    'error': ?error?.toJson(),
  };

  /// Decodes one message; throws [ProtocolException] with
  /// [RpcErrorCodes.invalidRequest] when it is not JSON-RPC 2.0.
  factory ProtocolMessage.fromJson(JsonMap json) {
    if (json['jsonrpc'] != jsonRpcVersion) {
      throw ProtocolException(
        RpcErrorCodes.invalidRequest,
        json.containsKey('aib')
            ? 'AIB protocol 1.x framing; this endpoint speaks '
                  '$aibProtocolVersion (JSON-RPC 2.0)'
            : 'not a JSON-RPC 2.0 message',
        id: json['id'],
      );
    }
    final id = json['id'];
    if (id != null && id is! String && id is! int) {
      throw ProtocolException(RpcErrorCodes.invalidRequest, 'id must be a string or an integer');
    }
    final method = json['method'];
    if (method != null && method is! String) {
      throw ProtocolException(RpcErrorCodes.invalidRequest, 'method must be a string', id: id);
    }
    return ProtocolMessage._(
      id: id,
      method: method as String?,
      params: asJsonMap(json['params']),
      result: json.containsKey('result') ? asJsonMap(json['result']) : null,
      error: json['error'] == null ? null : ProtocolError.fromJson(asJsonMap(json['error'])),
    );
  }

  /// Decodes one line of the wire; throws [ProtocolException] with
  /// [RpcErrorCodes.parseError] when it is not a JSON object.
  static ProtocolMessage decode(String line) {
    final Object? json;
    try {
      json = jsonDecode(line);
    } on FormatException catch (e) {
      throw ProtocolException(RpcErrorCodes.parseError, e.message);
    }
    if (json is! Map) {
      throw const ProtocolException(RpcErrorCodes.invalidRequest, 'a message must be a JSON object');
    }
    return ProtocolMessage.fromJson(asJsonMap(json));
  }

  String encode() => jsonEncode(toJson());
}

final class ProtocolException implements Exception {
  const ProtocolException(this.code, this.message, {this.id, this.data});

  final int code;
  final String message;

  /// The id of the message that caused it, when it could be read.
  final Object? id;
  final Object? data;

  ProtocolError toError() => ProtocolError(code: code, message: message, data: data);

  @override
  String toString() => 'ProtocolException($code): $message';
}
