import 'dart:convert';
import 'dart:io';

import 'package:aib_core/aib_core.dart';
import 'package:aib_mcp/aib_mcp.dart';
import 'package:path/path.dart' as p;

/// `dart run packages/aib_mcp/tool/withhold_holdout.dart <suite>…`: moves the
/// held-out tasks (`suites/splits/<suite>.yaml`) and their reference
/// trajectories into git-ignored `*.private.yaml` siblings. Prints no task
/// content; refuses to write unless the merged suite hashes as before.
void main(List<String> suites) {
  for (final name in suites) {
    try {
      _withhold(name);
    } on Object catch (e) {
      stderr.writeln('$name: $e');
      exitCode = 1;
    }
  }
}

const _stubComment = 'held out; the rest of this task is in the private file next to this suite, which is not published';

void _withhold(String name) {
  final split = SuiteSplit.load('.', name) ?? (throw StateError('no split in ${SuiteSplit.directory}/$name.yaml'));
  final suitePath = p.join('suites', '$name.yaml');
  final privatePath = SuiteLoader.privatePath(suitePath);
  if (File(privatePath).existsSync()) throw StateError('$privatePath exists; the suite is already split');

  final before = SuiteLoader.loadFile(suitePath);
  if (!before.isValid) throw StateError('suite does not load: ${before.errors.length} errors');
  final original = File(suitePath).readAsStringSync();
  final parts = splitWithheld(
    original,
    split.holdout,
    stubComment: _stubComment,
    privateHeader:
        '''
# Held-out tasks of $name, withheld from the public repository.
#
# NOT PUBLISHED (git-ignored). Each block below is the full task, expected
# results included, exactly as it stood in $name.yaml. The suite keeps a stub
# with `withheld: true` in its place; SuiteLoader.loadFile puts the block back,
# so a checkout with this file loads and hashes the suite as before the split.
# Keep a backup of this file outside the repository: without it the held-out
# tasks cannot be run or scored. Split from ${SuiteSplit.directory}/$name.yaml
# by packages/aib_mcp/tool/withhold_holdout.dart.''',
  );

  // The round trip must restore the original text byte for byte.
  final (merged, problems) = mergeWithheld(parts.public, parts.private);
  if (problems.isNotEmpty) throw StateError(problems.join('; '));
  if (merged != original) throw StateError('merge does not restore the suite text');

  final referencesPath = p.join('suites', 'references', '$name.yaml');
  final referencesFile = File(referencesPath);
  (String, String, int)? references;
  if (referencesFile.existsSync()) {
    references = _splitReferences(referencesFile.readAsStringSync(), split.holdout, name);
  }

  File(privatePath).writeAsStringSync(parts.private);
  File(suitePath).writeAsStringSync(parts.public);
  final after = SuiteLoader.loadFile(suitePath);
  final checks = [
    if (!after.isValid) 'merged suite does not load',
    if (after.suite?.sourceHash != before.suite!.sourceHash) 'source hash moved',
    if (after.suite?.contentHash != before.suite!.contentHash) 'content hash moved',
  ];
  if (checks.isNotEmpty) {
    File(suitePath).writeAsStringSync(original);
    File(privatePath).deleteSync();
    throw StateError('${checks.join(', ')}; restored');
  }
  stdout.writeln('$suitePath: ${parts.withheld.length} task(s) withheld, hashes unchanged (${before.suite!.sourceHash!.substring(0, 12)}).');

  if (references case (final public, final private, final count)) {
    final privateRefs = SuiteLoader.privatePath(referencesPath);
    final originalRefs = referencesFile.readAsStringSync();
    final beforeRefs = SuiteLoader.loadReferences(referencesPath);
    File(privateRefs).writeAsStringSync(private);
    referencesFile.writeAsStringSync(public);
    final afterRefs = SuiteLoader.loadReferences(referencesPath);
    if (jsonEncode(_sorted(beforeRefs)) != jsonEncode(_sorted(afterRefs))) {
      referencesFile.writeAsStringSync(originalRefs);
      File(privateRefs).deleteSync();
      throw StateError('references do not load the same after the split; restored');
    }
    stdout.writeln('$referencesPath: $count reference(s) withheld, scripts unchanged when merged.');
  }
}

Object? _sorted(Object? json) => switch (json) {
  final Map<dynamic, dynamic> m => {for (final k in (m.keys.map((k) => '$k').toList()..sort())) k: _sorted(m[k])},
  final List<dynamic> l => [for (final e in l) _sorted(e)],
  _ => json,
};

/// Moves the `scripts:` entries of [ids] (with the comments above them) out of
/// a reference file.
(String, String, int) _splitReferences(String text, Set<String> ids, String name) {
  final lines = text.split('\n');
  final key = RegExp(r'^  ([^\s#][^:]*):\s*$');
  final starts = <(int, String)>[];
  for (final (i, line) in lines.indexed) {
    if (key.firstMatch(line) case final m?) {
      var start = i;
      while (start > 0 && lines[start - 1].startsWith('  #')) {
        start--;
      }
      starts.add((start, m.group(1)!.trim()));
    }
  }
  final public = <String>[];
  final private = <String>[
    '# Reference trajectories of the held-out tasks of $name, withheld from the',
    '# public repository (they are solutions). NOT PUBLISHED (git-ignored).',
    '# SuiteLoader.loadReferences adds these scripts to $name.yaml next to it.',
    '# Keep a backup outside the repository.',
    'scripts:',
  ];
  var cursor = 0;
  var count = 0;
  for (final (k, (start, id)) in starts.indexed) {
    if (!ids.contains(id)) continue;
    var end = k + 1 < starts.length ? starts[k + 1].$1 : lines.length;
    // Trailing blank lines stay in the public file.
    while (end > start + 1 && lines[end - 1].trim().isEmpty) {
      end--;
    }
    public.addAll(lines.sublist(cursor, start));
    private.addAll(lines.sublist(start, end));
    cursor = end;
    count++;
  }
  public.addAll(lines.sublist(cursor));
  final header = '# The held-out tasks\' references are in $name.private.yaml next to this file (not published).';
  final insertAt = public.indexWhere((l) => l.startsWith('scripts:'));
  if (insertAt >= 0) public.insert(insertAt, header);
  return (public.join('\n'), '${private.join('\n')}\n', count);
}
