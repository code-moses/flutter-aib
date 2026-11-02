import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'run_reader.dart' show Json;

/// OTLP/HTTP trace export, received. A run started with `--otel <endpoint>`
/// (or from the UI's Launch page) posts batches of spans to this server; they
/// are decoded here — protobuf by hand, JSON as it comes — and kept as plain
/// maps the front end reads.
///
/// A span: `traceId`, `spanId`, `parentId`, `name`, `kind`, `startUs`, `endUs`
/// (microseconds since the epoch: nanoseconds do not survive a JavaScript
/// number), `attrs`, `events`, `status {code, message}`, `service`.
List<Json> decodeOtlp(List<int> body, {required bool json}) {
  if (json) return _fromJson(jsonDecode(utf8.decode(body)));
  final out = <Json>[];
  final request = _Reader(Uint8List.fromList(body));
  while (!request.done) {
    final (field, wire) = request.tag();
    if (field == 1 && wire == 2) {
      _resourceSpans(request.bytes(), out);
    } else {
      request.skip(wire);
    }
  }
  return out;
}

void _resourceSpans(_Reader r, List<Json> out) {
  var service = '';
  final scopes = <_Reader>[];
  while (!r.done) {
    final (field, wire) = r.tag();
    if (field == 1 && wire == 2) {
      final resource = r.bytes();
      while (!resource.done) {
        final (f, w) = resource.tag();
        if (f == 1 && w == 2) {
          final kv = _keyValue(resource.bytes());
          if (kv.$1 == 'service.name') service = '${kv.$2}';
        } else {
          resource.skip(w);
        }
      }
    } else if (field == 2 && wire == 2) {
      scopes.add(r.bytes());
    } else {
      r.skip(wire);
    }
  }
  for (final scope in scopes) {
    while (!scope.done) {
      final (field, wire) = scope.tag();
      if (field == 2 && wire == 2) {
        out.add(_span(scope.bytes(), service));
      } else {
        scope.skip(wire);
      }
    }
  }
}

Json _span(_Reader r, String service) {
  String hex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  var traceId = '', spanId = '', parentId = '', name = '';
  var kind = 0, start = 0, end = 0;
  final attrs = <String, Object?>{};
  final events = <Json>[];
  var statusCode = 0;
  var statusMessage = '';
  while (!r.done) {
    final (field, wire) = r.tag();
    switch ((field, wire)) {
      case (1, 2):
        traceId = hex(r.bytes().all);
      case (2, 2):
        spanId = hex(r.bytes().all);
      case (4, 2):
        parentId = hex(r.bytes().all);
      case (5, 2):
        name = r.string();
      case (6, 0):
        kind = r.varint();
      case (7, 1):
        start = r.fixed64();
      case (8, 1):
        end = r.fixed64();
      case (9, 2):
        final kv = _keyValue(r.bytes());
        attrs[kv.$1] = kv.$2;
      case (11, 2):
        final e = r.bytes();
        var t = 0;
        var n = '';
        final ea = <String, Object?>{};
        while (!e.done) {
          final (f, w) = e.tag();
          if (f == 1 && w == 1) {
            t = e.fixed64();
          } else if (f == 2 && w == 2) {
            n = e.string();
          } else if (f == 3 && w == 2) {
            final kv = _keyValue(e.bytes());
            ea[kv.$1] = kv.$2;
          } else {
            e.skip(w);
          }
        }
        events.add({'name': n, 'tUs': t ~/ 1000, 'attrs': ea});
      case (15, 2):
        final s = r.bytes();
        while (!s.done) {
          final (f, w) = s.tag();
          if (f == 2 && w == 2) {
            statusMessage = s.string();
          } else if (f == 3 && w == 0) {
            statusCode = s.varint();
          } else {
            s.skip(w);
          }
        }
      default:
        r.skip(wire);
    }
  }
  return {
    'traceId': traceId,
    'spanId': spanId,
    'parentId': parentId.isEmpty || RegExp(r'^0+$').hasMatch(parentId) ? null : parentId,
    'name': name,
    'kind': kind,
    'startUs': start ~/ 1000,
    'endUs': end ~/ 1000,
    'attrs': attrs,
    'events': events,
    'status': {'code': statusCode, 'message': statusMessage},
    'service': service,
  };
}

