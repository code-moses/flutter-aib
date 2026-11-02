import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aib_cli/aib_cli.dart';
import 'package:aib_mcp/aib_mcp.dart';
import 'package:dart_mcp/client.dart';
import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

/// Step 6: the same tools over Streamable HTTP, and what the transport
/// itself refuses.
void main() {
  final repoRoot = Directory.current.path.endsWith('aib_mcp') ? p.normalize(p.join(Directory.current.path, '..', '..')) : Directory.current.path;
  const token = 'test-token-0123456789abcdef';
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final runs = Directory(p.join(repoRoot, 'results', 'aib_mcp_test_http_$stamp'));
  final experiments = Directory(p.join(repoRoot, 'suites', 'agents', 'experiments'));

  late McpHttpServer http;
  late Uri endpoint;
  late _Client client;
  late ServerConnection server;

  setUpAll(() async {
    Directory.current = repoRoot;
    for (final (name, seed) in [('a', 1), ('b', 1), ('c', 2)]) {
      await const AibService().run(
        suite: 'suites/mock_v1.yaml',
        agents: ['scripted=suites/scripts/mock_scripted.yaml'],
        outDir: p.join(runs.path, name),
        reps: 1,
        seed: seed,
      );
    }
    final workspace = AibWorkspace(
      AibMcpConfig(
        root: repoRoot,
        runners: {
          'noop': const RunnerRecipe(name: 'noop', suite: 'todo_v2', command: ['sh', '-c', 'sleep 1']),
        },
      ),
      clock: () => DateTime.utc(2026, 9, 23),
    );
    final launcher = RunLauncher(
      workspace: workspace,
      jobs: JobManager(hostLimits: const {}),
    );
    http = await McpHttpServer.serve(
      token: token,
      port: 0,
      connect: (channel) => AibMcpServer(channel, workspace: workspace, runs: launcher, frameworkRevision: 'test'),
    );
    endpoint = Uri.parse('http://127.0.0.1:${http.port}/mcp');
    client = _Client();
    server = client.connectServer(_httpChannel(endpoint, token));
    await server.initialize(
      InitializeRequest(protocolVersion: ProtocolVersion.latestSupported, capabilities: client.capabilities, clientInfo: client.implementation),
    );
    server.notifyInitialized(InitializedNotification());
  });

  tearDownAll(() async {
    await client.shutdown();
    await http.close();
    runs.deleteSync(recursive: true);
    for (final dir in Directory(p.join(repoRoot, 'results')).listSync().where((e) => p.basename(e.path).startsWith('aib_mcp_test_http_out_$stamp'))) {
      dir.deleteSync(recursive: true);
    }
    if (experiments.existsSync()) {
      for (final f in experiments.listSync().where((e) => p.basename(e.path).startsWith('mcp_http_$stamp'))) {
        f.deleteSync();
      }
      if (experiments.listSync().isEmpty) experiments.deleteSync();
    }
  });

  String run(String name) => p.relative(p.join(runs.path, name), from: repoRoot);

  Future<Map<String, Object?>> ok(String tool, Map<String, Object?> args, {MetaWithProgressToken? meta}) async {
    final result = await server.callTool(CallToolRequest(name: tool, arguments: args, meta: meta));
    expect(result.isError, isNot(isTrue), reason: result.content.map((c) => (c as TextContent).text).join());
    return result.structuredContent!;
  }

  group('the tools, over HTTP', () {
    test('the tool list is the one stdio serves', () async {
      final tools = (await server.listTools(ListToolsRequest())).tools..sort((a, b) => a.name.compareTo(b.name));
      final golden = File(p.join(repoRoot, 'packages', 'aib_mcp', 'test', 'goldens', 'tools.json')).readAsStringSync();
      expect('${const JsonEncoder.withIndent('  ').convert(tools)}\n', golden);
    });

    test('discover and score', () async {
      expect((await ok('aib_list_suites', {}))['suites'], isNotEmpty);
      expect((await ok('aib_describe_run', {'run': run('a')}))['episodes'], containsPair('missing', isEmpty));
      final pair = await ok('aib_compare', {
        'runs': [run('a'), run('c')],
        'vary': ['seed'],
      });
      expect(pair['differences'], [containsPair('path', 'seed')]);
      final refused = await server.callTool(
        CallToolRequest(
          name: 'aib_compare',
          arguments: {
            'runs': [run('a'), run('c')],
          },
        ),
      );
      expect(refused.isError, isTrue);
    });

    test('configure', () async {
      final derived = await ok('aib_derive_agent_config', {
        'base': 'todo_v2_prepared_lexical',
        'agent': 'prepared',
        'name': 'mcp_http_$stamp',
        'hypothesis': 'Over HTTP as over stdio.',
        'patch': {
          'preparation': {'topK': 6},
        },
      });
      expect((derived['check'] as Map)['built'], isTrue);
    });

    test('resources', () async {
      final read = await server.readResource(ReadResourceRequest(uri: 'aib://runs/${run('a')}/manifest'));
      expect(jsonDecode((read.contents.single as TextResourceContents).text), containsPair('suite', containsPair('name', 'mock_v1')));
    });

    test('an elicitation reaches the client in the middle of a call', () async {
      client.answer = true;
      final started = await ok('aib_run_start', {
        'runner': 'noop',
        'config': 'anthropic',
        'agent': 'hybrid',
        'maxUsd': 1,
        'out': 'aib_mcp_test_http_out_${stamp}_paid',
      });
      expect(client.asked, hasLength(1));
      final request = CallToolRequest(
        name: 'aib_job_wait',
        arguments: {'job': started['job'], 'seconds': 30},
        meta: MetaWithProgressToken(progressToken: ProgressToken('http-wait')),
      );
      final progress = <ProgressNotification>[];
      final sub = server.onProgress(request).listen(progress.add);
      final done = await server.callTool(request);
      await sub.cancel();
      expect(done.structuredContent!['state'], 'succeeded');
      expect(progress, isNotEmpty);
    });
  });

  group('the transport refuses', () {
    Future<HttpClientResponse> post(Map<String, Object?> body, {String? bearer = token, String? session, String? origin}) async {
      final request = await HttpClient().postUrl(endpoint);
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.acceptHeader, 'application/json, text/event-stream');
      if (bearer != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      if (session != null) request.headers.set('mcp-session-id', session);
      if (origin != null) request.headers.set('origin', origin);
      request.write(jsonEncode(body));
      return request.close();
    }

    const ping = {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'};

    test('a missing or wrong token', () async {
      expect((await post(ping, bearer: null)).statusCode, HttpStatus.unauthorized);
      expect((await post(ping, bearer: 'wrong-token-0123456789')).statusCode, HttpStatus.unauthorized);
    });

    test('a foreign browser origin', () async {
      expect((await post(ping, origin: 'https://evil.example')).statusCode, HttpStatus.forbidden);
    });

    test('a request without a session, or with an unknown one', () async {
      expect((await post(ping)).statusCode, HttpStatus.badRequest);
      expect((await post(ping, session: 'nope')).statusCode, HttpStatus.notFound);
    });

    test('a session after DELETE', () async {
      final init = await post({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-06-18',
          'capabilities': <String, Object?>{},
          'clientInfo': {'name': 'raw', 'version': '0'},
        },
      });
      final session = init.headers.value('mcp-session-id')!;
      await init.drain<void>();
      final delete = await HttpClient().deleteUrl(endpoint);
      delete.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
        ..set('mcp-session-id', session);
      expect((await delete.close()).statusCode, HttpStatus.noContent);
      expect((await post(ping, session: session)).statusCode, HttpStatus.notFound);
    });

    test('a short token at startup', () {
      expect(() => McpHttpServer.serve(token: 'short', connect: (_) {}), throwsArgumentError);
    });
  });
}

