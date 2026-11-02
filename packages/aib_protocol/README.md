# aib_protocol

The AI Interaction Benchmark wire protocol 2.0, for agents and environments
that run in another process or language. Messages are JSON-RPC 2.0. The AIB
version and optional capabilities are negotiated in `aib.handshake`.

- **Transports** (`AibTransport`): `SubprocessTransport` (a child process
  over stdio), `SocketTransport` (TCP), `LineJsonTransport` (any line
  stream) and `InMemoryTransportPair` (tests).
- **Adapters**: `RemoteAgent` and `RemoteEnvironment` implement the
  `aib_core` ports over a transport, so the engine cannot tell a remote
  agent or environment from a local one.

The conformance tests in
[`test/conformance/`](https://github.com/code-moses/flutter-aib/tree/main/packages/aib_protocol/test/conformance)
are the formal protocol specification for third-party implementations. A
worked example is the Python vision agent in
[`agents/vision_python`](https://github.com/code-moses/flutter-aib/tree/main/agents/vision_python).
