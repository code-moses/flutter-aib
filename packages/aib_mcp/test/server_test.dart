import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aib_cli/aib_cli.dart';
import 'package:aib_mcp/aib_mcp.dart';
import 'package:dart_mcp/client.dart';
import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

/// The server driven by an in-process MCP client, over the real checkout.
///
/// Runs are written to `results/aib_mcp_test_*` and derived arms to
/// `suites/agents/experiments/`; both are removed afterwards.
void main() {
  final repoRoot = Directory.current.path.endsWith('aib_mcp') ? p.normalize(p.join(Directory.current.path, '..', '..')) : Directory.current.path;
  final goldens = p.join(repoRoot, 'packages', 'aib_mcp', 'test', 'goldens');

  late ServerConnection server;
  late MCPClient client;
  late AibMcpServer mcp;
  late Directory runs;
  final written = <File>[];

  setUpAll(() async {
    // Manifests record suite paths relative to where a run started; the
    // server resolves them from the checkout, as bin/server.dart sets up.
    Directory.current = repoRoot;
    runs = Directory(p.join(repoRoot, 'results', 'aib_mcp_test_${DateTime.now().microsecondsSinceEpoch}'))..createSync(recursive: true);
    const service = AibService();
    for (final (name, seed) in [('a', 1), ('b', 1), ('c', 2)]) {
      await service.run(
        suite: 'suites/mock_v1.yaml',
        agents: ['scripted=suites/scripts/mock_scripted.yaml'],
        outDir: p.join(runs.path, name),
        reps: 1,
        seed: seed,
      );
    }

    final toServer = StreamController<String>();
    final toClient = StreamController<String>();
    mcp = AibMcpServer(
      StreamChannel<String>.withCloseGuarantee(toServer.stream, toClient.sink),
      workspace: AibWorkspace(AibMcpConfig(root: repoRoot), clock: () => DateTime.utc(2026, 9, 23)),
      frameworkRevision: 'test',
    );
    client = MCPClient(Implementation(name: 'test', version: '0'));
    server = client.connectServer(StreamChannel<String>.withCloseGuarantee(toClient.stream, toServer.sink));
    await server.initialize(
      InitializeRequest(protocolVersion: ProtocolVersion.latestSupported, capabilities: client.capabilities, clientInfo: client.implementation),
    );
    server.notifyInitialized(InitializedNotification());
    await mcp.initialized;
  });

  tearDownAll(() async {
    await client.shutdown();
    await mcp.shutdown();
    runs.deleteSync(recursive: true);
    for (final file in written) {
      if (file.existsSync()) file.deleteSync();
    }
  });

  String run(String name) => p.relative(p.join(runs.path, name), from: repoRoot);

  Future<CallToolResult> call(String tool, [Map<String, Object?> args = const {}]) => server.callTool(CallToolRequest(name: tool, arguments: args));

  Future<Map<String, Object?>> ok(String tool, [Map<String, Object?> args = const {}]) async {
    final result = await call(tool, args);
    expect(result.isError, isNot(isTrue), reason: result.content.map((c) => (c as TextContent).text).join());
    return result.structuredContent!;
  }

  Future<String> refused(String tool, [Map<String, Object?> args = const {}]) async {
    final result = await call(tool, args);
    expect(result.isError, isTrue);
    return (result.content.single as TextContent).text;
  }

  test('the tool list and its schemas match the golden', () async {
    final tools = (await server.listTools(ListToolsRequest())).tools;
    // The whole definition, descriptions and annotations included: an
    // agent reads all of it.
    final actual = const JsonEncoder.withIndent('  ').convert(tools..sort((a, b) => a.name.compareTo(b.name)));
    final golden = File(p.join(goldens, 'tools.json'));
    if (Platform.environment['AIB_UPDATE_GOLDENS'] == '1' || !golden.existsSync()) {
      golden
        ..createSync(recursive: true)
        ..writeAsStringSync('$actual\n');
    }
    expect('$actual\n', golden.readAsStringSync(), reason: 'run with AIB_UPDATE_GOLDENS=1 to accept a change');
  });

  group('discover', () {
    test('lists suites, and describes one without ground truth', () async {
      final suites = (await ok('aib_list_suites'))['suites'] as List;
      expect(suites.map((s) => (s as Map)['suite']), containsAll(['mock_v1', 'todo_v2']));
      expect(suites.map((s) => (s as Map)['suite']), isNot(contains('pricing_2026_09')));
      final suite = await ok('aib_describe_suite', {'suite': 'mock_v1'});
      expect(suite['tasks'], isNotEmpty);
      expect(jsonEncode(suite), allOf(isNot(contains('groundTruth')), isNot(contains('"expected"')), isNot(contains('fixture'))));
    });

    test('lists and reads agent configs', () async {
      final configs = (await ok('aib_list_agent_configs', {'filter': 'routed_v2'}))['configs'] as List;
      expect(configs.map((c) => (c as Map)['name']), contains('routed_v2_jev3'));
      final config = await ok('aib_read_agent_config', {'name': 'routed_v2_jev3'});
      expect(config['yaml'], startsWith('#'));
      expect((config['blocks'] as Map).keys, contains('preparation'));
      expect(await refused('aib_read_agent_config', {'name': '../../pubspec'}), contains('not an agent config name'));
    });

    test('lists and describes runs', () async {
      final listed = (await ok('aib_list_runs', {'suite': 'mock_v1'}))['runs'] as List;
      expect(listed.map((r) => (r as Map)['run']), containsAll([run('a'), run('b'), run('c')]));
      final described = await ok('aib_describe_run', {'run': run('a')});
      expect(described['episodes'], containsPair('missing', isEmpty));
      expect(await refused('aib_describe_run', {'run': 'suites'}), contains('not a run directory'));
    });

    test('metrics catalog filters by provider', () async {
      final metrics =
          (await ok('aib_metrics_catalog', {
                'providers': ['routing'],
              }))['metrics']
              as List;
      expect(metrics.map((m) => (m as Map)['source']), everyElement(anyOf(startsWith('builtin'), startsWith('--metrics routing'))));
    });

    test('results carry the framework revision', () async {
      expect(await ok('aib_list_suites'), containsPair('aib', {'framework': 'test'}));
    });
  });

  group('score', () {
    test('evaluate writes verdicts inside the run and reports them', () async {
      final summary = await ok('aib_evaluate', {'run': run('a')});
      expect(summary['byVerdict'], {'success': isPositive});
      expect(summary['written'], [p.join(run('a'), 'verdicts.json'), p.join(run('a'), 'metrics.csv')]);
    });

    test('compare pairs two runs and refuses unintended differences', () async {
      final pair = await ok('aib_compare', {
        'runs': [run('a'), run('b')],
      });
      expect(pair['differences'], isEmpty);
      expect(pair['markdown'], contains('Run comparison'));
      expect(
        await refused('aib_compare', {
          'runs': [run('a'), run('c')],
        }),
        contains('"path":"seed"'),
      );
      expect(
        (await ok('aib_compare', {
          'runs': [run('a'), run('c')],
          'vary': ['seed'],
        }))['differences'],
        [containsPair('intended', true)],
      );
    });

    test('route, selftest and provenance', () async {
      final route = await ok('aib_route', {
        'local': run('a'),
        'cloud': run('b'),
        'routed': [run('c')],
      });
      expect(route['tasks'], isPositive);
      final selftest = await ok('aib_selftest', {'suite': 'mock_v1', 'reference': 'suites/scripts/mock_scripted.yaml'});
      expect(selftest['failures'], 0);
      final provenance = await ok('aib_provenance', {'run': run('a'), 'against': run('c')});
      expect((provenance['differences'] as List).map((d) => (d as Map)['path']), contains('seed'));
    });

    test('a run outside the checkout is refused', () async {
      expect(await refused('aib_evaluate', {'run': '/tmp'}), contains('outside the checkout'));
    });
  });

  group('configure', () {
    const base = 'todo_v2_prepared_lexical';
    File arm(String name) => File(p.join(repoRoot, 'suites', 'agents', 'experiments', '$name.yaml'));

    test('a derived arm with two changed paths is refused and nothing is written', () async {
      final name = 'mcp_test_two_${DateTime.now().microsecondsSinceEpoch}';
      written.add(arm(name));
      final message = await refused('aib_derive_agent_config', {
        'base': base,
        'agent': 'prepared',
        'name': name,
        'hypothesis': 'Two knobs at once.',
        'patch': {
          'preparation': {'topK': 8, 'minScore': 0.3},
        },
      });
      expect(message, contains('changes 2 paths'));
      expect(arm(name).existsSync(), isFalse);
    });

    test('a derived arm with one change is written and validates', () async {
      final name = 'mcp_test_one_${DateTime.now().microsecondsSinceEpoch}';
      written.add(arm(name));
      final derived = await ok('aib_derive_agent_config', {
        'base': base,
        'agent': 'prepared',
        'name': name,
        'hypothesis': 'A larger topK recovers the tools the lexical preparer misses on multi-step tasks; prefetch_recall should rise.',
        'patch': {
          'preparation': {'topK': 8},
        },
      });
      expect(derived['changes'], [
        {'path': 'preparation.topK', 'before': 5, 'after': 8},
      ]);
      expect(arm(name).readAsStringSync(), startsWith('# Derived from $base.yaml by aib_mcp on 2026-09-23'));

      final check = await ok('aib_validate_agent_config', {'agent': 'prepared', 'name': 'experiments/$name'});
      expect(check['built'], isTrue);
      expect(check['agentConfigHash'], (derived['check'] as Map)['agentConfigHash']);

      final diff = await ok('aib_diff_agent_configs', {'a': base, 'b': 'experiments/$name', 'agent': 'prepared'});
      expect((diff['changes'] as List).single, containsPair('path', 'preparation.topK'));
      expect(diff['vary'], contains(endsWith('configBlocks.preparation.config.topK')));

      expect(
        await refused('aib_derive_agent_config', {
          'base': base,
          'agent': 'prepared',
          'name': name,
          'hypothesis': 'again',
          'patch': {
            'preparation': {'topK': 9},
          },
        }),
        contains('exists already'),
      );
    });

    test('a patch that changes nothing, or does not build, is refused', () async {
      Future<String> derive(Map<String, Object?> patch) =>
          refused('aib_derive_agent_config', {'base': base, 'agent': 'prepared', 'name': 'mcp_test_never', 'hypothesis': 'none', 'patch': patch});
      expect(
        await derive({
          'preparation': {'topK': 5},
        }),
        contains('changes nothing'),
      );
      expect(await derive({'llm': null}), contains('does not build'));
      expect(arm('mcp_test_never').existsSync(), isFalse);
    });

    test('inline yaml validates; a broken config reports its error', () async {
      final ok_ = await ok('aib_validate_agent_config', {'agent': 'hybrid', 'yaml': 'llm: {provider: ollama, model: qwen3:8b}\n'});
      expect(ok_['built'], isTrue);
      final broken = await ok('aib_validate_agent_config', {'agent': 'hybrid', 'yaml': 'llm: {provider: nope, model: x}\n'});
      expect(broken['built'], isFalse);
      expect(broken['error'], isNotEmpty);
    });
  });

  group('resources', () {
    Future<String> read(String uri) async =>
        ((await server.readResource(ReadResourceRequest(uri: uri))).contents.single as TextResourceContents).text;

    test('templates are listed', () async {
      final templates = (await server.listResourceTemplates(ListResourceTemplatesRequest())).resourceTemplates;
      expect(templates.map((t) => t.uriTemplate), contains('aib://runs/{run}/episodes/{episode}/trace'));
    });

    test('suite, manifest and a paged trace', () async {
      expect(await read('aib://suites/mock_v1'), isNot(contains('groundTruth')));
      final manifest = jsonDecode(await read('aib://runs/${run('a')}/manifest')) as Map;
      expect(manifest['suite'], containsPair('name', 'mock_v1'));
      final encoded = await read('aib://runs/${Uri.encodeComponent(run('a'))}/manifest');
      expect(jsonDecode(encoded), manifest);

      final episode = (manifest['taskOrder'] as List).first;
      final trace = await read('aib://runs/${run('a')}/episodes/${episode}__scripted-mock__rep1/trace');
      final lines = const LineSplitter().convert(trace);
      expect(jsonDecode(lines.last), {'_page': 1, '_pages': 1});
    });

    test('docs are served, nothing else', () async {
      expect(await read('aib://docs/overview.md'), contains('# AIB overview'));
      await expectLater(server.readResource(ReadResourceRequest(uri: 'aib://docs/../pubspec.yaml')), throwsA(anything));
    });
  });
}