(String, Object?) _keyValue(_Reader r) {
  var key = '';
  Object? value;
  while (!r.done) {
    final (field, wire) = r.tag();
    if (field == 1 && wire == 2) {
      key = r.string();
    } else if (field == 2 && wire == 2) {
      value = _anyValue(r.bytes());
    } else {
      r.skip(wire);
    }
  }
  return (key, value);
}

Object? _anyValue(_Reader r) {
  Object? value;
  while (!r.done) {
    final (field, wire) = r.tag();
    switch ((field, wire)) {
      case (1, 2):
        value = r.string();
      case (2, 0):
        value = r.varint() != 0;
      case (3, 0):
        value = r.varint();
      case (4, 1):
        value = r.double64();
      case (5, 2):
        final a = r.bytes();
        final list = <Object?>[];
        while (!a.done) {
          final (f, w) = a.tag();
          if (f == 1 && w == 2) {
            list.add(_anyValue(a.bytes()));
          } else {
            a.skip(w);
          }
        }
        value = list;
      case (6, 2):
        final a = r.bytes();
        final map = <String, Object?>{};
        while (!a.done) {
          final (f, w) = a.tag();
          if (f == 1 && w == 2) {
            final kv = _keyValue(a.bytes());
            map[kv.$1] = kv.$2;
          } else {
            a.skip(w);
          }
        }
        value = map;
      case (7, 2):
        value = base64.encode(r.bytes().all);
      default:
        r.skip(wire);
    }
  }
  return value;
}

/// Minimal protobuf wire reader: varint, 64-bit, length-delimited, 32-bit.
final class _Reader {
  _Reader(this._b, [this._i = 0, int? end]) : _end = end ?? _b.length;
  final Uint8List _b;
  int _i;
  final int _end;

  bool get done => _i >= _end;
  Uint8List get all => Uint8List.sublistView(_b, _i, _end);

  (int, int) tag() {
    final t = varint();
    return (t >> 3, t & 7);
  }

  int varint() {
    var result = 0, shift = 0;
    while (true) {
      if (_i >= _end) throw const FormatException('truncated protobuf varint');
      final byte = _b[_i++];
      if (shift < 64) result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
    }
  }

  int fixed64() {
    if (_i + 8 > _end) throw const FormatException('truncated protobuf fixed64');
    final v = ByteData.sublistView(_b, _i, _i + 8).getUint64(0, Endian.little);
    _i += 8;
    return v;
  }

  double double64() {
    if (_i + 8 > _end) throw const FormatException('truncated protobuf double');
    final v = ByteData.sublistView(_b, _i, _i + 8).getFloat64(0, Endian.little);
    _i += 8;
    return v;
  }

  _Reader bytes() {
    final n = varint();
    if (n < 0 || _i + n > _end) throw const FormatException('truncated protobuf field');
    final r = _Reader(_b, _i, _i + n);
    _i += n;
    return r;
  }

  String string() => utf8.decode(bytes().all, allowMalformed: true);

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        _i += 8;
      case 2:
        bytes();
      case 5:
        _i += 4;
      default:
        throw FormatException('unsupported protobuf wire type $wire');
    }
  }
}

// OTLP/JSON

