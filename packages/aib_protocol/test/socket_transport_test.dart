import 'dart:io';

import 'package:aib_core/aib_core.dart';
import 'package:aib_protocol/aib_protocol.dart';
import 'package:test/test.dart';

/// The engine connects out to an agent it may not spawn: a sandboxed macOS
/// test build has the network-client entitlement and no way to start a
/// process (ADR 0007's stdio path assumes it may).
void main() {
  test('a socket peer serves the same protocol as stdio', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      final peer = LineJsonTransport(input: socket.cast<List<int>>(), output: socket);
      peer.incoming.listen((message) {
        peer.send(
          ProtocolMessage.response(message.id, switch (message.method) {
            Methods.handshake => {'protocolVersion': aibProtocolVersion, 'accepted': true, 'role': 'agent', 'capabilities': <String>[]},
            Methods.agentManifest => {
              'manifest': {'agentId': 'socket-agent'},
            },
            _ => {
              'envelope': {'key': 'screen.capture', 'kind': 'observe', 'payload': <String, Object?>{}},
            },
          }),
        );
      });
    });
    addTearDown(server.close);

    final transport = await SocketTransport.connect(server.address.address, server.port);
    final agent = await RemoteAgent.connect(transport);
    expect(agent.manifest.agentId, 'socket-agent');

    final envelope = await agent.next(null, const BudgetStatus(stepsUsed: 0, maxSteps: 5, elapsedMs: 0, maxWallClockMs: 1000, tokensUsed: 0));
    expect(envelope.key, 'screen.capture');
    await transport.close();
  });
}
