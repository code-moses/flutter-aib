import 'dart:convert';

import '../common/json.dart';
import '../engine/run_manifest.dart';
import '../evaluation/judge_provenance.dart';

/// One field that differs between two runs' manifests.
final class ManifestDifference {
  const ManifestDifference(this.path, this.a, this.b);

  /// Dotted path, e.g. `agents.hybrid.metadata.model`.
  final String path;
  final Object? a;
  final Object? b;
}

/// What the runs were: everything that changes a result, nothing that only
/// identifies a run (id, timestamps, platform strings, task order).
JsonMap comparabilityProjection(RunManifest m, {JudgeProvenance? judge}) => {
  'suite': {'name': m.suiteName, 'hash': m.suiteHash},
  'environment': {'id': m.environmentId, 'version': m.environmentVersion, 'metadata': m.environmentMetadata},
  'agents': {
    for (final entry in m.agents.entries) entry.key: {...entry.value}..remove('description'),
  },
  // Commit only: a dirty tree is not a different experiment by itself.
  'framework': m.revisions['framework']?.label.replaceAll('+dirty', ''),
  'models': m.extra[RunManifest.modelsKey],
  'pricing': m.pricing?.asOf,
  'repetitions': m.repetitions,
  'seed': m.seed,
  // `spend` and `evaluatedAt` are incidental: two identical runs judged on
  // different days differ in both, and `aib compare` must not refuse them.
  'judge': judge == null
      ? null
      : ({...judge.toJson()}
          ..remove('evaluatedAt')
          ..remove('spend')),
};

List<ManifestDifference> manifestDifferences(RunManifest a, RunManifest b, {JudgeProvenance? judgeA, JudgeProvenance? judgeB}) {
  final left = flattenJsonPaths(comparabilityProjection(a, judge: judgeA));
  final right = flattenJsonPaths(comparabilityProjection(b, judge: judgeB));
  return [
    for (final path in ({...left.keys, ...right.keys}.toList()..sort()))
      if (jsonEncode(left[path]) != jsonEncode(right[path])) ManifestDifference(path, left[path], right[path]),
  ];
}

/// Glob over dotted paths: `*` is one segment, `**` any number; a pattern
/// without a dot matches a final segment (`model` = `**.model`).
bool pathMatches(String path, String pattern) {
  final full = pattern.contains('.') ? pattern : '**.$pattern';
  final regex = full
      .split('.')
      .map(
        (s) => switch (s) {
          '**' => r'(?:[^.]+\.)*',
          '*' => r'[^.]+\.',
          _ => '${RegExp.escape(s)}\\.',
        },
      )
      .join();
  return RegExp('^$regex\$').hasMatch('$path.');
}

/// [node] as dotted path → leaf value, the paths [manifestDifferences]
/// reports and `--vary` globs name. An empty map is a leaf.
Map<String, Object?> flattenJsonPaths(Object? node, [String prefix = '']) {
  if (node is Map && node.isNotEmpty) {
    return {for (final entry in node.entries) ...flattenJsonPaths(entry.value, prefix.isEmpty ? '${entry.key}' : '$prefix.${entry.key}')};
  }
  return {prefix: node};
}

/// The identity table that heads a `RUN.md`. Built from
/// [comparabilityProjection], so the table and `aib compare`'s refusal read the
/// same fields.
String provenanceMarkdown(RunManifest manifest, {JudgeProvenance? judge, RunManifest? against, JudgeProvenance? againstJudge, String? againstName}) {
  final rows = flattenJsonPaths(comparabilityProjection(manifest, judge: judge))..removeWhere((_, value) => value == null);
  final buffer = StringBuffer()
    ..writeln('| field | value |')
    ..writeln('|---|---|');
  for (final entry in rows.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
    buffer.writeln('| `${entry.key}` | ${_cell(entry.value)} |');
  }
  if (against == null) return buffer.toString();

  final differences = manifestDifferences(manifest, against, judgeA: judge, judgeB: againstJudge);
  buffer
    ..writeln()
    ..writeln('### What moved against ${againstName ?? 'the other run'}')
    ..writeln();
  if (differences.isEmpty) {
    buffer.writeln('Nothing. Every field that decides comparability is equal.');
    return buffer.toString();
  }
  // A field only one manifest wrote is a changed recording, not a changed
  // experiment.
  final changed = differences.where((d) => d.a != null && d.b != null).toList();
  final unrecorded = differences.where((d) => d.a == null || d.b == null).toList();

  if (changed.isEmpty) {
    buffer.writeln('Nothing that both runs recorded.');
  } else {
    buffer
      ..writeln('| field | this run | ${againstName ?? 'other'} |')
      ..writeln('|---|---|---|');
    for (final difference in changed) {
      buffer.writeln('| `${difference.path}` | ${_cell(difference.a)} | ${_cell(difference.b)} |');
    }
  }
  if (unrecorded.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln(
        'Recorded by one run only, so they say nothing about the experiment: '
        '${unrecorded.map((d) => '`${d.path}`').join(', ')}.',
      );
  }
  buffer
    ..writeln()
    ..writeln(
      '`aib compare` refuses the pair unless each of the ${differences.length} '
      'differing field(s) is named by `--vary`.',
    );
  return buffer.toString();
}

String _cell(Object? value) {
  if (value == null) return '—';
  final text = value is String ? value : jsonEncode(value);
  return '`${text.length > 80 ? '${text.substring(0, 77)}…' : text}`';
}
