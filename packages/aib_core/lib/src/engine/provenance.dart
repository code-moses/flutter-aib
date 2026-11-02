import 'dart:io';
import 'dart:isolate';

import '../common/json.dart';

/// The revision of code that produced or scored a run: a git commit, or the
/// version of a package installed from a pub server.
final class SourceRevision {
  const SourceRevision({required this.revision, this.dirty = false, this.source});

  final String revision;

  /// Tracked files differ from [revision].
  final bool dirty;

  /// How it was found: `git`, `pub-cache` (a git dependency), `hosted` (a
  /// version from a pub server), or whoever passed it in.
  final String? source;

  String get label =>
      '${_isCommit(revision) && revision.length > 10 ? revision.substring(0, 10) : revision}'
      '${dirty ? '+dirty' : ''}';

  static final _commit = RegExp(r'^[0-9a-f]{7,40}$');
  static bool _isCommit(String revision) => _commit.hasMatch(revision);

  /// Same commit, or the same package version; dirtiness and source are
  /// ignored. Commits match on their common prefix (at least 7 characters).
  bool sameCommitAs(SourceRevision other) {
    if (!_isCommit(revision) || !_isCommit(other.revision)) return revision == other.revision;
    final n = revision.length < other.revision.length ? revision.length : other.revision.length;
    return revision.substring(0, n) == other.revision.substring(0, n);
  }

  JsonMap toJson() => {'revision': revision, 'dirty': dirty, if (source != null) 'source': source};

  factory SourceRevision.fromJson(JsonMap json) =>
      SourceRevision(revision: json['revision'] as String, dirty: json['dirty'] as bool? ?? false, source: json['source'] as String?);

  /// The checkout containing [directory], or null outside one.
  static SourceRevision? ofDirectory(String directory) {
    try {
      final head = Process.runSync('git', ['-C', directory, 'rev-parse', 'HEAD']);
      if (head.exitCode != 0) return null;
      final status = Process.runSync('git', ['-C', directory, 'status', '--porcelain', '--untracked-files=no']);
      return SourceRevision(
        revision: (head.stdout as String).trim(),
        dirty: status.exitCode == 0 && (status.stdout as String).trim().isNotEmpty,
        source: 'git',
      );
    } on ProcessException {
      return null;
    }
  }

  static final _pubCacheGit = RegExp(r'[/\\]git[/\\][^/\\]+-([0-9a-f]{40})[/\\]');

  /// Where [package] was loaded from. Null in a Flutter app, which cannot
  /// resolve package URIs — pass the revision in there.
  static Future<SourceRevision?> ofPackage(String package) async {
    final Uri? uri;
    try {
      uri = await Isolate.resolvePackageUri(Uri.parse('package:$package/'));
    } on UnsupportedError {
      return null;
    }
    if (uri == null || uri.scheme != 'file') return null;
    final path = uri.toFilePath();
    return ofPubCachePath(path) ?? (Directory(path).existsSync() ? ofDirectory(path) : null);
  }

  static final _pubCacheHosted = RegExp(r'[/\\]hosted[/\\][^/\\]+[/\\][a-z0-9_]+-(\d+\.\d+\.\d+[^/\\]*)[/\\]');

  /// A pub-cache git checkout is named after its commit; a package from a pub
  /// server (`hosted/<host>/<name>-<version>`) after its version.
  static SourceRevision? ofPubCachePath(String path) {
    final git = _pubCacheGit.firstMatch(path);
    if (git != null) return SourceRevision(revision: git.group(1)!, source: 'pub-cache');
    final hosted = _pubCacheHosted.firstMatch(path);
    return hosted == null ? null : SourceRevision(revision: hosted.group(1)!, source: 'hosted');
  }
}
