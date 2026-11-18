import 'dart:io';

import 'package:aib_agents/aib_agents.dart';
import 'package:aib_cli/aib_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Every shipped agent config builds its agent — a typo in a YAML block is
/// found here rather than at the start of an overnight run.
void main() {
  final repoRoot = Directory.current.path.endsWith('aib_cli') ? p.normalize(p.join(Directory.current.path, '..', '..')) : Directory.current.path;
  final dir = Directory(p.join(repoRoot, 'suites', 'agents'));
  final agents = Builtins.agentRegistry();

  for (final file in dir.listSync().whereType<File>().where((f) => p.basename(f.path).startsWith('routed_'))) {
    // A routed arm with a `preparation:` block runs as the prepared agent,
    // one without runs as the hybrid. Model routing lives in the client, so both
    // must come out with a ModelRouter.
    final config = Builtins.loadConfig(file.path);
    final kind = config.containsKey('preparation') ? 'prepared' : 'hybrid';
    test('${p.basename(file.path)} builds a routed $kind agent', () {
      final agent = agents.create(kind, config) as ToolLoopAgent;
      expect(agent.client, isA<ModelRouter>());
      final blocks = agent.manifest.metadata['configBlocks'] as Map;
      expect(blocks, contains('modelRouter'));
    });
  }
}
