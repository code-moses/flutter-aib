import 'dart:async';
import 'dart:io';

import 'package:aib_core/aib_core.dart';
import 'package:aib_mcp/aib_mcp.dart';
import 'package:args/args.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:path/path.dart' as p;

/// `dart run packages/aib_mcp/bin/server.dart --config aib_mcp.yaml` — the
/// MCP server on stdio; stdout carries the protocol, nothing else may print
/// to it. With `--http`, Streamable HTTP on the configured host and port
/// instead, one server per session, with the bearer token from the
/// environment (`http.tokenEnv`, default AIB_MCP_TOKEN).
Future<void> main(List<String> arguments) async {
  final args =
      (ArgParser()
            ..addOption('config', help: 'aib_mcp.yaml (default: ./aib_mcp.yaml if present, else the current directory as root).')
            ..addFlag('http', negatable: false, help: 'Serve Streamable HTTP instead of stdio.'))
          .parse(arguments);
  final configPath = args['config'] as String? ?? (File('aib_mcp.yaml').existsSync() ? 'aib_mcp.yaml' : null);
  final config = configPath == null ? AibMcpConfig(root: '.') : AibMcpConfig.load(configPath);
  // Paths recorded in manifests are relative to where a run was started;
  // the checkout is where they resolve.
  Directory.current = config.root;
  final framework = (await SourceRevision.ofPackage('aib_core'))?.label;
  final workspace = AibWorkspace(config);
  // One job manager for the process: the host queue and the daily budget are
  // the machine's, whichever session starts a run.
  final jobs = JobManager(
    hostLimits: {for (final h in config.hosts.values) h.name: h.concurrency},
    historyFile: File(p.join(config.root, 'results', '.aib_mcp', 'jobs.jsonl')),
  );
  final runs = RunLauncher(workspace: workspace, jobs: jobs);

  // Whatever ends the server — the client closing stdin, or a signal — the
  // jobs stop and their cleanup runs, so no app keeps its benchmark inputs.
  McpHttpServer? http;
  Future<void> stop() async {
    await http?.close();
    await jobs.shutdown();
    exit(0);
  }

  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    signal.watch().listen((_) => stop());
  }

  if (args['http'] as bool) {
    final token = Platform.environment[config.http.tokenEnv];
    if (token == null || token.length < 16) {
      stderr.writeln('--http needs a bearer token of at least 16 characters in \$${config.http.tokenEnv}.');
      exit(64);
    }
    http = await McpHttpServer.serve(
      token: token,
      host: config.http.host,
      port: config.http.port,
      path: config.http.path,
      allowedOrigins: config.http.allowedOrigins,
      connect: (channel) => AibMcpServer(channel, workspace: workspace, runs: runs, frameworkRevision: framework),
    );
    stderr.writeln('aib MCP server on http://${config.http.host}:${http.port}${config.http.path}');
    return;
  }
  final server = AibMcpServer(
    stdioChannel(input: stdin, output: stdout),
    workspace: workspace,
    runs: runs,
    frameworkRevision: framework,
  );
  unawaited(server.done.then((_) => stop()));
}