List<Json> _fromJson(Object? doc) {
  final out = <Json>[];
  if (doc is! Map) return out;
  for (final rs in (doc['resourceSpans'] as List? ?? const [])) {
    final resource = (rs as Map)['resource'];
    final service = '${_jsonAttrs(resource is Map ? resource['attributes'] : null)['service.name'] ?? ''}';
    for (final ss in (rs['scopeSpans'] as List? ?? rs['instrumentationLibrarySpans'] as List? ?? const [])) {
      for (final s in ((ss as Map)['spans'] as List? ?? const [])) {
        final m = s as Map;
        final parent = '${m['parentSpanId'] ?? ''}';
        out.add({
          'traceId': '${m['traceId']}',
          'spanId': '${m['spanId']}',
          'parentId': parent.isEmpty || RegExp(r'^0+$').hasMatch(parent) ? null : parent,
          'name': '${m['name']}',
          'kind': m['kind'] is num ? m['kind'] : 0,
          'startUs': (BigInt.parse('${m['startTimeUnixNano'] ?? 0}') ~/ BigInt.from(1000)).toInt(),
          'endUs': (BigInt.parse('${m['endTimeUnixNano'] ?? 0}') ~/ BigInt.from(1000)).toInt(),
          'attrs': _jsonAttrs(m['attributes']),
          'events': [
            for (final e in (m['events'] as List? ?? const []))
              {
                'name': '${(e as Map)['name']}',
                'tUs': (BigInt.parse('${e['timeUnixNano'] ?? 0}') ~/ BigInt.from(1000)).toInt(),
                'attrs': _jsonAttrs(e['attributes']),
              },
          ],
          'status': {
            'code': switch (m['status']) {
              {'code': final num code} => code,
              _ => 0,
            },
            'message': '${(m['status'] as Map?)?['message'] ?? ''}',
          },
          'service': service,
        });
      }
    }
  }
  return out;
}

Map<String, Object?> _jsonAttrs(Object? list) => {for (final a in (list as List? ?? const [])) '${(a as Map)['key']}': _jsonValue(a['value'])};

Object? _jsonValue(Object? v) => switch (v) {
  {'stringValue': final value} => value,
  {'boolValue': final value} => value,
  {'intValue': final value} => int.tryParse('$value') ?? value,
  {'doubleValue': final value} => value,
  {'arrayValue': final Map array} => [for (final x in array['values'] as List? ?? const []) _jsonValue(x)],
  {'kvlistValue': final Map list} => _jsonAttrs(list['values']),
  _ => null,
};

/// Received spans, grouped by trace. Spans arrive as they end, so a trace
/// whose root (`aib.episode`) has not arrived is still running.
final class OtelStore {
  OtelStore({Directory? dir, this.maxTraces = 3000}) : _file = dir == null ? null : File(p.join(dir.path, 'spans.jsonl')) {
    _load();
  }

  final File? _file;
  final int maxTraces;
  final _traces = <String, List<Json>>{};
  final _first = <String, DateTime>{};
  int batches = 0, spans = 0;
  DateTime? lastAt;

  static const _keepBytes = 48 * 1024 * 1024;

  void _load() {
    final f = _file;
    if (f == null || !f.existsSync()) return;
    try {
      if (f.lengthSync() > _keepBytes) {
        final lines = f.readAsLinesSync();
        var size = 0;
        var from = lines.length;
        while (from > 0 && size < _keepBytes ~/ 2) {
          size += lines[--from].length + 1;
        }
        f.writeAsStringSync('${lines.sublist(from).join('\n')}\n');
      }
      for (final line in f.readAsLinesSync()) {
        if (line.isEmpty) continue;
        try {
          _add(Map<String, Object?>.from(jsonDecode(line) as Map), DateTime.fromMicrosecondsSinceEpoch(0));
        } on Object {
          continue;
        }
      }
    } on FileSystemException {
      // An unreadable store is an empty one.
    }
  }

  void ingest(List<Json> batch) {
    if (batch.isEmpty) return;
    batches++;
    lastAt = DateTime.now();
    for (final s in batch) {
      _add(s, lastAt!);
    }
    final f = _file;
    if (f != null) {
      try {
        f.parent.createSync(recursive: true);
        f.writeAsStringSync('${batch.map(jsonEncode).join('\n')}\n', mode: FileMode.append);
      } on FileSystemException {
        // Memory only from here on.
      }
    }
  }

