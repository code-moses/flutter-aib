import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aib_cli/aib_cli.dart';
import 'package:aib_core/aib_core.dart';
import 'package:aib_mcp/aib_mcp.dart';
import 'package:dart_mcp/client.dart';
import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

/// Jobs, runner recipes, the host queue and the budget, with fake runners
/// (`sh -c …`) and the in-process mock runner — nothing here needs a model.
void main() {
  final repoRoot = Directory.current.path.endsWith('aib_mcp') ? p.normalize(p.join(Directory.current.path, '..', '..')) : Directory.current.path;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final experiments = Directory(p.join(repoRoot, 'suites', 'agents', 'experiments'));
  final scripted = File(p.join(experiments.path, 'mcp_test_scripted_$stamp.yaml'));
  final cleanupDirs = <Directory>[];
  late Directory scratch;

  setUpAll(() {
    Directory.current = repoRoot;
    experiments.createSync(recursive: true);
    // The mock runner runs agent configs from suites/agents; the scripted
    // reference episodes live under suites/scripts.
    File(p.join(repoRoot, 'suites', 'scripts', 'mock_scripted.yaml')).copySync(scripted.path);
    scratch = Directory.systemTemp.createTempSync('aib_jobs_');
  });

  tearDownAll(() {
    scripted.deleteSync();
    if (experiments.listSync().isEmpty) experiments.deleteSync();
    for (final dir in cleanupDirs) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
    scratch.deleteSync(recursive: true);
  });

  RunnerRecipe sh(String name, String script, {List<String>? prepare, List<String>? cleanup, String? output, bool stage = false}) => RunnerRecipe(
    name: name,
    suite: 'todo_v2',
    command: ['sh', '-c', script],
    prepare: prepare,
    cleanup: cleanup,
    output: output,
    stageSuites: stage,
  );

  RunLauncher launcher({Map<String, RunnerRecipe> runners = const {}, BudgetConfig budget = const BudgetConfig(), File? history, String? root}) {
    final workspace = AibWorkspace(
      AibMcpConfig(
        root: root ?? repoRoot,
        runners: {
          'mock': const RunnerRecipe(name: 'mock', kind: .inProcess),
          ...runners,
        },
        hosts: {'ollama': const HostLimit(name: 'ollama', url: 'http://localhost:11434')},
        budget: budget,
      ),
    );
    return RunLauncher(
      workspace: workspace,
      jobs: JobManager(hostLimits: {'ollama': 1}, historyFile: history),
    );
  }

  String out(String name) {
    final dir = Directory(p.join(repoRoot, 'results', 'aib_mcp_test_${stamp}_$name'));
    cleanupDirs.add(dir);
    return p.basename(dir.path);
  }

  Future<void> until(bool Function() condition, {Duration timeout = const Duration(seconds: 30)}) async {
    final end = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(end)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  const ollamaArm = 'todo_v2_prepared_lexical';

  test('a second run on the same Ollama queues behind the first', () async {
    final runs = launcher(runners: {'slow': sh('slow', 'sleep 30')});
    final first = await runs.startRun(runner: 'slow', configName: ollamaArm, agent: 'prepared', out: out('q1'));
    final second = await runs.startRun(runner: 'slow', configName: ollamaArm, agent: 'prepared', out: out('q2'));
    expect(first.hosts, {'ollama'});
    await until(() => first.state == .running);
    expect(second.state, JobState.queued);
    runs.jobs.cancel(first.id);
    await until(() => second.state == .running);
    expect(first.state, JobState.cancelled);
    runs.jobs.cancel(second.id);
    await runs.jobs.wait(second, const Duration(seconds: 30));
  });

  test('cancel stops the process tree; cleanup runs anyway', () async {
    final marker = p.join(scratch.path, 'cleaned');
    final child = p.join(scratch.path, 'child.pid');
    final runs = launcher(
      runners: {
        'app': sh('app', 'sleep 60 & echo \$! > $child; wait', prepare: ['sh', '-c', 'echo prepared'], cleanup: ['sh', '-c', 'touch $marker']),
      },
    );
    final job = await runs.startRun(runner: 'app', configName: ollamaArm, agent: 'prepared', out: out('cancel'));
    await until(() => File(child).existsSync() && File(child).readAsStringSync().trim().isNotEmpty);
    runs.jobs.cancel(job.id);
    await runs.jobs.wait(job, const Duration(seconds: 40));
    expect(job.state, JobState.cancelled);
    expect(File(marker).existsSync(), isTrue, reason: job.tail(30).join('\n'));
    final pid = File(child).readAsStringSync().trim();
    expect((await Process.run('kill', ['-0', pid])).exitCode, isNot(0), reason: 'the grandchild sleep survived');
    expect(job.tail(50), contains('prepared'));
  });

  test('staged suites put a derived arm at the top of agents/; output is collected', () async {
    final arm = File(p.join(experiments.path, 'mcp_test_arm_$stamp.yaml'))
      ..writeAsStringSync(File(p.join(repoRoot, 'suites', 'agents', '$ollamaArm.yaml')).readAsStringSync());
    addTearDown(arm.deleteSync);
    final written = p.join(scratch.path, 'sandbox');
    final runs = launcher(
      runners: {
        'sandboxed': sh(
          'sandboxed',
          'test -f "{suitesDir}/agents/{agentConfigFile}.yaml" && mkdir -p "$written/{out}" && echo ok > "$written/{out}/marker"',
          output: '$written/{out}',
          stage: true,
        ),
      },
    );
    final name = out('collect');
    final job = await runs.startRun(
      runner: 'sandboxed',
      configName: 'experiments/${p.basenameWithoutExtension(arm.path)}',
      agent: 'prepared',
      out: name,
    );
    await runs.jobs.wait(job, const Duration(seconds: 30));
    expect(job.state, JobState.succeeded, reason: job.tail(30).join('\n'));
    expect(File(p.join(repoRoot, 'results', name, 'marker')).readAsStringSync().trim(), 'ok');
    expect(Directory(p.join(repoRoot, 'results', '.aib_mcp', 'stage', job.id)).existsSync(), isFalse);
    final launch = jsonDecode(File(p.join(repoRoot, 'results', name, RunLauncher.launchFile)).readAsStringSync()) as List;
    expect(launch.single, containsPair('launchedBy', 'mcp'));
  });

  test('the mock runner runs in-process, reports progress, and resumes', () async {
    final history = File(p.join(scratch.path, 'jobs.jsonl'));
    final runs = launcher(history: history);
    final name = out('mock');
    final config = 'experiments/${p.basenameWithoutExtension(scripted.path)}';
    final job = await runs.startRun(runner: 'mock', configName: config, agent: 'scripted', suite: 'mock_v1', reps: 1, out: name);
    expect(job.hosts, isEmpty);
    await runs.jobs.wait(job, const Duration(seconds: 60));
    expect(job.state, JobState.succeeded, reason: '${job.error}\n${job.tail(30).join('\n')}');
    expect(job.done, job.total);
    expect(job.result, containsPair('executed', job.total));

    final again = await runs.startRun(runner: 'mock', configName: config, agent: 'scripted', suite: 'mock_v1', reps: 1, out: name);
    await runs.jobs.wait(again, const Duration(seconds: 60));
    expect(again.result, allOf(containsPair('executed', 0), containsPair('reused', job.total)));
    expect(history.readAsLinesSync(), hasLength(2));
    expect(runs.jobs.spentToday(), 0);
  });

  test('a run of a suite with instruction variants counts them, and describe plans them', () async {
    final name = 'mock_variants_$stamp';
    final suite = File(p.join(repoRoot, 'suites', '$name.yaml'))
      ..writeAsStringSync(
        File(p.join(repoRoot, 'suites', 'mock_v1.yaml'))
            .readAsStringSync()
            .replaceFirst('suite: mock_v1', 'suite: $name')
            .replaceFirst(
              '    optimalSteps: 1\n',
              '    optimalSteps: 1\n    variants:\n      - id: casual\n        instruction: Add "Milch kaufen" for 2026-07-10.\n',
            ),
      );
    addTearDown(suite.deleteSync);
    final runs = launcher();
    final config = 'experiments/${p.basenameWithoutExtension(scripted.path)}';
    final job = await runs.startRun(runner: 'mock', configName: config, agent: 'scripted', suite: name, out: out('variants'));
    // Four tasks and one variant, at the suite's three repetitions.
    expect(job.total, 15);
    await runs.jobs.wait(job, const Duration(seconds: 60));
    expect(job.state, JobState.succeeded, reason: '${job.error}\n${job.tail(30).join('\n')}');
    expect(job.done, job.total);
    final described = runs.workspace.describeRun(p.join('results', p.basename(job.runDir!)));
    expect(described['episodes'], allOf(containsPair('planned', 15), containsPair('done', 15), containsPair('missing', isEmpty)));
  });

  group('budget', () {
    final runners = {'noop': sh('noop', 'true')};
    const paid = 'anthropic';

    test('a priced arm needs maxUsd within the per-job budget', () async {
      final runs = launcher(runners: runners);
      await expectLater(
        runs.startRun(runner: 'noop', configName: paid, agent: 'hybrid'),
        throwsA(isA<AibError>().having((e) => e.message, 'message', contains('pass maxUsd'))),
      );
      await expectLater(
        runs.startRun(runner: 'noop', configName: paid, agent: 'hybrid', maxUsd: 50),
        throwsA(isA<AibError>().having((e) => e.message, 'message', contains('per-job budget'))),
      );
    });

    test('above the auto-approve limit, a person has to say yes', () async {
      final runs = launcher(runners: runners);
      final asked = <String>[];
      await expectLater(
        runs.startRun(
          runner: 'noop',
          configName: paid,
          agent: 'hybrid',
          maxUsd: 1,
          approve: (m) async {
            asked.add(m);
            return false;
          },
        ),
        throwsA(isA<AibError>().having((e) => e.message, 'message', startsWith('not approved'))),
      );
      expect(asked.single, contains('anthropic:claude-sonnet-4-6'));
      final job = await runs.startRun(runner: 'noop', configName: paid, agent: 'hybrid', maxUsd: 1, out: out('paid'), approve: (_) async => true);
      expect(job.maxUsd, 1);
      await runs.jobs.wait(job, const Duration(seconds: 30));
    });

    test('the daily budget counts what jobs spent today', () async {
      final history = File(p.join(scratch.path, 'spent.jsonl'))
        ..writeAsStringSync('${jsonEncode({'job': 'old', 'spendUsd': 19.5, 'endedAt': DateTime.now().toIso8601String()})}\n');
      final runs = launcher(runners: runners, history: history);
      await expectLater(
        runs.startRun(runner: 'noop', configName: paid, agent: 'hybrid', maxUsd: 1, approve: (_) async => true),
        throwsA(isA<AibError>().having((e) => e.message, 'message', contains('daily budget'))),
      );
    });

    test('local models cost nothing and need no approval', () {
      final targets = modelTargets(Builtins.loadConfig(p.join(repoRoot, 'suites', 'agents', 'routed_v2_jev3.yaml')));
      final prices = PriceTable.fromJson(Builtins.loadConfig(p.join(repoRoot, 'suites', 'pricing_2026_09.yaml')));
      expect(paidTargets(targets, prices), isEmpty);
      expect(hostsOf(targets, {'ollama': const HostLimit(name: 'ollama', url: 'http://127.0.0.1:11434/')}), {'ollama'});
    });
  });

  test('estimate reads earlier runs of the same arm', () {
    // A workspace of its own: the checkout's results/ is whatever the last
    // study left there, and pruning it must not break a test. The suites are
    // copied in rather than linked, because the sandbox refuses a path that
    // resolves outside the root.
    final root = Directory(p.join(scratch.path, 'estimate'));
    void copy(Directory from, Directory to) {
      for (final entity in from.listSync(recursive: true)) {
        final target = p.join(to.path, p.relative(entity.path, from: from.path));
        if (entity is File) {
          Directory(p.dirname(target)).createSync(recursive: true);
          entity.copySync(target);
        }
      }
    }

    copy(Directory(p.join(repoRoot, 'suites')), Directory(p.join(root.path, 'suites')));
    // Kept as runs/, because results/ is ignored by git wherever it occurs.
    copy(
      Directory(p.join(repoRoot, 'packages', 'aib_mcp', 'test', 'fixtures', 'estimate_workspace', 'runs')),
      Directory(p.join(root.path, 'results')),
    );
    final runs = launcher(root: root.path);
    final estimate = runs.estimate(configName: 'routed_v2_jev3', agent: 'prepared', suite: 'todo_v2', reps: 1);
    expect(estimate['episodes'], 16);
    expect((estimate['basis'] as Map)['runs'], ['results/route-v2-n3-jev3']);
    expect((estimate['basis'] as Map)['episodes'], 3);
    expect(estimate['wallClockMinutes'], isPositive);
    expect(estimate['paidModels'], isEmpty);
  });

  test('the planned episodes count each instruction variant', () {
    final suite = AibWorkspace(AibMcpConfig(root: repoRoot)).service.validateSuite(p.join(repoRoot, 'suites', 'sysco_v1.yaml')).suite!;
    final variants = suite.tasks.fold(0, (n, task) => n + task.variants.length);
    expect(variants, isPositive);
    final estimate = launcher().estimate(configName: 'offline_qwen3_4b', agent: 'hybrid', suite: 'sysco_v1', reps: 2);
    expect(estimate['episodes'], 2 * (suite.tasks.length + variants));
  });

  group('over MCP', () {
    late ServerConnection server;
    late _Client client;
    late AibMcpServer mcp;

    setUpAll(() async {
      final toServer = StreamController<String>();
      final toClient = StreamController<String>();
      mcp = AibMcpServer(
        StreamChannel<String>.withCloseGuarantee(toServer.stream, toClient.sink),
        workspace: launcher().workspace,
        runs: launcher(runners: {'noop': sh('noop', 'true')}),
      );
      client = _Client();
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
    });

    Future<CallToolResult> call(String tool, Map<String, Object?> args, {MetaWithProgressToken? meta}) =>
        server.callTool(CallToolRequest(name: tool, arguments: args, meta: meta));

    test('a paid run is approved through elicitation', () async {
      client.answer = false;
      final declined = await call('aib_run_start', {'runner': 'noop', 'config': 'anthropic', 'agent': 'hybrid', 'maxUsd': 1});
      expect(declined.isError, isTrue);
      expect(client.asked, hasLength(1));
      client.answer = true;
      final started = await call('aib_run_start', {'runner': 'noop', 'config': 'anthropic', 'agent': 'hybrid', 'maxUsd': 1, 'out': out('elicited')});
      expect(started.isError, isNot(isTrue), reason: '${started.content}');
      final id = started.structuredContent!['job'] as String;
      final done = await call('aib_job_wait', {'job': id, 'seconds': 30});
      expect(done.structuredContent!['state'], 'succeeded');
      final launch = jsonDecode(File(p.join(repoRoot, 'results', out('elicited'), RunLauncher.launchFile)).readAsStringSync()) as List;
      expect(launch.single, containsPair('client', 'jobs-test'));
    });

    test('a job waited on with a progress token reports progress', () async {
      final started = await call('aib_run_start', {
        'runner': 'mock',
        'config': 'experiments/${p.basenameWithoutExtension(scripted.path)}',
        'agent': 'scripted',
        'suite': 'mock_v1',
        'reps': 1,
        'out': out('progress'),
      });
      final request = CallToolRequest(
        name: 'aib_job_wait',
        arguments: {'job': started.structuredContent!['job'], 'seconds': 60},
        meta: MetaWithProgressToken(progressToken: ProgressToken('wait-1')),
      );
      final progress = <ProgressNotification>[];
      final sub = server.onProgress(request).listen(progress.add);
      final result = await server.callTool(request);
      await sub.cancel();
      expect(result.structuredContent!['state'], 'succeeded');
      expect(progress, isNotEmpty);
      expect(progress.last.total, 4);
    });
  });
}

base class _Client extends MCPClient with ElicitationFormSupport {
  _Client() : super(Implementation(name: 'jobs-test', version: '0'));

  bool answer = false;
  final asked = <String>[];

  @override
  FutureOr<ElicitResult> handleElicitation(ElicitRequest request, ServerConnection connection) {
    asked.add(request.message);
    return ElicitResult(action: .accept, content: {'approve': answer});
  }
}
