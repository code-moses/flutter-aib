import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:aib_ui/aib_ui.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

/// `dart run aib_ui [--root <checkout>] [--library <runs folder>] [--port 8787]`
///
/// Serves the web UI and its API on the loopback interface and opens it in
/// the browser. Without a checkout (no aib_mcp.yaml) it still browses any
/// folder of runs; configuring and starting runs needs the checkout.
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('root', help: 'The framework checkout (default: the current directory, or the nearest parent with aib_mcp.yaml).')
    ..addOption('config', help: 'aib_mcp.yaml (default: <root>/aib_mcp.yaml).')
    ..addOption('library', abbr: 'l', help: 'The folder of runs to open first (default: <root>/results).')
    ..addOption('port', abbr: 'p', defaultsTo: '8787')
    ..addOption(
      'otlp-port',
      defaultsTo: '4318',
      help: 'Also receive OTLP/HTTP spans on this port (the conventional one); 0 = only on the UI port. Spans are accepted on /v1/traces of either.',
    )
    ..addFlag('open', defaultsTo: true, help: 'Open the browser.')
    ..addFlag(
      'show-holdout',
      negatable: false,
      help: "Show the task text of a suite's holdout split in run views (hidden by default, as the framework hides it from tuning agents).",
    )
    ..addFlag('help', abbr: 'h', negatable: false);
  final args = parser.parse(arguments);
  if (args['help'] as bool) {
    stdout.writeln('aib_ui — a local web UI for the AI Interaction Benchmark\n\n${parser.usage}');
    return;
  }
  final root = args['root'] as String? ?? _findRoot(Directory.current.path);
  final webUri = await Isolate.resolvePackageUri(Uri.parse('package:aib_ui/aib_ui.dart'));
  if (webUri == null) {
    stderr.writeln('Cannot locate the aib_ui package; run it with `dart run aib_ui`.');
    exit(70);
  }
  final web = p.normalize(p.join(p.dirname(p.dirname(webUri.toFilePath())), 'web'));
  late final UiServer server;
  try {
    server = await UiServer.serve(
      root: root,
      configPath: args['config'] as String?,
      library: args['library'] as String?,
      webDir: web,
      port: int.parse(args['port'] as String),
      showHoldout: args['show-holdout'] as bool,
      otlpPort: int.parse(args['otlp-port'] as String),
    );
  } on SocketException catch (e) {
    stderr.writeln('Cannot listen on port ${args['port']}: ${e.osError?.message ?? e.message}. Try --port.');
    exit(73);
  }
  final url = 'http://localhost:${server.port}/';
  stdout.writeln('aib_ui  $url');
  stdout.writeln('  checkout  ${server.workspace == null ? '— none (browse-only; pass --root <checkout> to configure and run)' : server.root}');
  stdout.writeln('  runs      ${server.defaultLibrary}');
  stdout.writeln(
    '  otel      ${server.otlpPort == null ? 'http://localhost:${server.port}/v1/traces' : 'http://localhost:${server.otlpPort}/v1/traces  (also on the UI port)'}',
  );
  if (args['open'] as bool) unawaited(_open(url));

  Future<void> stop() async {
    await server.close();
    exit(0);
  }

  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    signal.watch().listen((_) => stop());
  }
}

String _findRoot(String start) {
  var dir = start;
  while (true) {
    if (File(p.join(dir, 'aib_mcp.yaml')).existsSync()) return dir;
    final up = p.dirname(dir);
    if (up == dir) return start;
    dir = up;
  }
}

Future<void> _open(String url) async {
  try {
    if (Platform.isMacOS) {
      await Process.run('open', [url]);
    } else if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', url]);
    } else {
      await Process.run('xdg-open', [url]);
    }
  } on Object {
    // The URL is printed; opening it is a convenience.
  }
}
