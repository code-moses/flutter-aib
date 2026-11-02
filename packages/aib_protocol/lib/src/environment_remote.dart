import 'package:aib_core/aib_core.dart';

import 'message.dart';
import 'transport.dart';

/// Engine-side proxy for an environment behind the wire (Environment Protocol
/// 2.0).
///
/// State fingerprints and resource samples are optional: when the environment
/// advertises them in the handshake, the proxy offers them to the engine.
base class RemoteEnvironment implements BenchmarkEnvironment, ResourceSampler {
  RemoteEnvironment._(this._peer, this.capabilities);

  final RpcPeer _peer;

  /// Optional methods the environment serves.
  final Set<String> capabilities;

  static Future<RemoteEnvironment> connect(AibTransport transport) async {
    final peer = RpcPeer(transport);
    final capabilities = await Handshake.perform(peer, role: 'engine');
    return capabilities.contains(Methods.envStateFingerprint)
        ? _FingerprintingRemoteEnvironment._(peer, capabilities)
        : RemoteEnvironment._(peer, capabilities);
  }

  @override
  Future<EnvironmentDescriptor> describe() async {
    final response = await _peer.request(Methods.envDescribe);
    return EnvironmentDescriptor.fromJson(asJsonMap(response['descriptor']));
  }

  @override
  Future<void> reset(FixtureRef fixture) async {
    await _peer.request(Methods.envReset, {'fixture': fixture.toJson()});
  }

  @override
  Future<EnvelopeResult> handle(Envelope envelope) async {
    final response = await _peer.request(Methods.envHandle, {'envelope': envelope.toJson()});
    return EnvelopeResult.fromJson(asJsonMap(response['result']));
  }

  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) async {
    final response = await _peer.request(Methods.envCaptureFinalState, {'queries': queries.map((q) => q.toJson()).toList()});
    return FinalStateSnapshot.fromJson(asJsonMap(response['snapshot']));
  }

  /// Empty when the environment does not sample; the engine skips an empty
  /// sample.
  @override
  Future<JsonMap> sampleResources() async {
    if (!capabilities.contains(Methods.envSampleResources)) return const {};
    return asJsonMap((await _peer.request(Methods.envSampleResources))['sample']);
  }

  Future<void> close() => _peer.close();
}

final class _FingerprintingRemoteEnvironment extends RemoteEnvironment implements StateFingerprintProvider {
  _FingerprintingRemoteEnvironment._(super.peer, super.capabilities) : super._();

  @override
  Future<String> stateFingerprint() async => (await _peer.request(Methods.envStateFingerprint))['fingerprint'] as String;
}

/// Serves a [BenchmarkEnvironment] over a transport. Optional capabilities
/// the environment implements are advertised in the handshake.
final class EnvironmentProtocolServer {
  EnvironmentProtocolServer(this.environment, AibTransport transport) : _peer = RpcPeer(transport) {
    _peer.onRequest = _dispatch;
  }

  final BenchmarkEnvironment environment;
  final RpcPeer _peer;

  List<String> get _capabilities => [
    if (environment is StateFingerprintProvider) Methods.envStateFingerprint,
    if (environment is ResourceSampler) Methods.envSampleResources,
  ];

  Future<JsonMap> _dispatch(String method, JsonMap params) async {
    switch (method) {
      case Methods.handshake:
        return Handshake.answer(params, role: 'environment', capabilities: _capabilities);
      case Methods.envDescribe:
        return {'descriptor': (await environment.describe()).toJson()};
      case Methods.envReset:
        await environment.reset(FixtureRef.fromJson(asJsonMap(params['fixture'])));
        return const {};
      case Methods.envHandle:
        final result = await environment.handle(Envelope.fromJson(asJsonMap(params['envelope'])));
        return {'result': result.toJson()};
      case Methods.envCaptureFinalState:
        final snapshot = await environment.captureFinalState([
          for (final q in params['queries'] as List? ?? const []) StateQuery.fromJson(asJsonMap(q)),
        ]);
        return {'snapshot': snapshot.toJson()};
      case Methods.envStateFingerprint when environment is StateFingerprintProvider:
        return {'fingerprint': await (environment as StateFingerprintProvider).stateFingerprint()};
      case Methods.envSampleResources when environment is ResourceSampler:
        return {'sample': await (environment as ResourceSampler).sampleResources()};
      default:
        throw ProtocolException(RpcErrorCodes.methodNotFound, 'Unknown method "$method"');
    }
  }

  Future<void> close() => _peer.close();
}
