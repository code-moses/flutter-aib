import 'dart:io';

import 'package:aib_cli/aib_cli.dart';
import 'package:path/path.dart' as p;

/// Every path a tool takes, resolved under the checkout.
///
/// Symlinks are resolved before the check, so a link inside the checkout
/// that points out of it is refused like the path it points to. Writes are
/// allowed only under the configured writable directories.
final class PathSandbox {
  PathSandbox(String root, List<String> writable)
    : root = _real(p.normalize(p.absolute(root))),
      writable = [for (final w in writable) _real(p.normalize(p.join(p.absolute(root), w)))];

  final String root;
  final List<String> writable;

  /// [path] (relative to [root], or absolute) if it lies under [root].
  String read(String path) {
    final resolved = _resolve(path);
    if (!_within(resolved, root)) throw AibError('$path is outside the checkout');
    return resolved;
  }

  /// [path] if it lies under one of the [writable] directories.
  String write(String path) {
    final resolved = read(path);
    if (!writable.any((w) => _within(resolved, w))) {
      throw AibError('$path is not writable (writable: ${[for (final w in writable) relative(w)].join(', ')})');
    }
    return resolved;
  }

  /// [path] relative to [root], as tools report it.
  String relative(String path) => p.relative(path, from: root);

  String _resolve(String path) => _real(p.normalize(p.isAbsolute(path) ? path : p.join(root, path)));

  static bool _within(String path, String dir) => path == dir || p.isWithin(dir, path);

  /// The real path of [path]: symlinks resolved on its longest existing
  /// prefix, the rest appended as given.
  static String _real(String path) {
    var existing = path;
    final rest = <String>[];
    while (FileSystemEntity.typeSync(existing, followLinks: false) == FileSystemEntityType.notFound) {
      final parent = p.dirname(existing);
      if (parent == existing) return path;
      rest.insert(0, p.basename(existing));
      existing = parent;
    }
    return p.joinAll([File(existing).resolveSymbolicLinksSync(), ...rest]);
  }
}
