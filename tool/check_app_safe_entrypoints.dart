// CI guard: the entry points an app ships must not reach a VM-only library
// through their import/export closure. One umbrella import breaks it silently.
// Workspace files are walked; third-party packages are only listed.
//
// Run: fvm dart tool/check_app_safe_entrypoints.dart
import 'dart:io';

/// Entry points that must stay app-safe, and why.
const entryPoints = <String, String>{
  'packages/aib_core/lib/ports.dart':
      'the agent-facing core surface (Envelope, TaskSpec, ports)',
  'packages/aib_core/lib/field.dart':
      'the field-trace observers the shipped assistant installs',
  'packages/aib_core/lib/catalog.dart': 'the catalogue lint an app runs',
  'packages/aib_core/lib/transport.dart':
      'cancellation, retry policy and error classification every client shares',
  'packages/aib_jev/lib/aib_jev.dart':
      'the decision-model package an app takes on its own (clients, template, backends)',
  'packages/aib_agents/lib/agents.dart':
      'the agent surface an app ships (ToolLoopAgent, HybridAgent, LlmClient)',
  'packages/aib_flutter/lib/aib_flutter.dart':
      'the environment bridges the app registers in lib/',
};

/// VM-only libraries. A hit on any of these fails the check.
const forbiddenLibraries = <String>{
  'dart:io',
  'dart:mirrors',
  'dart:isolate',
  'dart:cli',
  'dart:developer',
};

final _directive = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

void main() {
  final repoRoot = Directory.current.path;
  var failed = false;

  for (final entry in entryPoints.entries) {
    final path = entry.key;
    if (!File(path).existsSync()) {
      stderr.writeln('FAIL: entry point $path does not exist.');
      failed = true;
      continue;
    }
    final visited = <String>{};
    final external = <String>{};
    final violations = <String, List<String>>{}; // forbidden lib -> via files
    _walk(path, repoRoot, visited, external, violations);

    if (violations.isEmpty) {
      print('OK:   $path — ${visited.length} files, no VM-only imports');
      print('      (${entry.value})');
      if (external.isNotEmpty) {
        final sorted = external.toList()..sort();
        print('      third-party reached: ${sorted.join(', ')}');
      }
    } else {
      failed = true;
      stderr.writeln('FAIL: $path reaches VM-only libraries.');
      stderr.writeln('      This entry point is ${entry.value};');
      stderr.writeln('      an application depends on it and must not.');
      for (final violation in violations.entries) {
        for (final via in violation.value) {
          stderr.writeln('      ${violation.key}  <-  $via');
        }
      }
    }
  }

  if (failed) {
    stderr.writeln('');
    stderr.writeln(
      'Fix by moving the platform-dependent code behind a callback or port '
      '(see FixtureLoader in aib_flutter), or by keeping the offending file '
      'out of the narrow entry point and exporting it from the harness '
      'entry point instead (see aib_agents.dart).',
    );
    exit(1);
  }
  print('');
  print('All app-safe entry points are free of VM-only libraries.');
}

void _walk(
  String path,
  String repoRoot,
  Set<String> visited,
  Set<String> external,
  Map<String, List<String>> violations,
) {
  final normalized = File(path).absolute.path;
  if (!visited.add(normalized)) return;
  final file = File(path);
  if (!file.existsSync()) return;

  for (final match in _directive.allMatches(file.readAsStringSync())) {
    final uri = match.group(1)!;
    if (forbiddenLibraries.contains(uri)) {
      violations
          .putIfAbsent(uri, () => [])
          .add(path.replaceFirst('$repoRoot/', ''));
      continue;
    }
    if (uri.startsWith('dart:')) continue;

    final resolved = _resolve(uri, path);
    if (resolved == null) {
      external.add(uri.split('/').first.replaceFirst('package:', ''));
      continue;
    }
    _walk(resolved, repoRoot, visited, external, violations);
  }
}

/// Resolves an import URI to a file inside this workspace, or null when it
/// points at a third-party package.
String? _resolve(String uri, String fromFile) {
  if (uri.startsWith('package:')) {
    final rest = uri.substring('package:'.length);
    final slash = rest.indexOf('/');
    if (slash < 0) return null;
    final package = rest.substring(0, slash);
    final candidate = 'packages/$package/lib/${rest.substring(slash + 1)}';
    return File(candidate).existsSync() ? candidate : null;
  }
  if (uri.contains(':')) return null; // dart:, or something exotic
  final dir = File(fromFile).parent.path;
  final candidate = File('$dir/$uri').absolute.path;
  return File(candidate).existsSync()
      ? candidate.replaceFirst('${Directory.current.path}/', '')
      : null;
}
