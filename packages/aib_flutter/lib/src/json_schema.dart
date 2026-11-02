import 'package:aib_core/ports.dart';
import 'package:json_schema/json_schema.dart';

/// Validates LLM-supplied parameters against the JSON schema an intent or a
/// catalog component published, returning one human-readable message per
/// violation. Backed by `package:json_schema` (draft 2020-12).
///
/// - Messages name the offending path as `$.row.Menge` or `$.ids[1]`, then what was wrong.
///   They are fed back to the model verbatim (`bad_params`).
/// - A whole-number double (`5.0`) satisfies `integer`: models emit it.
///
/// An empty schema accepts anything. A schema that is itself invalid is the
/// app's defect, so it validates nothing rather than blaming the call.
List<String> validateAgainstSchema(JsonMap value, JsonMap schema) {
  if (schema.isEmpty) return const [];
  final compiled = _compile(schema);
  if (compiled == null) return const [];
  final results = compiled.validate(_wholeNumbersAsInts(value));
  // The package reports a missing property twice and quotes the whole instance;
  // each violation is said once, at the property.
  return {for (final error in results.errors) _render(error)}.toList();
}

final _missing = RegExp(r'^required prop missing: (\S+) from ');

String _render(ValidationError error) {
  final missing = _missing.firstMatch(error.message);
  if (missing != null) {
    final parent = _path(error.instancePath);
    final name = missing.group(1)!;
    final path = parent.endsWith('.$name') ? parent : '$parent.$name';
    return '$path: required but missing';
  }
  return '${_path(error.instancePath)}: ${error.message}';
}

final _cache = <String, JsonSchema?>{};

JsonSchema? _compile(JsonMap schema) {
  final key = stableStringify(schema);
  return _cache.putIfAbsent(key, () {
    try {
      return JsonSchema.create(schema, schemaVersion: SchemaVersion.draft2020_12);
    } catch (_) {
      return null;
    }
  });
}

/// `/row/Menge` -> `$.row.Menge`, `/ids/1` -> `$.ids[1]`.
String _path(String pointer) {
  final buffer = StringBuffer(r'$');
  for (final segment in pointer.split('/').skip(1)) {
    final name = segment.replaceAll('~1', '/').replaceAll('~0', '~');
    if (int.tryParse(name) != null) {
      buffer.write('[$name]');
    } else {
      buffer.write('.$name');
    }
  }
  return buffer.toString();
}

Object? _wholeNumbersAsInts(Object? value) => switch (value) {
  final double number when number.isFinite && number == number.roundToDouble() => number.toInt(),
  Map() => {for (final entry in value.entries) '${entry.key}': _wholeNumbersAsInts(entry.value)},
  List() => [for (final item in value) _wholeNumbersAsInts(item)],
  _ => value,
};
