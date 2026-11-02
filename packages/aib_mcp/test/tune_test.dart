import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aib_cli/aib_cli.dart';
import 'package:aib_mcp/aib_mcp.dart';
import 'package:dart_mcp/client.dart';
import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

/// Step 5: splits, the study journal, threshold replay, sweeps and the gated
/// holdout — over MCP, against the checkout's suites and recorded runs.
void main() {
  final repoRoot = Directory.current.path.endsWith('aib_mcp') ? p.normalize(p.join(Directory.current.path, '..', '..')) : Directory.current.path;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final study = 'mcp-test-$stamp';
  final experiments = Directory(p.join(repoRoot, 'suites', 'agents', 'experiments'));
  final scripted = File(p.join(experiments.path, 'mcp_test_scripted_$stamp.yaml'));
  // A splits directory of this test's own: other test files run mock_v1 at
  // the same time and must not see its holdout.
  final splits = 'results/aib_mcp_test_${stamp}_splits';
  final mockSplit = File(p.join(repoRoot, splits, 'mock_v1.yaml'));
  late Directory mockRun;

  late _Harness asked;
  late _Harness plain;

  /// Why a test cannot run without [runs], or null when they are there. They
  /// are recorded runs under the git-ignored `results/`, so CI has none.
  String? needsRuns(List<String> runs) => runs.every((run) => Directory(p.join(repoRoot, 'results', run)).existsSync())
      ? null
      : 'needs the recorded runs ${runs.join(', ')} under results/';

  setUpAll(() async {
    Directory.current = repoRoot;
    experiments.createSync(recursive: true);
    Directory(p.join(repoRoot, splits)).createSync(recursive: true);
    File(p.join(repoRoot, 'suites', 'splits', 'todo_v2.yaml')).copySync(p.join(repoRoot, splits, 'todo_v2.yaml'));
    File(p.join(repoRoot, 'suites', 'scripts', 'mock_scripted.yaml')).copySync(scripted.path);
    mockRun = Directory(p.join(repoRoot, 'results', 'aib_mcp_test_${stamp}_source'));
    await const AibService().run(suite: 'suites/mock_v1.yaml', agents: ['scripted=${scripted.path}'], outDir: mockRun.path, reps: 1);
    final runners = {
      'mock': const RunnerRecipe(name: 'mock', kind: .inProcess),
      // Stands in for an app runner: "runs" the mock suite by copying a run.
      'copy': RunnerRecipe(name: 'copy', suite: 'mock_v1', command: ['sh', '-c', 'cp -R "${mockRun.path}/." "{outDir}"']),
    };
    asked = await _Harness.start(repoRoot, runners, splits, elicitation: true);
    plain = await _Harness.start(repoRoot, runners, splits, elicitation: false);
  });

  tearDownAll(() async {
    await asked.stop();
    await plain.stop();
    for (final file in [scripted, mockSplit]) {
      if (file.existsSync()) file.deleteSync();
    }
    for (final entity in [
      ...experiments.listSync().where((e) => p.basename(e.path).startsWith(study)),
      ...Directory(
        p.join(repoRoot, 'results'),
      ).listSync().where((e) => p.basename(e.path).contains(study) || p.basename(e.path).contains('aib_mcp_test_$stamp')),
      Directory(p.join(repoRoot, 'experiments', study)),
    ]) {
      if (entity.existsSync()) entity.deleteSync(recursive: true);
    }
    if (experiments.existsSync() && experiments.listSync().isEmpty) experiments.deleteSync();
    final exp = Directory(p.join(repoRoot, 'experiments'));
    if (exp.existsSync() && exp.listSync().isEmpty) exp.deleteSync();
  });

  group('splits', () {
    test('a suite description leaves the holdout out', () async {
      final suite = await asked.ok('aib_describe_suite', {'suite': 'todo_v2'});
      final holdout = SuiteSplit.load(repoRoot, 'todo_v2')!.holdout;
      expect(suite['split'], {'tune': 16 - holdout.length, 'holdout': holdout.length});
      expect((suite['tasks'] as List).map((t) => (t as Map)['id']), everyElement(isNot(isIn(holdout))));
    });

    test('a held-out task cannot be run, and its trace cannot be read', () async {
      final held = SuiteSplit.load(repoRoot, 'todo_v2')!.holdout.first;
      expect(
        await asked.refused('aib_run_estimate', {
          'runner': 'mock',
          'config': 'todo_v2_prepared_lexical',
          'agent': 'prepared',
          'suite': 'todo_v2',
          'tasks': [held],
        }),
        contains('held out'),
      );
      await expectLater(asked.read('aib://runs/results/route-v2-n3-jev3/episodes/${held}__prepared__rep1/trace'), throwsA(anything));
    });

    test('scoring a run shows only the tuning split', () async {
      final holdout = SuiteSplit.load(repoRoot, 'todo_v2')!.holdout;
      final summary = await asked.ok('aib_evaluate', {'run': 'results/route-v2-n3-jev3'});
      final tasks = {for (final v in summary['verdicts'] as List) (v as Map)['taskId']};
      expect(tasks, hasLength(15 - holdout.length));
      expect(tasks.intersection(holdout), isEmpty);
      await expectLater(asked.read('aib://runs/results/route-v2-n3-jev3/verdicts'), throwsA(anything));
    }, skip: needsRuns(['route-v2-n3-jev3']));
  });

  group('replay', () {
    test('a route replay at the recorded threshold reproduces the recorded routes', () async {
      final replay = await asked.ok('aib_replay_thresholds', {
        'run': 'results/route-v2-n3-jev3',
        'decision': 'route',
        'thresholds': [0.5, 0.05, 0.95],
        'local': 'results/route-v2-n3-local',
        'cloud': 'results/route-v2-n3-cloud',
      });
      expect(replay['recordedThreshold'], 0.5);
      final replays = replay['replays'] as List;
      expect((replays[0] as Map)['changedEpisodes'], 0);
      expect((replays[0] as Map)['routes'], (replay['recorded'] as Map)['routes']);
      // The lowest threshold routes everything local, the highest everything cloud.
      expect((replays[1] as Map)['localShare'], greaterThanOrEqualTo((replays[0] as Map)['localShare'] as num));
      expect((replays[2] as Map)['localShare'], lessThanOrEqualTo((replays[0] as Map)['localShare'] as num));
      expect(replay['notReplayable'], 0);
    }, skip: needsRuns(['route-v2-n3-jev3']));

    test('a completion replay counts the episodes it cannot follow', () async {
      final replay = await asked.ok('aib_replay_thresholds', {
        'run': 'results/smoke-todo_v2_checked',
        'decision': 'completion',
        'thresholds': [0.5, 0.999],
      });
      expect(replay['exact'], isFalse);
      final [recorded, strict] = [for (final r in replay['replays'] as List) r as Map];
      expect(recorded['notFollowable'], 0);
      expect(strict['notFollowable'], greaterThan(0));
      expect(strict['firstChange'], contains('accept -> reject'));
    }, skip: needsRuns(['smoke-todo_v2_checked']));

    test('a selection replay refuses a run without per-candidate nouls', () async {
      expect(
        await asked.refused('aib_replay_thresholds', {
          'run': 'results/smoke-todo_v2_prepared_jev',
          'decision': 'select-tools',
          'thresholds': [0.3],
        }),
        contains('without per-candidate nouls'),
      );
    }, skip: needsRuns(['smoke-todo_v2_prepared_jev']));
  });

  group('study', () {
    test('tuning tools need an open study; a new one needs a hypothesis', () async {
      expect(
        await plain.refused('aib_sweep_start', {
          'base': 'x',
          'agent': 'scripted',
          'path': 'a',
          'values': [1, 2],
          'runner': 'mock',
        }),
        contains('open a study'),
      );
      expect(await asked.refused('aib_study', {'name': study}), contains('hypothesis'));
    });

    test('a sweep derives the arms, runs them, and compares with the tries counted', () async {
      await asked.ok('aib_study', {'name': study, 'hypothesis': 'Renaming the scripted agent changes nothing it scores.'});
      final base = 'experiments/${p.basenameWithoutExtension(scripted.path)}';
      final sweep = await asked.ok('aib_sweep_start', {
        'base': base,
        'agent': 'scripted',
        'path': 'agentId',
        'values': ['scripted-mock', 'scripted-renamed'],
        'runner': 'mock',
        'suite': 'mock_v1',
        'reps': 1,
      });
      expect(sweep['arms'], [base, startsWith('experiments/$study-agentid-')]);
      final done = await asked.ok('aib_job_wait', {'job': sweep['job'], 'seconds': 120});
      expect(done['state'], 'succeeded', reason: '${done['error']}');
      final result = done['result'] as Map;
      expect(result['study'], allOf(containsPair('armsDerived', 1), containsPair('runsStarted', 2)));
      final journal = File(p.join(repoRoot, 'experiments', study, 'journal.jsonl')).readAsLinesSync().map((l) => (jsonDecode(l) as Map)['type']);
      expect(journal, containsAllInOrder(['study', 'derive', 'run', 'run', 'compare']));
    });
  });

  group('holdout', () {
    setUpAll(() {
      mockSplit
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('suite: mock_v1\nholdout: [mock.delete.guarded]\n');
    });

    test('a client that cannot ask a person is refused', () async {
      await plain.ok('aib_study', {'name': study});
      expect(await plain.refused('aib_holdout_score', {'config': 'x', 'agent': 'scripted', 'runner': 'copy'}), contains('approval'));
    });

    test('a declined approval is refused and journals nothing', () async {
      await asked.ok('aib_study', {'name': study});
      asked.client.answer = false;
      final config = 'experiments/${p.basenameWithoutExtension(scripted.path)}';
      expect(await asked.refused('aib_holdout_score', {'config': config, 'agent': 'scripted', 'runner': 'copy'}), startsWith('not approved'));
      expect(File(p.join(repoRoot, 'experiments', study, 'journal.jsonl')).readAsStringSync(), isNot(contains('"holdout"')));
    });

    test('an approved call runs the holdout and returns only the suite-level score', () async {
      asked.client.answer = true;
      final config = 'experiments/${p.basenameWithoutExtension(scripted.path)}';
      final started = await asked.ok('aib_holdout_score', {'config': config, 'agent': 'scripted', 'runner': 'copy'});
      expect(asked.client.asked.last, contains('holdout of mock_v1 (1 tasks)'));
      final done = await asked.ok('aib_job_wait', {'job': started['job'], 'seconds': 60});
      expect(done['state'], 'succeeded', reason: '${done['error']}');
      final score = (done['result'] as Map)['holdout'] as List;
      expect(score, isNotEmpty);
      expect(score.map((r) => (r as Map)['taskId']), everyElement('*'));
      expect(jsonEncode(done), isNot(contains('mock.delete.guarded')));
      expect(await asked.refused('aib_job_log', {'job': started['job']}), contains('not shown'));
      final types = File(p.join(repoRoot, 'experiments', study, 'journal.jsonl')).readAsLinesSync().map((l) => (jsonDecode(l) as Map)['type']);
      expect(types, containsAllInOrder(['holdout', 'holdout-result']));
    });
  });
}

