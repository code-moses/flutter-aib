import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aib_jev/aib_jev.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// A GGUF to fetch, pinned by its content: the SHA-256 is the identity, not the
/// URL. A download whose bytes do not hash to [sha256] is refused.
final class JevModelSource {
  JevModelSource({required this.url, required String sha256, this.sizeBytes}) : sha256 = sha256.toLowerCase() {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(this.sha256)) {
      throw ArgumentError.value(sha256, 'sha256', 'must be 64 hex digits');
    }
  }

  /// `{url, sha256, size?}` — the `download:` block of a `backend: llama`
  /// config.
  factory JevModelSource.fromJson(JsonMap json) {
    final url = json['url'];
    final sha256 = json['sha256'];
    if (url is! String || sha256 is! String) {
      throw const FormatException('a model download needs "url" and "sha256"');
    }
    return JevModelSource(url: Uri.parse(url), sha256: sha256, sizeBytes: (json['size'] as num?)?.toInt());
  }

  final Uri url;

  /// Lowercase hex.
  final String sha256;

  /// Checked before hashing when known: a truncated file fails fast.
  final int? sizeBytes;

  /// Qwen3-4B, Q4_K_M, from Qwen's own GGUF repository.
  static final qwen3_4bQ4KM = JevModelSource(
    url: Uri.parse('https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf'),
    sha256: '7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5',
    sizeBytes: 2497280256,
  );

  JsonMap toJson() => {'url': '$url', 'sha256': sha256, 'size': ?sizeBytes};
}

/// The bytes did not hash to the pin. The partial file is deleted.
final class JevModelChecksumMismatch implements Exception {
  const JevModelChecksumMismatch({required this.url, required this.expected, required this.actual});

  final Uri url;
  final String expected;
  final String actual;

  @override
  String toString() => 'JevModelChecksumMismatch: $url hashed to $actual, pinned $expected — not used';
}

/// The download failed before it was complete; a retry resumes it.
final class JevModelDownloadFailed implements Exception {
  const JevModelDownloadFailed(this.url, this.message);

  final Uri url;
  final String message;

  @override
  String toString() => 'JevModelDownloadFailed: $url — $message';
}

