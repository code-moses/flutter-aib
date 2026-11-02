import 'dart:convert';

import 'package:aib_core/aib_core.dart';

/// RFC 7386 JSON merge patch: `null` removes a key, a map merges, anything
/// else replaces.
Object? mergePatch(Object? target, Object? patch) {
  if (patch is! Map) return patch;
  final result = <String, Object?>{if (target is Map) ...asJsonMap(target)};
  for (final MapEntry(:key, :value) in patch.entries) {
    if (value == null) {
      result.remove('$key');
    } else {
      result['$key'] = mergePatch(result['$key'], value);
    }
  }
  return result;
}

/// One config path that differs between two arms.
final class ConfigChange {
  const ConfigChange(this.path, this.before, this.after);

  /// Dotted path into the config, e.g. `preparation.topK`.
  final String path;

  /// Absent (null) when the path was added.
  final Object? before;

  /// Absent (null) when the path was removed.
  final Object? after;

  JsonMap toJson() => {'path': path, 'before': before, 'after': after};

  @override
  String toString() => '$path: ${_short(before)} -> ${_short(after)}';

  static String _short(Object? value) {
    final text = value == null ? '(absent)' : jsonEncode(value);
    return text.length <= 60 ? text : '${text.substring(0, 57)}...';
  }
}

/// What changed from [a] to [b], by path. Maps present on both sides are
/// compared key by key; anything else — a list, a scalar, a block present
/// on one side only — is one change. So adding a whole `decisions:` block
/// is one change, and moving `topK` and `minScore` is two.
List<ConfigChange> configChanges(Object? a, Object? b, [String prefix = '']) {
  if (a is Map && b is Map) {
    final keys = {...a.keys.map((k) => '$k'), ...b.keys.map((k) => '$k')}.toList()..sort();
    return [for (final key in keys) ...configChanges(a[key], b[key], prefix.isEmpty ? key : '$prefix.$key')];
  }
  return jsonEncode(a) == jsonEncode(b) ? const [] : [ConfigChange(prefix, a, b)];
}

/// The header a derived arm's YAML opens with: the same shape the
/// hand-written arms use ("One change against hybrid_union.yaml: …").
String derivedHeader({
  required String base,
  required String agent,
  required String hypothesis,
  required List<ConfigChange> changes,
  required String? agentConfigHash,
  required DateTime at,
}) {
  final lines = [
    'Derived from $base.yaml by aib_mcp on ${at.toIso8601String().substring(0, 10)} (agent: $agent).',
    '',
    'Hypothesis: ${hypothesis.trim()}',
    '',
    '${changes.length == 1 ? 'One change' : '${changes.length} changes'} against $base.yaml:',
    for (final change in changes) '  $change',
    if (agentConfigHash != null) ...['', 'agentConfigHash: $agentConfigHash'],
  ];
  return [for (final line in lines.expand(_wrap)) line.isEmpty ? '#' : '# $line'].join('\n');
}

Iterable<String> _wrap(String line) sync* {
  const width = 76;
  var rest = line;
  final indent = RegExp(r'^\s*').stringMatch(line)!;
  while (rest.length > width) {
    final cut = rest.lastIndexOf(' ', width);
    if (cut <= indent.length) break;
    yield rest.substring(0, cut);
    rest = '$indent${rest.substring(cut + 1)}';
  }
  yield rest;
}
