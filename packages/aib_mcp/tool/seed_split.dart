import 'dart:io';

import 'package:aib_cli/aib_cli.dart';
import 'package:aib_mcp/aib_mcp.dart';
import 'package:path/path.dart' as p;

/// `dart run packages/aib_mcp/tool/seed_split.dart <suite>…` from the
/// checkout: writes `suites/splits/<suite>.yaml` with a seeded 30% holdout.
///
/// A split is written once and then reviewed and kept: re-seeding would
/// move the holdout, and every holdout score before it would stop meaning
/// anything. So an existing split is never overwritten.
void main(List<String> suites) {
  for (final name in suites) {
    final out = File(p.join(SuiteSplit.directory, '$name.yaml'));
    if (out.existsSync()) {
      stderr.writeln('${out.path} exists; a split is never re-seeded.');
      exitCode = 1;
      continue;
    }
    final suite = const AibService().validateSuite(p.join('suites', '$name.yaml')).suite ?? (throw StateError('$name does not load'));
    final holdout = SuiteSplit.seeded(suite.tasks.map((t) => t.id));
    out.parent.createSync(recursive: true);
    out.writeAsStringSync('''
# Holdout of $name (docs/overview.md, "The MCP server").
#
# Tasks listed here are never shown to, run by or scored for a tuning agent
# over MCP; aib_holdout_score runs an arm on them, with a person's approval
# every time, and journals the call. Seeded: the ${holdout.length} of ${suite.tasks.length} task ids
# whose sha256("aib-split-v1:<id>") sorts first (SuiteSplit.seeded). Review
# the choice once, then leave it: moving the holdout voids every holdout
# score made before.
suite: $name
holdout:
${holdout.map((id) => '  - $id').join('\n')}
''');
    stdout.writeln('${out.path}: ${holdout.length} of ${suite.tasks.length} held out.');
  }
}
