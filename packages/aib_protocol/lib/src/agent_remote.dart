import 'package:aib_core/aib_core.dart';

import 'message.dart';
import 'transport.dart';

/// Engine-side proxy for an agent behind the wire (Agent Protocol 2.0).
///
/// Warm-up and model identity are optional: forwarded when the agent
/// advertised them in the handshake, a no-op (and the manifest's model)
/// otherwise.
final class RemoteAgent implements BenchmarkAgent, AgentWarmUp, AgentModelIdentity {
  RemoteAgent._(this._peer, this.manifest, this.capabilities);

  final RpcPeer _peer;

  @override
  final AgentManifest manifest;

  /// Optional methods the agent serves.
  final Set<String> capabilities;

  static Future<RemoteAgent> connect(AibTransport transport) async {
    final peer = RpcPeer(transport);
    final capabilities = await Handshake.perform(peer, role: 'engine');
    final manifestJson = await peer.request(Methods.agentManifest);
    return RemoteAgent._(peer, AgentManifest.fromJson(asJsonMap(manifestJson['manifest'])), capabilities);
  }

  @override
  Future<void> startEpisode(TaskSpec task, EnvironmentDescriptor environment) async {
    await _peer.request(Methods.agentStartEpisode, {'task': task.toJson(), 'environment': environment.toJson()});
  }

  @override
  Future<Envelope> next(EnvelopeResult? lastResult, BudgetStatus budget) async {
    final response = await _peer.request(Methods.agentNext, {if (lastResult != null) 'lastResult': lastResult.toJson(), 'budget': budget.toJson()});
    return Envelope.fromJson(asJsonMap(response['envelope']));
  }

  @override
  Future<void> endEpisode(EpisodeOutcome outcome) async {
    await _peer.request(Methods.agentEndEpisode, {'outcome': outcome.toJson()});
  }

  @override
  Future<void> warmUp() async {
    if (capabilities.contains(Methods.agentWarmUp)) {
      await _peer.request(Methods.agentWarmUp);
    }
  }

  @override
  Future<JsonMap> modelIdentity() async {
    if (!capabilities.contains(Methods.agentModelIdentity)) {
      return {'model': manifest.metadata['model']};
    }
    return asJsonMap((await _peer.request(Methods.agentModelIdentity))['identity']);
  }

  Future<void> close() => _peer.close();
}

/// Serves a [BenchmarkAgent] over a transport. Optional capabilities the
/// agent implements are advertised in the handshake.
final class AgentProtocolServer {
  AgentProtocolServer(this.agent, AibTransport transport) : _peer = RpcPeer(transport) {
    _peer.onRequest = _dispatch;
  }

  final BenchmarkAgent agent;
  final RpcPeer _peer;

  List<String> get _capabilities => [if (agent is AgentWarmUp) Methods.agentWarmUp, if (agent is AgentModelIdentity) Methods.agentModelIdentity];

  Future<JsonMap> _dispatch(String method, JsonMap params) async {
    switch (method) {
      case Methods.handshake:
        return Handshake.answer(params, role: 'agent', capabilities: _capabilities);
      case Methods.agentManifest:
        return {'manifest': agent.manifest.toJson()};
      case Methods.agentStartEpisode:
        await agent.startEpisode(TaskSpec.fromJson(asJsonMap(params['task'])), EnvironmentDescriptor.fromJson(asJsonMap(params['environment'])));
        return const {};
      case Methods.agentNext:
        final envelope = await agent.next(
          params['lastResult'] == null ? null : EnvelopeResult.fromJson(asJsonMap(params['lastResult'])),
          BudgetStatus.fromJson(asJsonMap(params['budget'])),
        );
        return {'envelope': envelope.toJson()};
      case Methods.agentEndEpisode:
        await agent.endEpisode(EpisodeOutcome.fromJson(asJsonMap(params['outcome'])));
        return const {};
      case Methods.agentWarmUp when agent is AgentWarmUp:
        await (agent as AgentWarmUp).warmUp();
        return const {};
      case Methods.agentModelIdentity when agent is AgentModelIdentity:
        return {'identity': await (agent as AgentModelIdentity).modelIdentity()};
      default:
        throw ProtocolException(RpcErrorCodes.methodNotFound, 'Unknown method "$method"');
    }
  }

  Future<void> close() => _peer.close();
}
