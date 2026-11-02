// Derives each task's retrieval gold set from its reference trajectory.
//
// `requiredTools` is what tool-retrieval research scores a retriever against
// (Recall@k, nDCG@k, Completeness@k). A reference is one trajectory, not the
// minimal one, so this is a starting point: rerunning with --write only fills
// tasks that have no `requiredTools` yet.
//
// Only `intents.invoke` counts: what a reference *described* is the agent's
// guess about what it might need.
//
//   fvm dart run packages/aib_cli/tool/required_tools.dart \
//     suites/references/sysco_v1.yaml [--write suites/sysco_v1.yaml]
//
// Without --write it prints the fragments and changes nothing.

import 'dart:io';

import 'package:yaml/yaml.dart';

void main(List<String> args) {
  final positional = [
    for (final arg in args)
      if (!arg.startsWith('--')) arg,
  ];
  if (positional.isEmpty) {
    stderr.writeln('usage: required_tools.dart <references.yaml> [--write <suite.yaml>]');
    exit(2);
  }

  final referencesPath = positional.first;
  final writeIndex = args.indexOf('--write');
  final suitePath = writeIndex >= 0 && writeIndex + 1 < args.length ? args[writeIndex + 1] : null;

  final references = loadYaml(File(referencesPath).readAsStringSync());
  final scripts = (references as YamlMap)['scripts'];
  if (scripts is! YamlMap) {
    stderr.writeln('$referencesPath has no "scripts" map');
    exit(1);
  }

  final tools = _invokedIntents(scripts);
  if (suitePath == null) {
    for (final entry in tools.entries) {
      stdout.writeln('${entry.key}:');
      stdout.writeln('    requiredTools: [${entry.value.join(', ')}]');
    }
    stderr.writeln('${tools.length} task(s) have a reference trajectory.');
    return;
  }

  final file = File(suitePath);
  final patched = _patch(file.readAsLinesSync(), tools);
  file.writeAsStringSync('${patched.lines.join('\n')}\n');
  stderr.writeln(
    'wrote ${patched.added} requiredTools line(s) to $suitePath; '
    '${patched.kept} task(s) already declared one, '
    '${patched.missing} had no reference.',
  );
}

/// Intent names a reference episode actually invoked, in first-seen order.
Map<String, List<String>> _invokedIntents(YamlMap scripts) {
  final result = <String, List<String>>{};
  for (final entry in scripts.entries) {
    final steps = entry.value;
    if (steps is! YamlList) continue;
    final intents = <String>{};
    for (final step in steps) {
      if (step is! YamlMap || step['key'] != 'intents.invoke') continue;
      final payload = step['payload'];
      if (payload is! YamlMap) continue;
      if (payload['intent'] case final String intent) intents.add(intent);
    }
    if (intents.isNotEmpty) result['${entry.key}'] = intents.toList();
  }
  return result;
}

typedef _Patch = ({List<String> lines, int added, int kept, int missing});

/// Inserts `requiredTools:` under every task that has a gold set and does not
/// already declare one. Textual on purpose: re-emitting the suite through a
/// YAML writer would reformat a file whose comments are half its value.
_Patch _patch(List<String> lines, Map<String, List<String>> tools) {
  final idPattern = RegExp(r'^  - id: (\S+)');
  final declared = <String>{};

  // Which tasks already say it, so a second run is a no-op.
  String? current;
  for (final line in lines) {
    final match = idPattern.firstMatch(line);
    if (match != null) current = match.group(1);
    if (current != null && line.startsWith('    requiredTools:')) {
      declared.add(current);
    }
  }

  final out = <String>[];
  var added = 0;
  for (final line in lines) {
    out.add(line);
    final match = idPattern.firstMatch(line);
    if (match == null) continue;
    final id = match.group(1)!;
    if (declared.contains(id) || !tools.containsKey(id)) continue;
    out.add('    requiredTools: [${tools[id]!.join(', ')}]');
    added++;
  }

  final ids = [
    for (final line in lines)
      if (idPattern.firstMatch(line) case final m?) m.group(1)!,
  ];
  return (lines: out, added: added, kept: ids.where(declared.contains).length, missing: ids.where((id) => !tools.containsKey(id)).length);
}
