import 'dart:io';

import 'package:aib_mcp/aib_mcp.dart';
import 'package:path/path.dart' as p;

import 'run_reader.dart' show Json;

/// What a runner recipe needs on this machine before a run can start: the
/// working directory, and the scripts its `prepare`, `command` and `cleanup`
/// name. A recipe points into another repository (an app); that repository
/// being on the wrong branch is the usual way for it to be missing a script,
/// and the job's own failure — a Dart "file not found" deep in a log — does
/// not say so.
///
/// Returns `ok`, the resolved `cwd`, its git `branch`, and for each missing
/// file the local branches that do hold it.
Future<Json> checkRunner(RunnerRecipe recipe, {required String root}) async {
  if (recipe.kind == .inProcess) return {'ok': true, 'inProcess': true, 'missing': const <Object?>[]};
  String expand(String s) => s.replaceAll('{root}', root).replaceAll('{home}', Platform.environment['HOME'] ?? '');
  final cwd = recipe.cwd == null ? root : (p.isAbsolute(expand(recipe.cwd!)) ? expand(recipe.cwd!) : p.join(root, expand(recipe.cwd!)));
  if (!Directory(cwd).existsSync()) {
    return {
      'ok': false,
      'cwd': cwd,
      'cwdMissing': true,
      'missing': const <Object?>[],
      'message': 'The working directory of runner "${recipe.name}" does not exist: $cwd. Set `cwd:` of the runner in aib_mcp.local.yaml.',
    };
  }
  final branch = await _git(cwd, ['rev-parse', '--abbrev-ref', 'HEAD']);
  final missing = <Json>[];
  for (final file in scriptsOf(recipe)) {
    if (File(p.join(cwd, file)).existsSync()) continue;
    missing.add({'file': file, 'branches': await _branchesWith(cwd, file)});
  }
  String? message;
  if (missing.isNotEmpty) {
    final lines = [
      'Runner "${recipe.name}" runs scripts from $cwd${branch == null ? '' : ' (checked out: $branch)'} that are not there:',
      for (final m in missing) '  ${m['file']}${(m['branches'] as List).isEmpty ? '' : ' — on ${(m['branches'] as List).join(', ')}'}',
    ];
    final candidates = {for (final m in missing) ...(m['branches'] as List).cast<String>()};
    if (candidates.length == 1) {
      lines.add('Check that branch out in the app repository (git -C $cwd switch ${candidates.single}), then start the run again.');
    }
    message = lines.join('\n');
  }
  return {'ok': missing.isEmpty, 'cwd': cwd, 'branch': branch, 'missing': missing, 'message': ?message};
}

/// Script files named in a recipe's commands: tokens that end in a script
/// extension, with no placeholder and no option dash. `sh -c '…'` strings are
/// read word by word.
Set<String> scriptsOf(RunnerRecipe recipe) {
  final found = <String>{};
  final word = RegExp(r'''[^\s;&|"'()<>=]+''');
  for (final command in [recipe.prepare, recipe.command, recipe.cleanup]) {
    for (final part in command ?? const <String>[]) {
      for (final m in word.allMatches(part)) {
        final token = m[0]!;
        if (token.startsWith('-') || token.contains('{') || token.contains(r'$') || p.isAbsolute(token)) continue;
        if (RegExp(r'\.(dart|sh|py)$').hasMatch(token)) found.add(token.startsWith('./') ? token.substring(2) : token);
      }
    }
  }
  return found;
}

Future<String?> _git(String cwd, List<String> args) async {
  try {
    final r = await Process.run('git', ['-C', cwd, ...args]);
    return r.exitCode == 0 ? (r.stdout as String).trim() : null;
  } on ProcessException {
    return null;
  }
}

Future<List<String>> _branchesWith(String cwd, String file) async {
  final refs =
      (await _git(cwd, ['for-each-ref', '--format=%(refname:short)', 'refs/heads']))?.split('\n').where((s) => s.isNotEmpty).take(40) ?? const [];
  final out = <String>[];
  for (final ref in refs) {
    final hit = await _git(cwd, ['ls-tree', '--name-only', ref, '--', file]);
    if (hit != null && hit.isNotEmpty) out.add(ref);
  }
  return out;
}
