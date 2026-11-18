/// Held-out tasks kept out of a published suite: the suite keeps a stub
/// (`withheld: true`), the full block lives in git-ignored
/// `<suite>.private.yaml`. [mergeWithheld] restores the original text byte
/// for byte, so hashes do not change. Works on text: tasks are blocks starting
/// with `  - id: <id>` under a final `tasks:` key.
library;

/// The marker a stub carries in place of its expected results.
const withheldKey = 'withheld';

/// Keys of a withheld task that stay in the public suite.
const publicWithheldKeys = {'title', 'instruction', 'tags'};

final _taskStart = RegExp(r'^  - id:\s*(.+?)\s*$');
final _blockKey = RegExp(r'^    ([A-Za-z_][A-Za-z0-9_]*):');

/// One task block: [start] and [end] are line indices, [end] exclusive.
final class _Block {
  _Block(this.id, this.start, this.end);
  final String id;
  final int start;
  final int end;
}

String _unquote(String raw) {
  final s = raw.split(' #').first.trim();
  if (s.length >= 2 && (s.startsWith('"') && s.endsWith('"') || s.startsWith("'") && s.endsWith("'"))) {
    return s.substring(1, s.length - 1);
  }
  return s;
}

bool _isTrailer(String line) {
  final t = line.trim();
  return t.isEmpty || t.startsWith('#');
}

/// Task blocks of [lines], without trailing blank and comment lines.
List<_Block> _blocks(List<String> lines) {
  final starts = <(int, String)>[
    for (final (i, line) in lines.indexed)
      if (_taskStart.firstMatch(line) case final m?) (i, _unquote(m.group(1)!)),
  ];
  return [
    for (final (k, (start, id)) in starts.indexed)
      () {
        var end = k + 1 < starts.length ? starts[k + 1].$1 : lines.length;
        while (end > start + 1 && _isTrailer(lines[end - 1])) {
          end--;
        }
        return _Block(id, start, end);
      }(),
  ];
}

/// Lines such that [List.join] restores the text exactly.
List<String> _lines(String text) => text.split('\n');

/// The result of [splitWithheld].
final class WithheldSplit {
  const WithheldSplit({required this.public, required this.private, required this.withheld});

  /// The suite text with a stub in place of each withheld block.
  final String public;

  /// The private file: a header, then every withheld block verbatim.
  final String private;

  /// Ids that were withheld, in suite order.
  final List<String> withheld;
}

/// Replaces the blocks of [ids] with stubs and collects them into a private
/// file opened by [privateHeader]. Throws when an id is missing.
WithheldSplit splitWithheld(String original, Set<String> ids, {required String privateHeader, required String stubComment}) {
  final lines = _lines(original);
  final blocks = _blocks(lines);
  final missing = ids.difference({for (final b in blocks) b.id});
  if (missing.isNotEmpty) throw ArgumentError('not in the suite: ${missing.join(', ')}');

  final public = <String>[];
  final private = <String>[...privateHeader.trimRight().split('\n'), 'tasks:'];
  final withheld = <String>[];
  var cursor = 0;
  for (final block in blocks) {
    if (!ids.contains(block.id)) continue;
    public.addAll(lines.sublist(cursor, block.start));
    final body = lines.sublist(block.start, block.end);
    if (body.any((l) => _blockKey.firstMatch(l)?.group(1) == withheldKey)) {
      throw ArgumentError('${block.id} is already withheld');
    }
    // The stub: the id line, the marker, then each public key's lines.
    public
      ..add(body.first)
      ..add('    $withheldKey: true # $stubComment');
    String? key;
    for (final line in body.skip(1)) {
      final m = _blockKey.firstMatch(line);
      if (m != null) key = m.group(1);
      if (key != null && publicWithheldKeys.contains(key)) public.add(line);
    }
    private.addAll(body);
    withheld.add(block.id);
    cursor = block.end;
  }
  public.addAll(lines.sublist(cursor));
  return WithheldSplit(public: public.join('\n'), private: '${private.join('\n')}\n', withheld: withheld);
}

/// Ids of the stubs in [public]: blocks that carry `withheld: true`.
List<String> withheldStubs(String public) {
  final lines = _lines(public);
  return [
    for (final block in _blocks(lines))
      if (lines.sublist(block.start, block.end).any((l) => _blockKey.firstMatch(l)?.group(1) == withheldKey)) block.id,
  ];
}

/// Puts the blocks of [private] back in place of the stubs in [public]; also
/// returns mismatches (a stub without a block, a block without a stub).
(String, List<String>) mergeWithheld(String public, String private) {
  final privateLines = _lines(private);
  final privateBlocks = {for (final b in _blocks(privateLines)) b.id: privateLines.sublist(b.start, b.end)};
  final lines = _lines(public);
  final stubs = {
    for (final block in _blocks(lines))
      if (lines.sublist(block.start, block.end).any((l) => _blockKey.firstMatch(l)?.group(1) == withheldKey)) block.id: block,
  };
  final problems = [
    for (final id in stubs.keys)
      if (!privateBlocks.containsKey(id)) 'withheld task "$id" has no block in the private file',
    for (final id in privateBlocks.keys)
      if (!stubs.containsKey(id)) 'private block "$id" has no withheld stub in the suite',
  ];
  final out = <String>[];
  var cursor = 0;
  for (final stub in stubs.values) {
    final block = privateBlocks[stub.id];
    if (block == null) continue;
    out
      ..addAll(lines.sublist(cursor, stub.start))
      ..addAll(block);
    cursor = stub.end;
  }
  out.addAll(lines.sublist(cursor));
  return (out.join('\n'), problems);
}
