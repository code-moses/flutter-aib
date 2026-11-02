import 'dart:io';

import 'package:aib_mcp/aib_mcp.dart';
import 'package:aib_ui/src/runner_check.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

RunnerRecipe recipe({String? cwd, List<String>? prepare, List<String> command = const [], List<String>? cleanup}) =>
    RunnerRecipe(name: 'app', cwd: cwd, prepare: prepare, command: command, cleanup: cleanup);

void main() {
  test('scripts are found in plain commands and inside sh -c strings, placeholders and options left out', () {
    final r = recipe(
      prepare: ['sh', '-c', 'fvm dart integration_test/aib/prepare.dart && fvm dart integration_test/enable.dart'],
      command: [
        'fvm',
        'flutter',
        'test',
        'integration_test/aib/live_test.dart',
        '-d',
        'macos',
        '--dart-define=AIB_AGENT={agentConfigFile}',
        './tool/run.sh',
      ],
      cleanup: ['fvm', 'dart', '/abs/path/clean.dart', r'$HOME/x.dart'],
    );
    expect(scriptsOf(r), {'integration_test/aib/prepare.dart', 'integration_test/enable.dart', 'integration_test/aib/live_test.dart', 'tool/run.sh'});
  });

  test('a recipe that is in process needs nothing', () async {
    final r = await checkRunner(
      const RunnerRecipe(name: 'mock', kind: .inProcess),
      root: '/nowhere',
    );
    expect(r['ok'], isTrue);
  });

  test('a missing working directory is named, with the setting to change', () async {
    final r = await checkRunner(
      recipe(cwd: '/no/such/dir', command: ['dart', 'a.dart']),
      root: Directory.systemTemp.path,
    );
    expect(r['ok'], isFalse);
    expect(r['cwdMissing'], isTrue);
    expect(r['message'], allOf(contains('/no/such/dir'), contains('aib_mcp.local.yaml')));
  });

  test('a script the checked-out tree lacks is reported with the branch that has it', () async {
    final tmp = Directory.systemTemp.createTempSync('aib_runner_check');
    addTearDown(() => tmp.deleteSync(recursive: true));
    Future<void> git(List<String> args) async {
      final r = await Process.run('git', ['-C', tmp.path, '-c', 'user.email=t@t', '-c', 'user.name=t', ...args]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }

    await git(['init', '-b', 'develop']);
    File(p.join(tmp.path, 'README')).writeAsStringSync('x');
    await git(['add', '.']);
    await git(['commit', '-m', 'one']);
    await git(['switch', '-c', 'feature']);
    Directory(p.join(tmp.path, 'integration_test')).createSync();
    File(p.join(tmp.path, 'integration_test', 'prepare.dart')).writeAsStringSync('void main(){}');
    await git(['add', '.']);
    await git(['commit', '-m', 'two']);
    await git(['switch', 'develop']);

    final r = await checkRunner(
      recipe(cwd: tmp.path, prepare: ['dart', 'integration_test/prepare.dart']),
      root: '/unused',
    );
    expect(r['ok'], isFalse);
    expect(r['branch'], 'develop');
    final missing = (r['missing'] as List).single as Map;
    expect(missing['file'], 'integration_test/prepare.dart');
    expect(missing['branches'], ['feature']);
    expect(r['message'], contains('switch feature'));

    await git(['switch', 'feature']);
    expect(
      (await checkRunner(
        recipe(cwd: tmp.path, prepare: ['dart', 'integration_test/prepare.dart']),
        root: '/unused',
      ))['ok'],
      isTrue,
    );
  });
}