  void _add(Json span, DateTime at) {
    final id = '${span['traceId']}';
    (_traces[id] ??= []).add(span);
    _first[id] ??= at;
    spans++;
    if (_traces.length > maxTraces) {
      final oldest = _first.entries.reduce((a, b) => a.value.isBefore(b.value) ? a : b).key;
      spans -= _traces[oldest]!.length;
      _traces.remove(oldest);
      _first.remove(oldest);
    }
  }

  void clear() {
    _traces.clear();
    _first.clear();
    spans = 0;
    final f = _file;
    if (f != null && f.existsSync()) f.writeAsStringSync('');
  }

  int get traceCount => _traces.length;

  List<Json>? trace(String id) => _traces[id];

  Json? summary(String id) {
    final list = _traces[id];
    return list == null ? null : _summarize(id, list);
  }

  List<Json> summaries({String? runId, String? q}) {
    final all = [for (final e in _traces.entries) _summarize(e.key, e.value)];
    var rows = runId == null ? all : all.where((s) => s['runId'] == runId).toList();
    if (q != null && q.isNotEmpty) {
      final needle = q.toLowerCase();
      rows = rows.where((s) => '${s['episodeId']} ${s['taskId']} ${s['runId']} ${s['agent']}'.toLowerCase().contains(needle)).toList();
    }
    rows.sort((a, b) => (b['startUs'] as int).compareTo(a['startUs'] as int));
    return rows;
  }

  /// The trace of one episode, by the attributes the exporter puts on it.
  String? idFor(String runId, String episodeId) {
    for (final e in _traces.entries) {
      for (final s in e.value) {
        final a = s['attrs'] as Map;
        if (s['name'] == 'aib.episode' && a['aib.episode_id'] == episodeId && a['aib.run_id'] == runId) return e.key;
      }
    }
    return null;
  }

  static Json _summarize(String id, List<Json> list) {
    Json? root;
    for (final s in list) {
      if (s['parentId'] == null && (root == null || s['name'] == 'aib.episode')) root = s;
    }
    final a = (root?['attrs'] as Map?) ?? const {};
    var start = 1 << 62, end = 0, tin = 0, tout = 0, errors = 0, decisions = 0, tools = 0;
    for (final s in list) {
      start = start < (s['startUs'] as int) ? start : s['startUs'] as int;
      end = end > (s['endUs'] as int) ? end : s['endUs'] as int;
      if ((s['status'] as Map)['code'] == 2) errors++;
      final sa = s['attrs'] as Map;
      if (s['name'] == 'invoke_agent') {
        decisions++;
        tin += (sa['gen_ai.usage.input_tokens'] as num?)?.toInt() ?? 0;
        tout += (sa['gen_ai.usage.output_tokens'] as num?)?.toInt() ?? 0;
      }
      if (s['name'] == 'execute_tool') tools++;
    }
    return {
      'traceId': id,
      'rootName': root?['name'],
      'live': root == null || root['name'] != 'aib.episode',
      'runId': a['aib.run_id'],
      'episodeId': a['aib.episode_id'],
      'taskId': a['aib.task_id'],
      'agent': a['gen_ai.agent.name'],
      'repetition': a['aib.repetition'],
      'reason': a['aib.termination_reason'],
      'wallClockMs': a['aib.wall_clock_ms'],
      'startUs': start,
      'durationUs': end - start,
      'spans': list.length,
      'decisions': decisions,
      'tools': tools,
      'tokensIn': tin,
      'tokensOut': tout,
      'errors': errors,
      'service': root?['service'] ?? list.first['service'],
      'semconvAsOf': a['aib.semconv_as_of'],
    };
  }
}
