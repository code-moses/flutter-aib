import 'dart:convert';
import 'dart:io';

import 'package:aib_core/aib_core.dart';
import 'package:aib_mcp/aib_mcp.dart';
import 'package:aib_mcp/src/jev_probe.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Tool-selection prompts × decision backends on labelled tasks ([JevProbe]).
///
/// ```sh
/// # 1. labels from judged runs (tuning split only; the fixture holds the
/// #    app's catalogue text, so it stays under results/)
/// dart run packages/aib_mcp/bin/jev_probe.dart extract --suite sysco_v1 \
///   --runs results/tsurf-local_gemma4_26b,results/tsurf-local_gemma4_26b_fixed \
///   --out results/jev-probe/sysco_v1.json
///
/// # 2. compare (keys from the environment: TYPESAFE_API_KEY for the hosted API)
/// dart run packages/aib_mcp/bin/jev_probe.dart run \
///   --fixture results/jev-probe/sysco_v1.json \
///   --variants suites/jev_probe/selection_variants.yaml \
///   --backends suites/jev_probe/backends.yaml --only hosted-latest \
///   --out results/jev-probe/2026-10-15
///
/// # 3. re-summarise a finished probe with other thresholds
/// dart run packages/aib_mcp/bin/jev_probe.dart summarise \
///   --fixture results/jev-probe/sysco_v1.json --result results/jev-probe/2026-10-15/selections.json
/// ```
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()..addOption('config', help: 'aib_mcp.yaml (default: ./aib_mcp.yaml if present, else the current directory as root).');
  parser.addCommand('extract')
    ..addOption('suite', mandatory: true)
    ..addMultiOption('runs', help: 'Judged run directories, comma-separated.')
    ..addOption('min-share', defaultsTo: '0.5', help: 'Share of successful episodes that must invoke an intent for it to count as needed.')
    ..addOption('out', mandatory: true);
  ArgParser summary() => ArgParser()
    ..addOption('fixture', mandatory: true)
    ..addOption('thresholds', defaultsTo: '0.4,0.5')
    ..addOption('min-keep', defaultsTo: '5', help: 'The floor reported next to the last threshold.');
  parser.addCommand('run', summary())
    ..addOption('variants', mandatory: true, help: 'YAML: variants: [{id, statement?, ifTrue?, ifFalse?, state?, candidate?}]')
    ..addOption('backends', mandatory: true, help: 'YAML: backends: {name: <jev block>}')
    ..addMultiOption('only', help: 'Backend names to run (default: all).')
    ..addMultiOption('tasks', help: 'Task ids (default: every labelled task).')
    ..addOption('reps', defaultsTo: '1')
    ..addOption('out', mandatory: true, help: 'Directory for selections.json and summary.md.');
  parser.addCommand('summarise', summary()).addOption('result', mandatory: true);

  final args = parser.parse(arguments);
  final command = args.command;
  if (command == null) {
    stderr.writeln('usage: jev_probe <extract|run|summarise> …\n${parser.usage}');
    exitCode = 64;
    return;
  }

  switch (command.name) {
    case 'extract':
      final configPath = args['config'] as String? ?? (File('aib_mcp.yaml').existsSync() ? 'aib_mcp.yaml' : null);
      final workspace = AibWorkspace(configPath == null ? AibMcpConfig(root: '.') : AibMcpConfig.load(configPath));
      final runs = [for (final value in command['runs'] as List<String>) ...value.split(',').where((r) => r.isNotEmpty)];
      final fixture = JevProbe.extract(
        workspace: workspace,
        suite: command['suite'] as String,
        runs: runs,
        minShare: double.parse(command['min-share'] as String),
      );
      _write(command['out'] as String, const JsonEncoder.withIndent('  ').convert(fixture));
      for (final task in fixture['tasks'] as List) {
        final t = asJsonMap(task);
        stdout.writeln(
          '${'${t['id']}'.padRight(32)} n=${t['successes']}  needed: ${(t['needed'] as List).join(', ')}'
          '${(t['useful'] as List).isEmpty ? '' : '  useful: ${(t['useful'] as List).join(', ')}'}',
        );
      }
    case 'run':
      final fixture = _json(command['fixture'] as String);
      final variants = [for (final v in _yaml(command['variants'] as String)['variants'] as List) asJsonMap(v)];
      final only = (command['only'] as List<String>).expand((v) => v.split(',')).toSet();
      final backends = {
        for (final e in asJsonMap(_yaml(command['backends'] as String)['backends']).entries)
          if (only.isEmpty || only.contains(e.key)) e.key: asJsonMap(e.value),
      };
      final taskIds = (command['tasks'] as List<String>).expand((v) => v.split(',')).toSet();
      final result = await JevProbe.run(
        fixture: fixture,
        variants: variants,
        backends: backends,
        taskIds: taskIds.isEmpty ? null : taskIds,
        repetitions: int.parse(command['reps'] as String),
        onProgress: stderr.writeln,
      );
      final out = command['out'] as String;
      _write(p.join(out, 'selections.json'), const JsonEncoder.withIndent('  ').convert(result));
      _summarise(command, fixture, result, out: out);
    case 'summarise':
      _summarise(command, _json(command['fixture'] as String), _json(command['result'] as String));
  }
}

void _summarise(ArgResults command, JsonMap fixture, JsonMap result, {String? out}) {
  final thresholds = [for (final t in (command['thresholds'] as String).split(',')) double.parse(t)];
  final minKeep = int.parse(command['min-keep'] as String);
  final rows = JevProbe.summarise(fixture: fixture, result: result, thresholds: thresholds, minKeep: minKeep);
  final table = JevProbe.table(rows, thresholds: thresholds, minKeep: minKeep);
  stdout.writeln(table);
  if (out != null) {
    _write(p.join(out, 'summary.md'), '$table\n');
    _write(p.join(out, 'summary.json'), const JsonEncoder.withIndent('  ').convert(rows));
  }
}

JsonMap _json(String path) => asJsonMap(jsonDecode(File(path).readAsStringSync()));

JsonMap _yaml(String path) => asJsonMap(jsonDecode(jsonEncode(loadYaml(File(path).readAsStringSync()))));

void _write(String path, String content) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(content);
  stderr.writeln('wrote $path');
}