/// Where downloaded decision models live, by content.
///
/// - **Content-addressed.** A model is stored as `<sha256>.gguf`, so two
///   sources for the same bytes share one file and a changed pin can never
///   pick up the old file.
/// - **Resumable.** Bytes arrive in `<sha256>.gguf.part`; an interrupted
///   download continues with an HTTP range request where the server allows
///   one, and starts over where it does not.
/// - **Atomic.** The final name appears only after the hash matched — a
///   crash mid-download leaves a `.part`, never a wrong model under the
///   right name.
/// - **Verified once.** Hashing 2.5 GB takes seconds, so a verified file gets
///   a sidecar recording its size and modification time; [ensure] hashes it
///   again only when either changed, or when asked to ([verify]).
final class JevModelStore {
  JevModelStore(this.directory, {http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final Directory directory;
  final http.Client _http;

  File fileFor(JevModelSource source) => File('${directory.path}${Platform.pathSeparator}${source.sha256}.gguf');

  File _partFor(JevModelSource source) => File('${fileFor(source).path}.part');

  File _sidecarFor(JevModelSource source) => File('${fileFor(source).path}.verified');

  /// A local file holding exactly [source]'s bytes: the stored one when it
  /// still verifies, otherwise downloaded (resuming a partial download).
  ///
  /// [verify] forces a full re-hash of a stored file. [onProgress] gets the
  /// bytes on disk and the total when known. Cancellation keeps the partial
  /// file, so the next call resumes it.
  Future<File> ensure(
    JevModelSource source, {
    bool verify = false,
    void Function(int received, int? total)? onProgress,
    CancellationToken? cancellation,
  }) async {
    final file = fileFor(source);
    if (file.existsSync()) {
      if (!verify && await _sidecarMatches(source, file)) return file;
      final actual = await sha256Of(file);
      if (actual == source.sha256) {
        await _writeSidecar(source, file);
        return file;
      }
      // Something else sits under a content-addressed name: it is not this
      // model, and it cannot be any other either.
      await file.delete();
    }
    directory.createSync(recursive: true);
    await _download(source, onProgress: onProgress, cancellation: cancellation);
    return file;
  }

  /// Whether [source] is stored and verified, without downloading or hashing.
  bool isStored(JevModelSource source) => fileFor(source).existsSync() && _sidecarFor(source).existsSync();

  /// Streams [file] through SHA-256; lowercase hex.
  static Future<String> sha256Of(File file) async => '${await sha256.bind(file.openRead()).first}';

  Future<void> _download(JevModelSource source, {void Function(int, int?)? onProgress, CancellationToken? cancellation}) async {
    final part = _partFor(source);
    var offset = part.existsSync() ? part.lengthSync() : 0;
    if (source.sizeBytes case final size? when offset > size) {
      await part.delete();
      offset = 0;
    }

    final request = http.Request('GET', source.url);
    if (offset > 0) request.headers['range'] = 'bytes=$offset-';
    final http.StreamedResponse response;
    try {
      response = await _http.send(request);
    } on Exception catch (e) {
      throw JevModelDownloadFailed(source.url, '$e');
    }
    final resumed = offset > 0 && response.statusCode == 206;
    if (response.statusCode != 200 && !resumed) {
      await response.stream.drain<void>();
      if (response.statusCode == 416 && offset > 0) {
        // The range starts at or past the end: the part may already be whole.
        return _finish(source, part);
      }
      throw JevModelDownloadFailed(source.url, 'HTTP ${response.statusCode}');
    }
    if (!resumed) offset = 0;
    final total = switch (response.contentLength) {
      final length? => offset + length,
      null => source.sizeBytes,
    };

    final sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
    var received = offset;
    try {
      await for (final chunk in response.stream) {
        if (cancellation?.isCancelled ?? false) {
          throw const _Cancelled();
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
    } on _Cancelled {
      await sink.close();
      cancellation!.throwIfCancelled();
      rethrow;
    } on Exception catch (e) {
      await sink.close();
      throw JevModelDownloadFailed(source.url, 'interrupted at $received bytes: $e');
    }
    await sink.close();
    await _finish(source, part);
  }

  Future<void> _finish(JevModelSource source, File part) async {
    final length = part.lengthSync();
    if (source.sizeBytes case final size? when length != size) {
      if (length > size) await part.delete();
      throw JevModelDownloadFailed(source.url, 'got $length bytes, pinned $size');
    }
    final actual = await sha256Of(part);
    if (actual != source.sha256) {
      await part.delete();
      throw JevModelChecksumMismatch(url: source.url, expected: source.sha256, actual: actual);
    }
    final file = await part.rename(fileFor(source).path);
    await _writeSidecar(source, file);
  }

  Future<bool> _sidecarMatches(JevModelSource source, File file) async {
    final sidecar = _sidecarFor(source);
    if (!sidecar.existsSync()) return false;
    try {
      final recorded = asJsonMap(jsonDecode(await sidecar.readAsString()));
      final stat = file.statSync();
      return recorded['sha256'] == source.sha256 && recorded['size'] == stat.size && recorded['modified'] == stat.modified.toUtc().toIso8601String();
    } on FormatException {
      return false;
    }
  }

  Future<void> _writeSidecar(JevModelSource source, File file) async {
    final stat = file.statSync();
    await _sidecarFor(source).writeAsString(
      jsonEncode({'sha256': source.sha256, 'size': stat.size, 'modified': stat.modified.toUtc().toIso8601String(), 'url': '${source.url}'}),
    );
  }

  void close() => _http.close();
}

/// Cancellation observed between chunks.
final class _Cancelled implements Exception {
  const _Cancelled();
}