final class _Harness {
  _Harness._(this.server, this.client, this.mcp);

  final ServerConnection server;
  final _Client client;
  final AibMcpServer mcp;

  static Future<_Harness> start(String root, Map<String, RunnerRecipe> runners, String splits, {required bool elicitation}) async {
    final workspace = AibWorkspace(AibMcpConfig(root: root, runners: runners, splits: splits, judges: const {'todo_v2': 'ollama_judge'}));
    final toServer = StreamController<String>();
    final toClient = StreamController<String>();
    final mcp = AibMcpServer(
      StreamChannel<String>.withCloseGuarantee(toServer.stream, toClient.sink),
      workspace: workspace,
      runs: RunLauncher(
        workspace: workspace,
        jobs: JobManager(hostLimits: const {}),
      ),
    );
    final client = elicitation ? _AskingClient() : _Client();
    final server = client.connectServer(StreamChannel<String>.withCloseGuarantee(toClient.stream, toServer.sink));
    await server.initialize(
      InitializeRequest(protocolVersion: ProtocolVersion.latestSupported, capabilities: client.capabilities, clientInfo: client.implementation),
    );
    server.notifyInitialized(InitializedNotification());
    await mcp.initialized;
    return _Harness._(server, client, mcp);
  }

  Future<void> stop() async {
    await client.shutdown();
    await mcp.shutdown();
  }

  Future<CallToolResult> call(String tool, Map<String, Object?> args) => server.callTool(CallToolRequest(name: tool, arguments: args));

  Future<Map<String, Object?>> ok(String tool, Map<String, Object?> args) async {
    final result = await call(tool, args);
    expect(result.isError, isNot(isTrue), reason: result.content.map((c) => (c as TextContent).text).join());
    return result.structuredContent!;
  }

  Future<String> refused(String tool, Map<String, Object?> args) async {
    final result = await call(tool, args);
    expect(result.isError, isTrue, reason: '$tool was not refused');
    return (result.content.single as TextContent).text;
  }

  Future<String> read(String uri) async => ((await server.readResource(ReadResourceRequest(uri: uri))).contents.single as TextResourceContents).text;
}

base class _Client extends MCPClient {
  _Client() : super(Implementation(name: 'tune-test', version: '0'));

  bool answer = false;
  final asked = <String>[];
}

base class _AskingClient extends _Client with ElicitationFormSupport {
  @override
  FutureOr<ElicitResult> handleElicitation(ElicitRequest request, ServerConnection connection) {
    asked.add(request.message);
    return ElicitResult(action: .accept, content: {'approve': answer});
  }
}
