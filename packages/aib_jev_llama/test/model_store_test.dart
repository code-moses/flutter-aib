import 'dart:io';
import 'dart:typed_data';

import 'package:aib_jev/aib_jev.dart';
import 'package:aib_jev_llama/aib_jev_llama.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

/// Serves [body] at `/model.gguf`, honouring range requests unless told not
/// to, and records what it was asked.
final class _Server {
  _Server._(this._server, this.body, {required this.ranges});

  static Future<_Server> start(List<int> body, {bool ranges = true}) async =>
      _Server._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), body, ranges: ranges).._listen();

  final HttpServer _server;
  final List<int> body;
  final bool ranges;
  final List<String?> rangeHeaders = [];

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/model.gguf');

  void _listen() => _server.listen((request) async {
    final range = request.headers.value('range');
    rangeHeaders.add(range);
    final match = range == null ? null : RegExp(r'bytes=(\d+)-').firstMatch(range);
    if (ranges && match != null) {
      final from = int.parse(match.group(1)!);
      if (from >= body.length) {
        request.response.statusCode = 416;
      } else {
        request.response
          ..statusCode = 206
          ..contentLength = body.length - from
          ..add(body.sublist(from));
      }
    } else {
      request.response
        ..contentLength = body.length
        ..add(body);
    }
    await request.response.close();
  });

  Future<void> close() => _server.close(force: true);
}

void main() {
  final body = Uint8List.fromList(List.generate(200000, (i) => (i * 31) % 251));
  final hash = '${sha256.convert(body)}';
  late Directory dir;
  late _Server server;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jev-store-');
    server = await _Server.start(body);
  });

  tearDown(() async {
    await server.close();
    await dir.delete(recursive: true);
  });

  JevModelSource source({String? sha, int? size}) => JevModelSource(url: server.url, sha256: sha ?? hash, sizeBytes: size ?? body.length);

  test('downloads, verifies and stores by content', () async {
    final store = JevModelStore(dir);
    final progress = <int>[];
    final file = await store.ensure(source(), onProgress: (received, _) => progress.add(received));
    expect(file.path, endsWith('$hash.gguf'));
    expect(await file.readAsBytes(), body);
    expect(progress.last, body.length);
    expect(store.isStored(source()), isTrue);
    expect(File('${file.path}.part').existsSync(), isFalse);
  });

  test('a stored model is not fetched or hashed again', () async {
    final store = JevModelStore(dir);
    await store.ensure(source());
    await store.ensure(source());
    expect(server.rangeHeaders, hasLength(1));
  });

  test('bytes that do not match the pin are refused and discarded', () async {
    final store = JevModelStore(dir);
    final wrong = 'a' * 64;
    await expectLater(store.ensure(source(sha: wrong)), throwsA(isA<JevModelChecksumMismatch>()));
    expect(dir.listSync(), isEmpty, reason: 'neither the final name nor a .part');
  });

  test('a partial download resumes with a range request', () async {
    final store = JevModelStore(dir);
    File('${store.fileFor(source()).path}.part').writeAsBytesSync(body.sublist(0, 50000));
    final file = await store.ensure(source());
    expect(server.rangeHeaders.single, 'bytes=50000-');
    expect(await file.readAsBytes(), body);
  });

  test('a server that ignores the range starts over rather than appending', () async {
    await server.close();
    server = await _Server.start(body, ranges: false);
    final store = JevModelStore(dir);
    File('${store.fileFor(source()).path}.part').writeAsBytesSync(body.sublist(0, 50000));
    final file = await store.ensure(source());
    expect(await file.readAsBytes(), body);
  });

  test('a file changed on disk is hashed again and replaced', () async {
    final store = JevModelStore(dir);
    final file = await store.ensure(source());
    file.writeAsBytesSync([1, 2, 3], mode: FileMode.append);
    final again = await store.ensure(source());
    expect(await again.readAsBytes(), body);
    expect(server.rangeHeaders, hasLength(2));
  });

  test('a wrong size fails before anything is renamed', () async {
    final store = JevModelStore(dir);
    await expectLater(store.ensure(source(size: body.length + 1)), throwsA(isA<JevModelDownloadFailed>()));
    expect(store.fileFor(source()).existsSync(), isFalse);
  });

  test('cancellation keeps the partial file for the next call', () async {
    final store = JevModelStore(dir);
    final token = CancellationToken();
    await expectLater(
      store.ensure(
        source(),
        cancellation: token,
        onProgress: (received, _) {
          if (received > 0) token.cancel('user closed the sheet');
        },
      ),
      throwsA(anything),
    );
    expect(store.fileFor(source()).existsSync(), isFalse);
    final file = await store.ensure(source());
    expect(await file.readAsBytes(), body);
  });

  test('the pin is validated', () {
    expect(() => JevModelSource(url: server.url, sha256: 'abc'), throwsArgumentError);
    expect(JevModelSource.fromJson({'url': 'https://x/m.gguf', 'sha256': hash.toUpperCase()}).sha256, hash);
    expect(() => JevModelSource.fromJson({'url': 'https://x/m.gguf'}), throwsFormatException);
  });

  group('LlamaJevConfig', () {
    test('other backends go to JevConfig unchanged', () async {
      final client = await LlamaJevConfig.clientFromJson({'backend': 'ollama', 'model': 'qwen3:4b'}, store: JevModelStore(dir));
      expect(client, isA<LogitJevClient>());
      expect(server.rangeHeaders, isEmpty);
    });

    test('llama needs a format, and exactly one model source', () async {
      final store = JevModelStore(dir);
      await expectLater(LlamaJevConfig.clientFromJson({'backend': 'llama', 'modelPath': '/m.gguf'}, store: store), throwsFormatException);
      await expectLater(
        LlamaJevConfig.clientFromJson({
          'backend': 'llama',
          'format': 'qwen3',
          'modelPath': '/m.gguf',
          'download': {'url': 'https://x', 'sha256': hash},
        }, store: store),
        throwsFormatException,
      );
    });

    test('a download block fetches the model before the client is built', () async {
      final store = JevModelStore(dir);
      final client = await LlamaJevConfig.clientFromJson({'backend': 'llama', 'format': 'qwen3', 'download': source().toJson()}, store: store);
      expect(store.isStored(source()), isTrue);
      expect(client.model, 'gguf-sha256:${hash.substring(0, 12)}');
    });
  });
}