/// The client side of Streamable HTTP, for [MCPClient]: each message is a
/// POST; a request's answer (and what comes before it) arrives as events.
StreamChannel<String> _httpChannel(Uri endpoint, String token) {
  final incoming = StreamController<String>();
  final outgoing = StreamController<String>();
  final http = HttpClient();
  String? session;
  Future<void> post(String message) async {
    final request = await http.postUrl(endpoint);
    request.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.acceptHeader, 'application/json, text/event-stream')
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (session != null) request.headers.set('mcp-session-id', session!);
    request.write(message);
    final response = await request.close();
    session ??= response.headers.value('mcp-session-id');
    await for (final line in response.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.startsWith('data: ')) incoming.add(line.substring(6));
    }
  }

  outgoing.stream.listen(
    (message) async {
      try {
        await post(message);
      } on Object {
        // The session is going away; nothing waits for this message.
      }
    },
    onDone: () {
      http.close(force: true);
      incoming.close();
    },
  );
  return StreamChannel<String>.withCloseGuarantee(incoming.stream, outgoing.sink);
}

base class _Client extends MCPClient with ElicitationFormSupport {
  _Client() : super(Implementation(name: 'http-test', version: '0'));

  bool answer = false;
  final asked = <String>[];

  @override
  FutureOr<ElicitResult> handleElicitation(ElicitRequest request, ServerConnection connection) {
    asked.add(request.message);
    return ElicitResult(action: .accept, content: {'approve': answer});
  }
}
