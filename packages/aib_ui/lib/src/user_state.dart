import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// What a person adds on top of runs — tags, notes, stars, aliases — and the
/// folders they opened. Kept in `~/.aib_ui/state.json`, never in a run
/// directory: results stay as the benchmark wrote them.
final class UserState {
  UserState._(this._file, this._recents, this._annotations);

  final File _file;
  final List<String> _recents;
  final Map<String, Map<String, Object?>> _annotations;

  factory UserState.open({String? home}) {
    final dir = home ?? Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;
    final file = File(p.join(dir, '.aib_ui', 'state.json'));
    var recents = <String>[];
    var annotations = <String, Map<String, Object?>>{};
    try {
      if (file.existsSync()) {
        final json = jsonDecode(file.readAsStringSync()) as Map;
        recents = [for (final r in json['recents'] as List? ?? const []) '$r'];
        annotations = {
          for (final e in (json['annotations'] as Map? ?? const {}).entries)
            '${e.key}': {for (final f in (e.value as Map).entries) '${f.key}': f.value},
        };
      }
    } on Object {
      // A damaged state file is not worth refusing to start for.
    }
    return UserState._(file, recents, annotations);
  }

  Map<String, Object?> annotation(String dir) => _annotations[dir] ?? const {};

  void annotate(String dir, {List<String>? tags, String? note, bool? starred, String? alias}) {
    final a = Map<String, Object?>.of(_annotations[dir] ?? const {});
    if (tags != null) a['tags'] = tags.map((t) => t.trim()).where((t) => t.isNotEmpty).toSet().toList();
    if (note != null) a['note'] = note;
    if (starred != null) a['starred'] = starred;
    if (alias != null) a['alias'] = alias;
    final empty =
        (a['tags'] as List?)?.isEmpty != false &&
        ((a['note'] as String?) ?? '').isEmpty &&
        a['starred'] != true &&
        ((a['alias'] as String?) ?? '').isEmpty;
    if (empty) {
      _annotations.remove(dir);
    } else {
      _annotations[dir] = a;
    }
    _save();
  }

  void addRecent(String path) {
    _recents
      ..remove(path)
      ..insert(0, path);
    if (_recents.length > 12) _recents.removeRange(12, _recents.length);
    _save();
  }

  void removeRecent(String path) {
    _recents.remove(path);
    _save();
  }

  Map<String, Object?> toJson() => {'recents': _recents, 'tagCount': _annotations.length};

  void _save() {
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({'recents': _recents, 'annotations': _annotations}));
    } on FileSystemException {
      // Read-only home: annotations then last for this session only.
    }
  }
}
