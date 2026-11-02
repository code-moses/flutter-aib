import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aib_ui/aib_ui.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// A protobuf writer just big enough to produce what an OTLP exporter sends.
List<int> varint(int v) {
  final out = <int>[];
  var x = v;
  while (x > 0x7f) {
    out.add((x & 0x7f) | 0x80);
    x >>= 7;
  }
  out.add(x);
  return out;
}

List<int> field(int n, int wire, List<int> payload) => [...varint(n << 3 | wire), ...payload];
List<int> lenField(int n, List<int> bytes) => field(n, 2, [...varint(bytes.length), ...bytes]);
List<int> str(int n, String s) => lenField(n, utf8.encode(s));
List<int> fixed64(int n, int v) => field(n, 1, (ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List());

List<int> kvString(String k, String v) => [...str(1, k), ...lenField(2, str(1, v))];
List<int> kvInt(String k, int v) => [...str(1, k), ...lenField(2, field(3, 0, varint(v)))];
List<int> kvBool(String k, bool v) => [...str(1, k), ...lenField(2, field(2, 0, varint(v ? 1 : 0)))];

List<int> span({
  required List<int> trace,
  required List<int> id,
  List<int>? parent,
  required String name,
  required int start,
  required int end,
  List<List<int>> attrs = const [],
  int status = 0,
}) => [
  ...lenField(1, trace),
  ...lenField(2, id),
  if (parent != null) ...lenField(4, parent),
  ...str(5, name),
  ...field(6, 0, varint(1)),
  ...fixed64(7, start),
  ...fixed64(8, end),
  for (final a in attrs) ...lenField(9, a),
  if (status != 0) ...lenField(15, [...str(2, 'boom'), ...field(3, 0, varint(status))]),
];

List<int> request(List<List<int>> spans) {
  final scope = [for (final s in spans) ...lenField(2, s)];
  final resource = lenField(1, lenField(1, kvString('service.name', 'aib')));
  return lenField(1, [...resource, ...lenField(2, scope)]);
}

final trace = List<int>.generate(16, (i) => i + 1);
List<int> sid(int n) => List<int>.filled(8, n);
const t0 = 1790000000000000000; // ns

List<int> episode() => request([
  span(
    trace: trace,
    id: sid(1),
    name: 'aib.episode',
    start: t0,
    end: t0 + 3000000000,
    attrs: [
      kvString('aib.run_id', 'run-1'),
      kvString('aib.episode_id', 'task.a__agent__rep1'),
      kvString('aib.task_id', 'task.a'),
      kvString('gen_ai.agent.name', 'agent'),
      kvString('aib.termination_reason', 'done'),
      kvInt('aib.wall_clock_ms', 3000),
    ],
  ),
  span(
    trace: trace,
    id: sid(2),
    parent: sid(1),
    name: 'invoke_agent',
    start: t0 + 1000,
    end: t0 + 2000000000,
    attrs: [kvInt('gen_ai.usage.input_tokens', 1200), kvInt('gen_ai.usage.output_tokens', 30), kvBool('aib.unfinished', false)],
  ),
  span(
    trace: trace,
    id: sid(3),
    parent: sid(2),
    name: 'execute_tool',
    start: t0 + 1500000000,
    end: t0 + 1900000000,
    status: 2,
    attrs: [kvString('gen_ai.tool.name', 'todo.open')],
  ),
]);

void main() {
  test('a protobuf export decodes to spans with ids, attributes, microsecond times and status', () {
    final spans = decodeOtlp(episode(), json: false);
    expect(spans, hasLength(3));
    expect(spans[0]['name'], 'aib.episode');
    expect(spans[0]['parentId'], isNull);
    expect(spans[0]['traceId'], '0102030405060708090a0b0c0d0e0f10');
    expect(spans[0]['startUs'], t0 ~/ 1000);
    expect((spans[0]['endUs'] as int) - (spans[0]['startUs'] as int), 3000000);
    expect(spans[0]['service'], 'aib');
    expect((spans[0]['attrs'] as Map)['aib.wall_clock_ms'], 3000);
    expect(spans[1]['parentId'], '0101010101010101');
    expect((spans[1]['attrs'] as Map)['aib.unfinished'], false);
    expect((spans[2]['status'] as Map), {'code': 2, 'message': 'boom'});
  });

  test('an OTLP/JSON export decodes the same way', () {
    final doc = {
      'resourceSpans': [
        {
          'resource': {
            'attributes': [
              {
                'key': 'service.name',
                'value': {'stringValue': 'aib'},
              },
            ],
          },
          'scopeSpans': [
            {
              'spans': [
                {
                  'traceId': 'ab' * 16,
                  'spanId': 'cd' * 8,
                  'parentSpanId': '',
                  'name': 'aib.episode',
                  'startTimeUnixNano': '$t0',
                  'endTimeUnixNano': '${t0 + 2000000}',
                  'attributes': [
                    {
                      'key': 'aib.repetition',
                      'value': {'intValue': '2'},
                    },
                  ],
                },
              ],
            },
          ],
        },
      ],
    };
    final spans = decodeOtlp(utf8.encode(jsonEncode(doc)), json: true);
    expect(spans.single['parentId'], isNull);
    expect(spans.single['startUs'], t0 ~/ 1000);
    expect((spans.single['attrs'] as Map)['aib.repetition'], 2);
  });

  test('a truncated body is a format error, not a crash', () {
    expect(() => decodeOtlp(episode().sublist(0, 40), json: false), throwsFormatException);
  });

  test('the store summarises an episode and finds it by run and episode id; a trace without its root is live', () {
    final store = OtelStore();
    final spans = decodeOtlp(episode(), json: false);
    store.ingest(spans.sublist(1));
    expect(store.summaries().single['live'], true);
    store.ingest(spans.sublist(0, 1));
    final s = store.summaries().single;
    expect(s['live'], false);
    expect(s, containsPair('tokensIn', 1200));
    expect(s, containsPair('errors', 1));
    expect(s, containsPair('taskId', 'task.a'));
    expect(store.idFor('run-1', 'task.a__agent__rep1'), s['traceId']);
    expect(store.idFor('run-1', 'other'), isNull);
    expect(store.summaries(runId: 'nope'), isEmpty);
  });

  test('spans persist across a restart and the oldest trace goes first past the cap', () {
    final dir = Directory.systemTemp.createTempSync('aib_otel_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    OtelStore(dir: dir).ingest(decodeOtlp(episode(), json: false));
    expect(OtelStore(dir: dir).traceCount, 1);
    final small = OtelStore(maxTraces: 1);
    for (var i = 0; i < 3; i++) {
      small.ingest([
        {
          'traceId': 't$i',
          'spanId': 's',
          'parentId': null,
          'name': 'x',
          'startUs': i,
          'endUs': i + 1,
          'attrs': <String, Object?>{},
          'events': <Object?>[],
          'status': {'code': 0, 'message': ''},
          'service': '',
        },
      ]);
    }
    expect(small.traceCount, 1);
  });

  test('the server takes a gzip protobuf export on /v1/traces and answers on the API', () async {
    final tmp = Directory.systemTemp.createTempSync('aib_ui_otlp');
    addTearDown(() => tmp.deleteSync(recursive: true));
    Directory(p.join(tmp.path, 'web')).createSync();
    final server = await UiServer.serve(
      root: tmp.path,
      library: tmp.path,
      webDir: p.join(tmp.path, 'web'),
      port: 0,
      otelDir: Directory(p.join(tmp.path, 'otel')),
    );
    addTearDown(server.close);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final base = 'http://127.0.0.1:${server.port}';

    final post = await client.postUrl(Uri.parse('$base/v1/traces'));
    post.headers.contentType = ContentType('application', 'x-protobuf');
    post.headers.set('content-encoding', 'gzip');
    post.add(gzip.encode(episode()));
    expect((await post.close()).statusCode, 200);

    Future<Object?> get(String path) async {
      final res = await (await client.getUrl(Uri.parse('$base$path'))).close();
      return jsonDecode(await utf8.decoder.bind(res).join());
    }

    final list = (await get('/api/otel/traces') as Map)['traces'] as List;
    expect((list.single as Map)['episodeId'], 'task.a__agent__rep1');
    final found = await get('/api/otel/for?runId=run-1&episodeId=task.a__agent__rep1') as Map;
    expect(found['spans'], hasLength(3));
    expect((await get('/api/otel/for?runId=run-1&episodeId=x') as Map)['summary'], isNull);

    final bad = await client.postUrl(Uri.parse('$base/v1/traces'));
    bad.headers.contentType = ContentType.text;
    expect((await bad.close()).statusCode, 415);
  });
}
