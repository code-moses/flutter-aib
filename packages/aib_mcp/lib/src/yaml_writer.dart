import 'dart:convert';

/// Block-style YAML for a JSON value, for the agent configs the server
/// derives. Strings that could read as anything but themselves are written
/// as JSON strings, which YAML reads back unchanged.
String toYaml(Map<String, Object?> value) {
  final buffer = StringBuffer();
  _map(buffer, value, 0);
  return buffer.toString();
}

void _map(StringBuffer out, Map<Object?, Object?> map, int indent) {
  final pad = ' ' * indent;
  for (final MapEntry(:key, :value) in map.entries) {
    out.write('$pad${_scalar('$key')}:');
    _value(out, value, indent);
  }
}

void _list(StringBuffer out, List<Object?> list, int indent) {
  final pad = ' ' * indent;
  for (final item in list) {
    if (item is Map && item.isNotEmpty) {
      // The first entry shares the dash's line; the rest align under it.
      final nested = StringBuffer();
      _map(nested, item, indent + 2);
      out.write('$pad- ${nested.toString().substring(indent + 2)}');
    } else if (item is List && item.isNotEmpty) {
      out.writeln('$pad-');
      _list(out, item, indent + 2);
    } else {
      out.writeln('$pad- ${_leaf(item)}');
    }
  }
}

void _value(StringBuffer out, Object? value, int indent) {
  if (value is Map && value.isNotEmpty) {
    out.writeln();
    _map(out, value, indent + 2);
  } else if (value is List && value.isNotEmpty) {
    out.writeln();
    _list(out, value, indent + 2);
  } else {
    out.writeln(' ${_leaf(value)}');
  }
}

String _leaf(Object? value) => switch (value) {
  null => 'null',
  Map() => '{}',
  List() => '[]',
  String() => _scalar(value),
  _ => '$value',
};

final _plain = RegExp(r'^[A-Za-z_./][A-Za-z0-9_./\-]*(?:[ :][A-Za-z0-9_./\-]+)*$');
const _reserved = {'true', 'false', 'yes', 'no', 'on', 'off', 'null', 'y', 'n', '~'};

String _scalar(String s) {
  final plain = _plain.hasMatch(s) && !s.contains(': ') && !_reserved.contains(s.toLowerCase()) && num.tryParse(s) == null;
  return plain ? s : jsonEncode(s);
}
