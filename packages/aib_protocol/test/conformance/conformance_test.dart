/// Protocol conformance tests (spec §4.5): the golden message catalog under
/// `golden/` is the formal protocol specification for third-party
/// implementations. Any adapter must (1) decode every golden message,
/// (2) tolerate unknown fields, (3) reject incompatible major versions and
/// (4) answer requests with the documented payload shapes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:aib_protocol/aib_protocol.dart';
import 'package:test/test.dart';

JsonMap loadCatalog() => asJsonMap(jsonDecode(File('test/conformance/golden/messages.json').readAsStringSync()));

void main() {
  final catalog = loadCatalog();
  final entries = (catalog['messages'] as List).map(asJsonMap).toList();

  group('golden messages decode and re-encode losslessly', () {
    for (final entry in entries) {
      test(entry['name'] as String, () {
        final original = asJsonMap(entry['message']);
        final decoded = ProtocolMessage.fromJson(original);
        expect(decoded.isRequest, isTrue);
        expect(decoded.id, original['id']);
        expect(decoded.method, original['method']);
        // Known members survive the round trip; unknown ones are dropped —
        // the documented forward-compatibility rule.
        final reEncoded = decoded.toJson();
        expect(reEncoded['jsonrpc'], '2.0');
        expect(reEncoded['id'], original['id']);
        expect(reEncoded.containsKey('x-future-member'), isFalse);
        expect(jsonEquals(reEncoded['params'], original['params']), isTrue);
      });
    }
  });

  test('an incompatible major version is refused in the handshake', () async {
    final pair = InMemoryTransportPair();
    final server = EnvironmentProtocolServer(MockEnvironment(), pair.a);
    final futureResponse = pair.b.incoming.first;
    pair.b.send(ProtocolMessage.request(1, Methods.handshake, {'protocolVersion': '9.0', 'role': 'engine'}));
    final response = await futureResponse;
    expect(response.error?.code, RpcErrorCodes.versionMismatch);
    await server.close();
  });

  test('a protocol 1 message is answered as an invalid request', () async {
    final pair = InMemoryTransportPair();
    final server = EnvironmentProtocolServer(MockEnvironment(), pair.a);
    final futureResponse = pair.b.incoming.first;
    pair.b.sendRaw('{"aib":"1.0","id":"msg-1","kind":"request","method":"env.describe"}');
    final response = await futureResponse;
    expect(response.error?.code, RpcErrorCodes.invalidRequest);
    expect(response.id, 'msg-1');
    await server.close();
  });

  test('a line that is not JSON is answered, and the peer keeps serving', () async {
    final pair = InMemoryTransportPair();
    final server = EnvironmentProtocolServer(MockEnvironment(), pair.a);
    final responses = <ProtocolMessage>[];
    final subscription = pair.b.incoming.listen(responses.add);
    pair.b.sendRaw('debug output from a print()');
    pair.b.send(ProtocolMessage.request(7, Methods.envDescribe));
    await _until(() => responses.length == 2);
    expect(responses.first.error?.code, RpcErrorCodes.parseError);
    expect(responses.first.id, isNull);
    expect(responses.last.result, contains('descriptor'));
    await subscription.cancel();
    await server.close();
  });

  test('unknown method is answered with method not found', () async {
    final pair = InMemoryTransportPair();
    final server = EnvironmentProtocolServer(MockEnvironment(), pair.a);
    final futureResponse = pair.b.incoming.first;
    pair.b.send(ProtocolMessage.request(2, 'env.doesNotExist'));
    final response = await futureResponse;
    expect(response.error?.code, RpcErrorCodes.methodNotFound);
    await server.close();
  });

  test('a closed connection fails pending requests at once', () async {
    final pair = InMemoryTransportPair();
    final peer = RpcPeer(pair.b);
    final pending = peer.request(Methods.envDescribe);
    await pair.a.close();
    await expectLater(pending, throwsA(isA<ProtocolException>().having((e) => e.code, 'code', RpcErrorCodes.connectionClosed)));
  });

  group('reference environment server answers golden requests', () {
    test('all env.* goldens yield the documented payload keys', () async {
      final pair = InMemoryTransportPair();
      final server = EnvironmentProtocolServer(MockEnvironment(), pair.a);

      final responses = <Object, ProtocolMessage>{};
      final subscription = pair.b.incoming.listen((m) => responses[m.id!] = m);

      for (final entry in entries) {
        final message = asJsonMap(entry['message']);
        final method = message['method'] as String?;
        if (method == null || !(method.startsWith('env.') || method == Methods.handshake)) {
          continue;
        }
        pair.b.send(ProtocolMessage.fromJson(message));
        final id = message['id'] as Object;
        await _until(() => responses.containsKey(id));
        final response = responses[id]!;
        expect(response.isResponse, isTrue, reason: '${entry['name']} must be answered with a response');
        expect(response.error, isNull, reason: '${entry['name']} must not error: ${response.error?.message}');
        for (final key in entry['resultKeys'] as List) {
          expect(response.result, contains(key), reason: '${entry['name']} result must carry "$key"');
        }
      }
      await subscription.cancel();
      await server.close();
    });
  });

  group('reference agent server answers golden requests', () {
    test('all agent.* goldens yield the documented payload keys', () async {
      final pair = InMemoryTransportPair();
      final agent = ScriptedAgent(
        defaultScript: const [Envelope(key: 'state.list', kind: .observe)],
      );
      final server = AgentProtocolServer(agent, pair.a);

      final responses = <Object, ProtocolMessage>{};
      final subscription = pair.b.incoming.listen((m) => responses[m.id!] = m);

      // agent.next before startEpisode is undefined — replay in catalog
      // order, which starts the episode first.
      for (final entry in entries) {
        final message = asJsonMap(entry['message']);
        final method = message['method'] as String?;
        if (method == null || !method.startsWith('agent.')) continue;
        pair.b.send(ProtocolMessage.fromJson(message));
        final id = message['id'] as Object;
        await _until(() => responses.containsKey(id));
        final response = responses[id]!;
        expect(response.error, isNull, reason: '${entry['name']}: ${response.error?.message}');
        for (final key in entry['resultKeys'] as List) {
          expect(response.result, contains(key), reason: '${entry['name']} result must carry "$key"');
        }
      }
      await subscription.cancel();
      await server.close();
    });
  });

  group('end-to-end over the wire (agent AND environment remote)', () {
    test('remote episode produces the same verdict and metrics as in-process', () async {
      const fixture = {
        'db': {'todos': <Object?>[]},
      };
      final task = TaskSpec(
        id: 'wire.create',
        title: 'Create over the wire',
        instruction: 'Insert "Milch kaufen".',
        budget: const Budget(maxSteps: 10, maxWallClockSeconds: 30),
        fixture: const FixtureRef(id: 'fx', data: fixture),
        groundTruth: const GroundTruth(finalState: [FinalStateExpectation(query: "db.todos.where(title == 'Milch kaufen')", expectCount: 1)]),
        successCriteria: const [SuccessCriterion(type: CriterionTypes.finalStateMatch)],
        optimalSteps: 1,
      );
      List<Envelope> script() => const [
        Envelope(key: 'state.list', kind: .observe, payload: {'path': 'db.todos'}),
        Envelope(
          key: 'state.insert',
          kind: .act,
          payload: {
            'path': 'db.todos',
            'item': {'title': 'Milch kaufen'},
          },
        ),
      ];
      EpisodeMeta meta(String id) => EpisodeMeta(
        runId: 'wire-run',
        episodeId: id,
        taskId: task.id,
        agentId: 'scripted',
        environmentId: 'mock',
        repetition: 1,
        startedAt: DateTime.utc(2026, 7, 2),
      );

      // In-process reference run.
      final localRecord = await RunEvaluation().evaluateEpisode(
        (await BenchmarkEngine().runEpisode(
          task: task,
          agent: ScriptedAgent(defaultScript: script()),
          environment: MockEnvironment(),
          meta: meta('local'),
        )).trace,
        task,
      );

      // Remote run: both ports behind the wire protocol.
      final agentPair = InMemoryTransportPair();
      final envPair = InMemoryTransportPair();
      final agentServer = AgentProtocolServer(ScriptedAgent(defaultScript: script()), agentPair.a);
      final envServer = EnvironmentProtocolServer(MockEnvironment(), envPair.a);
      final remoteAgent = await RemoteAgent.connect(agentPair.b);
      final remoteEnv = await RemoteEnvironment.connect(envPair.b);

      final remoteRecord = await RunEvaluation().evaluateEpisode(
        (await BenchmarkEngine().runEpisode(task: task, agent: remoteAgent, environment: remoteEnv, meta: meta('remote'))).trace,
        task,
      );

      expect(remoteRecord.verdict.type, VerdictType.success);
      expect(remoteRecord.verdict.type, localRecord.verdict.type);
      for (final metric in ['action_count', 'observation_count', 'unsupported_envelope_count', 'path_efficiency', 'weighted_score']) {
        expect(remoteRecord.metrics[metric], localRecord.metrics[metric], reason: 'metric $metric must be transport-independent');
      }
      // Protocol 2 negotiates the fingerprint capability, so the state-diff
      // metrics survive the wire (protocol 1 reported them as null).
      expect(remoteEnv, isA<StateFingerprintProvider>());
      expect(remoteRecord.metrics['kind_integrity_violations'], 0);
      expect(remoteRecord.metrics['redundant_action_ratio'], localRecord.metrics['redundant_action_ratio']);

      await remoteAgent.close();
      await remoteEnv.close();
      await agentServer.close();
      await envServer.close();
    });
  });
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
