import 'dart:convert';

import 'package:crypto/crypto.dart';

/// JSON object as used throughout the framework. Payloads are opaque to the
/// core (ADR 0002); this alias is the only shape the core assumes.
typedef JsonMap = Map<String, Object?>;

/// Casts a decoded JSON value to a [JsonMap] (deep-copying nested structures
/// is not needed for read access; use [deepCopyJson] when mutating).
JsonMap asJsonMap(Object? value) {
  if (value == null) return <String, Object?>{};
  return (value as Map).map((k, v) => MapEntry(k as String, v));
}

/// UTF-8 size of the JSON serialization — used as payload-size proxy metric.
int jsonSizeBytes(Object? value) => utf8.encode(jsonEncode(value)).length;

/// Deep copy of a JSON-like structure.
Object? deepCopyJson(Object? value) => switch (value) {
  Map() => value.map((k, v) => MapEntry(k as String, deepCopyJson(v))),
  List() => value.map(deepCopyJson).toList(),
  _ => value,
};

/// Deep structural equality for JSON-like values.
bool jsonEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !jsonEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b;
  return a == b;
}

/// Canonical JSON serialization: map keys sorted recursively. Basis for
/// state fingerprints and config hashes (reproducibility, spec §5.3).
String stableStringify(Object? value) => jsonEncode(_sortJson(value));

Object? _sortJson(Object? value) => switch (value) {
  Map() => Map<String, Object?>.fromEntries(
    (value.entries.toList()..sort((a, b) => (a.key as String).compareTo(b.key as String))).map((e) => MapEntry(e.key as String, _sortJson(e.value))),
  ),
  List() => value.map(_sortJson).toList(),
  _ => value,
};

/// SHA-256 hex digest of the canonical serialization of [value].
String jsonFingerprint(Object? value) => sha256.convert(utf8.encode(stableStringify(value))).toString();

/// SHA-256 hex digest of a raw string (e.g. suite file contents).
String stringFingerprint(String content) => sha256.convert(utf8.encode(content)).toString();

/// One CSV cell (RFC 4180): quoted when it contains a comma, quote or line
/// break, with quotes doubled. Null is an empty cell.
String csvCell(Object? value) {
  final text = value?.toString() ?? '';
  return text.contains(RegExp('[",\r\n]')) ? '"${text.replaceAll('"', '""')}"' : text;
}
