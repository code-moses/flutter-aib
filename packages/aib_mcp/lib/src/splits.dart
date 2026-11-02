import 'dart:convert';
import 'dart:io';

import 'package:aib_core/aib_core.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'config.dart';

/// A suite's holdout: the tasks a tuning agent never sees, runs or scores.
///
/// Kept in `suites/splits/<suite>.yaml` rather than as tags in the suite, so
/// the suite hash — and every comparison with an earlier run — does not
/// move, and listed by task id, so the holdout does not move when a task is
/// added.
final class SuiteSplit {
  const SuiteSplit({required this.suite, required this.holdout});

  /// Where splits live unless `aib_mcp.yaml` says otherwise.
  static const directory = 'suites/splits';

  final String suite;
  final Set<String> holdout;

  /// The tuning split of [tasks]: everything not held out.
  Set<String> tune(Iterable<String> tasks) => {
    for (final task in tasks)
      if (!holdout.contains(task)) task,
  };

  /// `<dir>/<suite>.yaml`, [dir] relative to [root] (default
  /// [directory]); null when the suite has no split.
  static SuiteSplit? load(String root, String suite, {String dir = directory}) {
    final file = File(p.join(root, dir, '$suite.yaml'));
    if (!file.existsSync()) return null;
    final json = asJsonMap(yamlToJson(loadYaml(file.readAsStringSync())));
    return SuiteSplit(suite: json['suite'] as String? ?? suite, holdout: {for (final id in json['holdout'] as List? ?? const []) '$id'});
  }

  /// A seeded holdout of [share] of [tasks]: the tasks whose
  /// `sha256("<seed>:<id>")` sorts first. Reproducible from the ids alone,
  /// and a task added later does not displace one already held out unless
  /// it sorts before it.
  static List<String> seeded(Iterable<String> tasks, {double share = 0.3, String seed = 'aib-split-v1'}) {
    final ids = tasks.toList();
    final n = (ids.length * share).round().clamp(ids.isEmpty ? 0 : 1, ids.length);
    String key(String id) => sha256.convert(utf8.encode('$seed:$id')).toString();
    return (ids..sort((a, b) => key(a).compareTo(key(b)))).take(n).toList()..sort();
  }
}
