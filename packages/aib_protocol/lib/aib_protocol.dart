/// AI Interaction Benchmark — Layer 2 wire protocol (spec §4.5).
///
/// Agent Protocol and Environment Protocol 2.0: JSON-RPC 2.0 messages over
/// pluggable transports, with the AIB version and optional capabilities
/// negotiated in `aib.handshake`. The conformance tests under
/// `test/conformance/` are the formal protocol specification for
/// third-party implementations.
library;

export 'src/agent_remote.dart';
export 'src/environment_remote.dart';
export 'src/message.dart';
export 'src/transport.dart';
