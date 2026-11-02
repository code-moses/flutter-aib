import 'dart:io';

import 'package:aib_cli/aib_cli.dart';
import 'package:aib_mcp/aib_mcp.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  final repoRoot = Directory.current.path.endsWith('aib_mcp') ? p.normalize(p.join(Directory.current.path, '..', '..')) : Directory.current.path;

  group('toYaml', () {
    // The shipped arms only: other test files create and remove arms under
    // experiments/ while this one runs.
    final configs = Directory(p.join(repoRoot, 'suites', 'agents')).listSync().whereType<File>().where((f) => f.path.endsWith('.yaml'));
    for (final file in configs) {
      test('round-trips ${p.basename(file.path)}', () {
        final config = Builtins.loadConfig(file.path);
        expect(yamlToJson(loadYaml(toYaml(config))), config);
      });
    }

    test('quotes what would read as something else', () {
      final value = {'a': 'true', 'b': '5m', 'c': 'x: y', 'd': 'line\nbreak', 'e': '', 'f': '# no', 'g': 'qwen3:8b', 'h': 'http://localhost:11434'};
      expect(yamlToJson(loadYaml(toYaml(value))), value);
      expect(toYaml(value), contains('g: qwen3:8b'));
    });

    test('lists of maps and nested lists', () {
      final value = {
        'l': [
          {
            'a': 1,
            'b': [1, 2],
          },
          [1, 'x'],
          <String, Object?>{},
          null,
        ],
      };
      expect(yamlToJson(loadYaml(toYaml(value))), value);
    });
  });

  group('arms', () {
    test('mergePatch merges maps, removes on null, replaces the rest', () {
      expect(
        mergePatch(
          {
            'a': {'x': 1, 'y': 2},
            'b': [1],
            'c': 3,
          },
          {
            'a': {'x': null, 'z': 4},
            'b': [2],
            'd': {'e': 5},
          },
        ),
        {
          'a': {'y': 2, 'z': 4},
          'b': [2],
          'c': 3,
          'd': {'e': 5},
        },
      );
    });

    test('a whole added block is one change; two leaves are two', () {
      final base = {
        'preparation': {'topK': 5, 'minScore': 0.25},
      };
      expect(
        configChanges(base, {
          ...base,
          'decisions': {
            'completion': {'threshold': 0.5},
          },
        }).map((c) => c.path),
        ['decisions'],
      );
      expect(
        configChanges(base, {
          'preparation': {'topK': 8, 'minScore': 0.3},
        }).map((c) => c.path),
        ['preparation.minScore', 'preparation.topK'],
      );
      expect(configChanges(base, base), isEmpty);
    });
  });

  group('PathSandbox', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('aib_sandbox_');
      Directory(p.join(root.path, 'results')).createSync();
      Directory(p.join(root.path, 'suites')).createSync();
    });
    tearDown(() => root.delete(recursive: true));

    test('resolves inside the root and refuses outside', () {
      final sandbox = PathSandbox(root.path, ['results']);
      expect(sandbox.read('suites/x.yaml'), p.join(sandbox.root, 'suites', 'x.yaml'));
      expect(() => sandbox.read('../etc/passwd'), throwsA(isA<AibError>()));
      expect(() => sandbox.read('/etc/passwd'), throwsA(isA<AibError>()));
    });

    test('writes only under writable directories', () {
      final sandbox = PathSandbox(root.path, ['results']);
      expect(sandbox.write('results/run/verdicts.json'), endsWith(p.join('results', 'run', 'verdicts.json')));
      expect(() => sandbox.write('suites/x.yaml'), throwsA(isA<AibError>()));
    });

    test('a symlink out of the root is refused like its target', () {
      final outside = Directory.systemTemp.createTempSync('aib_outside_');
      addTearDown(() => outside.delete(recursive: true));
      Link(p.join(root.path, 'results', 'escape')).createSync(outside.path);
      final sandbox = PathSandbox(root.path, ['results']);
      expect(() => sandbox.read('results/escape/file'), throwsA(isA<AibError>()));
    });
  });
}
