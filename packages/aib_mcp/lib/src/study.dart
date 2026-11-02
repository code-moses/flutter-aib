import 'dart:convert';
import 'dart:io';

import 'package:aib_cli/aib_cli.dart';
import 'package:aib_core/aib_core.dart';
import 'package:path/path.dart' as p;

/// A tuning study: `experiments/<name>/journal.jsonl`, one line per arm
/// derived, run started, comparison, replay and holdout score, each with the
/// hypothesis it served. A reader can only correct for selection noise if every
/// arm tried is written down.
final class Study {
  Study._(this.name, this.file);

  static const directory = 'experiments';
  static final _name = RegExp(r'^[a-z0-9][a-z0-9_.\-]*$');

  final String name;
  final File file;

  /// Opens [name] under [experimentsDir], creating it with [hypothesis] on
  /// first use; a reopened study keeps its journal.
  static Study open(String experimentsDir, String name, {String? hypothesis, DateTime? at}) {
    if (!_name.hasMatch(name)) throw AibError('"$name" is not a study name (lowercase letters, digits, _ . -)');
    final file = File(p.join(experimentsDir, name, 'journal.jsonl'));
    final study = Study._(name, file);
    if (!file.existsSync()) {
      if (hypothesis == null || hypothesis.trim().isEmpty) throw const AibError('a new study needs a hypothesis');
      file.parent.createSync(recursive: true);
      study.record('study', {'hypothesis': hypothesis}, at: at);
    } else {
      study.record('reopened', {'hypothesis': ?hypothesis}, at: at);
    }
    return study;
  }

  void record(String type, JsonMap data, {DateTime? at}) =>
      file.writeAsStringSync('${jsonEncode({'type': type, 'at': (at ?? DateTime.now()).toIso8601String(), ...data})}\n', mode: FileMode.append);

  List<JsonMap> entries() => [
    for (final line in file.readAsLinesSync())
      if (line.trim().isNotEmpty) asJsonMap(jsonDecode(line)),
  ];

  /// How many tries the study has made — what a reader needs to correct a
  /// best-of-N for the N.
  JsonMap summary() {
    final all = entries();
    int count(String type) => all.where((e) => e['type'] == type).length;
    return {
      'study': name,
      'hypothesis': all.firstWhere((e) => e['type'] == 'study', orElse: () => const {})['hypothesis'],
      'armsDerived': count('derive'),
      'arms': {
        for (final e in all)
          if (e['type'] == 'derive' || e['type'] == 'run') '${e['arm']}',
      }.toList(),
      'runsStarted': count('run'),
      'comparisons': count('compare'),
      'replays': count('replay'),
      'holdoutScores': count('holdout'),
      'journal': file.path,
    };
  }
}
