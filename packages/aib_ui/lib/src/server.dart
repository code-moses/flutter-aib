import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aib_cli/aib_cli.dart';
import 'package:aib_core/aib_core.dart';
import 'package:aib_mcp/aib_mcp.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'labelling.dart';
import 'otlp.dart';
import 'run_reader.dart';
import 'runner_check.dart';
import 'user_state.dart';

/// A request the server answers with a status instead of a stack trace.
final class ApiError implements Exception {
  const ApiError(this.status, this.message);
  final int status;
  final String message;
}

/// The local web UI's HTTP server: a JSON API over run directories (read as
/// plain files, any folder) and, when a checkout with `aib_mcp.yaml` is
/// known, over the same workspace, runner and job layer the MCP server uses.
///
/// It binds to the loopback interface, refuses requests whose Host is not
/// loopback (DNS rebinding) and requires a header on every write that a
/// cross-site form cannot send.
final class UiServer {
  UiServer._(
    this._http,
    this._web,
    this.reader,
    this.state,
    this.workspace,
    this.launcher,
    this.jobs,
    this.defaultLibrary,
    this.root,
    this.otel,
    this.labelling,
  );

  final HttpServer _http;
  final String _web;
  final RunReader reader;
  final UserState state;
  final AibWorkspace? workspace;
  final RunLauncher? launcher;
  final JobManager? jobs;
  final String defaultLibrary;
  final String root;

  /// Spans received on `/v1/traces`.
  final OtelStore otel;

  /// Judge calibration sets (the Label view).
  final Labelling labelling;
  HttpServer? _otlp;

  int get port => _http.port;
  int? get otlpPort => _otlp?.port;

  static Future<UiServer> serve({
    required String root,
    String? configPath,
    String? library,
    required String webDir,
    String host = '127.0.0.1',
    int port = 8787,
    bool showHoldout = false,
    int otlpPort = 0,
    Directory? otelDir,
  }) async {
    final cfgFile = configPath ?? p.join(root, 'aib_mcp.yaml');
    AibWorkspace? workspace;
    RunLauncher? launcher;
    JobManager? jobs;
    var effectiveRoot = p.normalize(p.absolute(root));
    if (File(cfgFile).existsSync()) {
      final config = AibMcpConfig.load(cfgFile);
      effectiveRoot = config.root;
      // Paths recorded in manifests resolve against the checkout.
      Directory.current = config.root;
      workspace = AibWorkspace(config);
      jobs = JobManager(
        hostLimits: {for (final h in config.hosts.values) h.name: h.concurrency},
        historyFile: File(p.join(config.root, 'results', '.aib_mcp', 'jobs.jsonl')),
      );
      launcher = RunLauncher(workspace: workspace, jobs: jobs);
    }
    final defaultLibrary = p.normalize(p.absolute(library ?? p.join(effectiveRoot, 'results')));
    final http = await HttpServer.bind(host, port);
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final store = OtelStore(dir: otelDir ?? (home == null ? null : Directory(p.join(home, '.aib_ui', 'otel'))));
    final server = UiServer._(
      http,
      webDir,
      RunReader(workspaceRoot: workspace == null ? null : effectiveRoot, showHoldout: showHoldout),
      UserState.open(),
      workspace,
      launcher,
      jobs,
      defaultLibrary,
      effectiveRoot,
      store,
      Labelling(root: effectiveRoot, showHoldout: showHoldout, service: workspace?.service ?? const AibService()),
    );
    http.listen(server._handle);
    // The conventional OTLP/HTTP port, so `--otel http://localhost:4318/v1/traces`
    // works as it does against a collector. Skipped when something else holds it.
    if (otlpPort > 0) {
      try {
        server._otlp = await HttpServer.bind(host, otlpPort);
        server._otlp!.listen(server._handle);
      } on SocketException {
        server._otlp = null;
      }
    }
    return server;
  }

  Future<void> close() async {
    await jobs?.shutdown();
    await _otlp?.close(force: true);
    await _http.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (!_loopback(request.headers.host)) throw const ApiError(HttpStatus.forbidden, 'only loopback hosts are served');
      final path = request.uri.path;
      if (path == '/v1/traces') {
        await _receiveSpans(request);
      } else if (path.startsWith('/api/')) {
        final write = request.method != 'GET';
        if (write && request.headers.value('x-aib-ui') != '1') throw const ApiError(HttpStatus.forbidden, 'missing X-AIB-UI header');
        Json body = const {};
        if (write) {
          final text = await utf8.decoder.bind(request).join();
          if (text.isNotEmpty) {
            final decoded = jsonDecode(text);
            if (decoded is Map) body = {for (final e in decoded.entries) '${e.key}': e.value};
          }
        }
        final result = await _route(request.method, path.substring(5), request.uri.queryParameters, body);
        response.headers.contentType = ContentType.json;
        response.headers.set('cache-control', 'no-store');
        if (result is _Raw) {
          response.headers.contentType = ContentType.parse(result.type);
          // A run folder may come from anyone, and this origin holds the write API.
          response.headers.set('content-security-policy', 'sandbox');
          response.add(result.bytes);
        } else {
          response.write(jsonEncode(result));
        }
      } else {
        await _static(request);
      }
    } on ApiError catch (e) {
      response.statusCode = e.status;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'error': e.message}));
    } on AibError catch (e) {
      response.statusCode = HttpStatus.unprocessableEntity;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'error': e.message}));
    } on FileSystemException catch (e) {
      response.statusCode = HttpStatus.notFound;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'error': '${e.message}: ${e.path}'}));
    } on ArgumentError catch (e) {
      response.statusCode = HttpStatus.badRequest;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'error': '${e.message}'}));
    } on FormatException catch (e) {
      response.statusCode = HttpStatus.badRequest;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'error': e.message}));
    } on Object catch (e, st) {
      stderr.writeln('$e\n$st');
      response.statusCode = HttpStatus.internalServerError;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'error': '$e'}));
    } finally {
      await response.close();
    }
  }

  /// OTLP/HTTP `POST /v1/traces`. A browser page cannot send a protobuf or
  /// JSON body cross-site without a preflight this server never answers, so no
  /// header is demanded of exporters.
  Future<void> _receiveSpans(HttpRequest request) async {
    final response = request.response;
    if (request.method != 'POST') throw const ApiError(HttpStatus.methodNotAllowed, 'POST OTLP/HTTP trace exports here');
    final type = request.headers.contentType?.mimeType ?? '';
    final json = type == 'application/json';
    if (!json && type != 'application/x-protobuf') {
      throw ApiError(HttpStatus.unsupportedMediaType, 'content type $type: send application/x-protobuf or application/json');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
      if (builder.length > 64 * 1024 * 1024) throw const ApiError(HttpStatus.requestEntityTooLarge, 'batch too large');
    }
    List<int> body = builder.takeBytes();
    if (request.headers.value('content-encoding') == 'gzip') body = gzip.decode(body);
    otel.ingest(decodeOtlp(body, json: json));
    response.headers.contentType = ContentType.parse(json ? 'application/json' : 'application/x-protobuf');
    if (json) response.write('{}');
  }

  static bool _loopback(String? host) => host == 'localhost' || host == '127.0.0.1' || host == '::1' || host == '[::1]';

  Future<void> _static(HttpRequest request) async {
    var path = request.uri.path;
    if (path == '/') path = '/index.html';
    final file = File(p.normalize(p.join(_web, path.substring(1))));
    if (!p.isWithin(_web, file.path) || !file.existsSync()) {
      // Client-side routes fall back to the app shell.
      if (!p.extension(path).isNotEmpty) return _send(request, File(p.join(_web, 'index.html')));
      throw const ApiError(HttpStatus.notFound, 'not found');
    }
    await _send(request, file);
  }

  static const _mime = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.mjs': 'text/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.json': 'application/json',
    '.svg': 'image/svg+xml',
    '.woff2': 'font/woff2',
    '.woff': 'font/woff',
    '.png': 'image/png',
    '.ico': 'image/x-icon',
  };

  Future<void> _send(HttpRequest request, File file) async {
    final response = request.response;
    response.headers.set('content-type', _mime[p.extension(file.path)] ?? 'application/octet-stream');
    response.headers.set('cache-control', 'no-cache');
    await response.addStream(file.openRead());
  }

  // Routes

  Future<Object?> _route(String method, String path, Map<String, String> q, Json body) async {
    final key = '$method $path';
    switch (key) {
      case 'GET info':
        return _info();
      case 'GET fs':
        return _fs(q['path']);
      case 'GET runs':
        return _runs(_library(q));
      case 'GET run':
        return _run(q);
      case 'GET trace':
        return {'events': reader.trace(_runDir(q), q['episode'] ?? '')};
      case 'GET file':
        return _file(q);
      case 'GET otel/info':
        return {
          'endpoint': 'http://localhost:${_http.port}/v1/traces',
          'conventionalEndpoint': otlpPort == null ? null : 'http://localhost:$otlpPort/v1/traces',
          'traces': otel.traceCount,
          'spans': otel.spans,
          'batches': otel.batches,
          'lastAt': otel.lastAt?.toIso8601String(),
        };
      case 'GET otel/traces':
        return {'traces': otel.summaries(runId: q['run'], q: q['q']).take(int.tryParse(q['limit'] ?? '') ?? 1000).toList()};
      case 'GET otel/trace':
        final spans = otel.trace(q['id'] ?? '') ?? (throw const ApiError(HttpStatus.notFound, 'no such trace'));
        return {'summary': otel.summary(q['id']!), 'spans': spans};
      case 'GET otel/for':
        final id = otel.idFor(q['runId'] ?? '', q['episodeId'] ?? '');
        return id == null ? {'summary': null, 'spans': const <Object?>[]} : {'summary': otel.summary(id), 'spans': otel.trace(id)};
      case 'POST otel/clear':
        otel.clear();
        return {'ok': true};
      case 'GET user':
        return state.toJson();
      case 'POST user/annotate':
        state.annotate(
          body['dir'] as String,
          tags: (body['tags'] as List?)?.map((e) => '$e').toList(),
          note: body['note'] as String?,
          starred: body['starred'] as bool?,
          alias: body['alias'] as String?,
        );
        return state.toJson();
      case 'POST user/recent':
        state.addRecent(body['path'] as String);
        return state.toJson();
      case 'POST user/forget':
        state.removeRecent(body['path'] as String);
        return state.toJson();
      case 'GET label/sets':
        return {'sets': labelling.listSets(_library(q))};
      case 'GET label/set':
        return labelling.load(_setDir(q['path']));
      case 'POST label/save':
        return labelling.save(
          _setDir(body['path'] as String?),
          labelId: body['labelId'] as String,
          criterion: body['criterion'] as String?,
          label: body['label'] as String?,
          note: body['note'] as String?,
        );
      case 'POST label/create':
        final out = body['out'] as String? ?? (throw const ApiError(HttpStatus.badRequest, 'out is required'));
        return labelling.create(
          runs: _strings(body['runs']),
          out: p.isAbsolute(out) ? out : p.join(_library(q), out),
          sample: body['sample'] as int?,
          seed: body['seed'] as int? ?? 42,
        );
      case 'POST label/calibrate':
        return labelling.calibrate(_setDir(body['path'] as String?));
    }
    if (path.startsWith('fw/')) return _framework(method, path.substring(3), q, body);
    throw ApiError(HttpStatus.notFound, 'no route $key');
  }

  Json _info() => {
    'root': root,
    'defaultLibrary': defaultLibrary,
    'home': Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '/',
    'framework': workspace != null,
    'platform': Platform.operatingSystem,
    'runners': {
      for (final r in workspace?.config.runners.values ?? const <RunnerRecipe>[]) r.name: {'kind': r.kind.name, 'suite': r.suite},
    },
    'hosts': {
      for (final h in workspace?.config.hosts.values ?? const <HostLimit>[]) h.name: {'url': h.url, 'concurrency': h.concurrency},
    },
    'budget': workspace == null
        ? null
        : {
            'maxUsdPerJob': workspace!.config.budget.maxUsdPerJob,
            'maxUsdPerDay': workspace!.config.budget.maxUsdPerDay,
            'autoApproveUsd': workspace!.config.budget.autoApproveUsd,
          },
    'judges': workspace?.config.judges ?? const {},
    'maxChangedPaths': workspace?.config.maxChangedPaths,
    'user': state.toJson(),
  };

  String _library(Map<String, String> q) {
    final dir = q['dir'] ?? defaultLibrary;
    if (!Directory(dir).existsSync()) throw ApiError(HttpStatus.notFound, 'no such folder: $dir');
    return p.normalize(p.absolute(dir));
  }

  String _runDir(Map<String, String> q) {
    final lib = _library(q);
    final id = q['run'] ?? (throw const ApiError(HttpStatus.badRequest, 'run is required'));
    final dir = p.normalize(p.join(lib, id));
    if (dir != lib && !p.isWithin(lib, dir)) throw const ApiError(HttpStatus.forbidden, 'outside the folder');
    if (!RunReader.isRun(dir)) throw ApiError(HttpStatus.notFound, '$id is not a run directory');
    return dir;
  }

  /// A calibration set's folder; any folder the person points at, as for runs.
  String _setDir(String? path) {
    if (path == null || path.isEmpty) throw const ApiError(HttpStatus.badRequest, 'path is required');
    final dir = p.normalize(p.absolute(path));
    if (!Labelling.isSet(dir)) throw ApiError(HttpStatus.notFound, '$path is not a calibration set (no ${Labelling.sampleFile})');
    return dir;
  }

  Json _runs(String lib) {
    final started = DateTime.now();
    final dirs = RunReader.find(lib);
    final runs = [for (final d in dirs) reader.summary(d, lib)];
    runs.sort((a, b) => '${b['createdAt']}'.compareTo('${a['createdAt']}'));
    // Other output next to runs (comparison reports, sweeps) is listed by name.
    final extras = <String>[];
    try {
      for (final e in Directory(lib).listSync(followLinks: false)) {
        if (e is Directory && !p.basename(e.path).startsWith('.') && !RunReader.isRun(e.path) && !dirs.any((d) => p.isWithin(e.path, d))) {
          extras.add(p.basename(e.path));
        }
      }
    } on FileSystemException {
      // unreadable: nothing extra to list
    }
    return {
      'dir': lib,
      'runs': runs,
      'otherFolders': extras..sort(),
      'scanMs': DateTime.now().difference(started).inMilliseconds,
      'annotations': {for (final d in dirs) p.relative(d, from: lib): state.annotation(d)},
    };
  }

  Json _run(Map<String, String> q) {
    final dir = _runDir(q);
    return {...reader.detail(dir, _library(q)), 'annotation': state.annotation(dir)};
  }

  Object _file(Map<String, String> q) {
    final dir = _runDir(q);
    final name = q['name'] ?? '';
    if (name.contains('/') || name.contains('\\') || name.startsWith('.')) throw const ApiError(HttpStatus.badRequest, 'bad file name');
    final f = File(p.join(dir, name));
    if (!f.existsSync()) throw ApiError(HttpStatus.notFound, 'no $name');
    if (f.lengthSync() > 8 * 1024 * 1024) throw const ApiError(HttpStatus.requestEntityTooLarge, 'file too large to show');
    final ext = p.extension(name);
    final type =
        {
          '.html': 'text/html; charset=utf-8',
          '.json': 'application/json',
          '.md': 'text/plain; charset=utf-8',
          '.csv': 'text/plain; charset=utf-8',
        }[ext] ??
        'text/plain; charset=utf-8';
    return _Raw(type, f.readAsBytesSync());
  }

  Json _fs(String? path) {
    final dir = p.normalize(p.absolute(path == null || path.isEmpty ? (Platform.environment['HOME'] ?? '/') : path));
    final d = Directory(dir);
    if (!d.existsSync()) throw ApiError(HttpStatus.notFound, 'no such folder: $dir');
    final entries = <Json>[];
    try {
      for (final e in d.listSync(followLinks: false)) {
        if (e is! Directory) continue;
        final name = p.basename(e.path);
        if (name.startsWith('.')) continue;
        var runs = 0;
        final isRun = RunReader.isRun(e.path);
        if (!isRun) {
          try {
            for (final c in e.listSync(followLinks: false)) {
              if (c is Directory && RunReader.isRun(c.path)) runs++;
            }
          } on FileSystemException {
            // unreadable folder
          }
        }
        entries.add({'name': name, 'path': e.path, 'isRun': isRun, 'runs': runs});
      }
    } on FileSystemException catch (e) {
      throw ApiError(HttpStatus.forbidden, 'cannot read $dir: ${e.osError?.message ?? e.message}');
    }
    entries.sort((a, b) => '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));
    return {
      'path': dir,
      'parent': p.dirname(dir) == dir ? null : p.dirname(dir),
      'isRun': RunReader.isRun(dir),
      'runsHere': entries.where((e) => e['isRun'] == true).length,
      'entries': entries,
    };
  }

  // The framework (needs aib_mcp.yaml)

  AibWorkspace get _ws =>
      workspace ??
      (throw const ApiError(HttpStatus.failedDependency, 'no aib_mcp.yaml found: start the UI with --root <checkout> to configure and run'));
  RunLauncher get _launcher => launcher ?? (throw const ApiError(HttpStatus.failedDependency, 'no runner'));

  /// A run path the workspace's sandbox accepts: relative to the checkout.
  String _rel(String dirOrRel) {
    final abs = p.normalize(p.isAbsolute(dirOrRel) ? dirOrRel : p.join(root, dirOrRel));
    if (!p.isWithin(root, abs)) {
      throw ApiError(HttpStatus.unprocessableEntity, 'the framework operates on runs inside the checkout ($root); this one is outside');
    }
    return p.relative(abs, from: root);
  }

  List<String> _strings(Object? v) => [for (final x in v as List? ?? const []) '$x'];

  Future<Object?> _framework(String method, String path, Map<String, String> q, Json body) async {
    final ws = _ws;
    final service = ws.service;
    ScoringOptions scoring() => ScoringOptions(metrics: _strings(body['metrics']));
    switch ('$method $path') {
      case 'GET suites':
        return {'suites': ws.listSuites()};
      case 'GET suite':
        return ws.describeSuite(q['name']!);
      case 'GET configs':
        return {'configs': ws.listAgentConfigs(filter: q['filter'])};
      case 'GET config':
        return ws.readAgentConfig(q['name']!);
      case 'POST config/parse':
        return {'parsed': _parseYaml(body['yaml'] as String)};
      case 'POST config/validate':
        return (ws.validateAgentConfig(agent: body['agent'] as String, name: body['name'] as String?, yaml: body['yaml'] as String?)).toJson()
          ..remove('path');
      case 'POST config/derive':
        return _derive(ws, body);
      case 'POST config/preview':
        return _preview(ws, body);
      case 'POST config/diff':
        return ws.diffAgentConfigs(a: body['a'] as String, b: body['b'] as String, agent: body['agent'] as String);
      case 'GET runner/check':
        return checkRunner(_launcher.recipe(q['runner'] ?? ''), root: root);
      case 'POST judge/plan':
        return _judgePlan(ws, body['run'] as String);
      case 'GET metrics':
        return {
          'metrics': [for (final m in service.metrics()) m.toJson()],
        };
      case 'GET doctor':
        return (await service.doctor(
          suite: q['suite'] == null ? null : ws.suitePath(q['suite']!),
          judge: q['judge'] == null ? null : ws.agentConfigPath(q['judge']!),
          agents: [for (final name in (q['configs'] ?? '').split(',').where((s) => s.isNotEmpty)) '$name=${ws.agentConfigPath(name)}'],
        )).toJson();
      case 'POST estimate':
        return _launcher.estimate(
          configName: body['config'] as String,
          agent: body['agent'] as String,
          suite: _suiteFor(body),
          tasks: _tasks(body),
          reps: body['reps'] as int?,
        );
      case 'POST run':
        _checkCap(body);
        final check = await checkRunner(_launcher.recipe(body['runner'] as String), root: root);
        if (check['ok'] != true) throw AibError('${check['message']}');
        final job = await _launcher.startRun(
          runner: body['runner'] as String,
          configName: body['config'] as String,
          agent: body['agent'] as String,
          suite: body['suite'] as String?,
          reps: body['reps'] as int?,
          tasks: _tasks(body),
          seed: body['seed'] as int?,
          maxUsd: (body['maxUsd'] as num?)?.toDouble(),
          out: (body['out'] as String?)?.isEmpty ?? true ? null : body['out'] as String,
          study: body['study'] as String?,
          otel: _otelEndpoint(body),
          otelCaptureContent: body['otelCaptureContent'] == true,
          launcher: (client: 'aib_ui', clientVersion: '1.0.0'),
          approve: (_) async => body['approved'] == true,
        );
        return _job(job);
      case 'GET jobs':
        final j = jobs!;
        return {
          'jobs': [for (final job in j.jobs.toList().reversed) _job(job)],
          'spentTodayUsd': j.spentToday(),
        };
      case 'GET job':
        return _job(jobs![q['id']!] ?? (throw ApiError(HttpStatus.notFound, 'no job ${q['id']}')));
      case 'GET job/log':
        final job = jobs![q['id']!] ?? (throw ApiError(HttpStatus.notFound, 'no job ${q['id']}'));
        if (job.kind == 'holdout') throw const ApiError(HttpStatus.forbidden, "a holdout job's log is not shown");
        return {'lines': job.tail(int.tryParse(q['tail'] ?? '') ?? 200)};
      case 'POST job/cancel':
        return _job(jobs!.cancel(body['id'] as String));
      case 'POST evaluate':
        _checkCap(body);
        final dir = ws.runDir(_rel(body['run'] as String));
        ws.sandbox.write(dir);
        if (body['judge'] == true) {
          return _job(
            await _launcher.startJudgedEvaluation(
              runDir: dir,
              metrics: _strings(body['metrics']),
              maxUsd: (body['maxUsd'] as num?)?.toDouble(),
              approve: (_) async => body['approved'] == true,
              only: ws.scoringTasks(dir),
            ),
          );
        }
        final summary = await service.evaluate(dir, options: scoring(), withoutJudge: .reusePersisted);
        return {...summary.toJson(), 'written': summary.written.map(ws.sandbox.relative).toList()};
      case 'POST report':
        final dir = ws.runDir(_rel(body['run'] as String));
        ws.sandbox.write(dir);
        final formats = _strings(body['formats']);
        final outcome = await service.report(dir, formats: formats.isEmpty ? const ['md', 'html'] : formats, options: scoring());
        return {...outcome.toJson(), 'markdown': outcome.markdown, 'written': outcome.written.map(ws.sandbox.relative).toList()};
      case 'POST compare':
        try {
          final dirs = [for (final r in _strings(body['runs'])) ws.runDir(_rel(r))];
          final outcome = await service.compare(dirs, options: scoring().only(ws.scoringTasks(dirs.first)), vary: _strings(body['vary']));
          return {...outcome.toJson(), 'markdown': outcome.markdown};
        } on UnintendedDifferences catch (e) {
          throw AibError(
            '${e.message}\n${jsonEncode({
              for (final entry in e.differences.entries) entry.key: [for (final d in entry.value) differenceJson(d)],
            })}',
          );
        }
      case 'POST provenance':
        final dir = ws.runDir(_rel(body['run'] as String));
        return service.provenance(dir, against: body['against'] == null ? null : ws.runDir(_rel(body['against'] as String))).toJson();
      case 'POST selftest':
        final path = ws.suitePath(body['suite'] as String);
        return (await service.selftest(
          suite: path,
          reference: body['reference'] == null ? null : ws.sandbox.read(body['reference'] as String),
          tasks: null,
        )).toJson();
    }
    throw ApiError(HttpStatus.notFound, 'no route $method fw/$path');
  }

  /// `otel: true` exports to this server; a string is a collector's endpoint.
  String? _otelEndpoint(Json body) => switch (body['otel']) {
    true => 'http://localhost:${otlpPort ?? port}/v1/traces',
    final String url when url.trim().isNotEmpty => url.trim(),
    _ => null,
  };

  /// A spend cap of nothing would stop the job at once; the person must say how much.
  void _checkCap(Json body) {
    final cap = body['maxUsd'];
    if (cap != null && (cap is! num || cap <= 0)) throw const AibError('the spend cap must be more than \$0');
  }

  /// What judging a run would use and cost, for the dialog that asks first.
  Future<Json> _judgePlan(AibWorkspace ws, String run) async {
    final dir = ws.runDir(_rel(run));
    final manifest = RunStore(Directory(dir)).readManifest();
    final suite = manifest.suiteName;
    final detail = reader.detail(dir, p.dirname(dir));
    final tasks = [for (final t in (detail['tasks'] as List)) t as Map];
    final rubricTasks = {
      for (final t in tasks)
        if ((t['criteria'] as List).any((c) => (c as Map)['type'] == 'artifactRubric')) '${t['id']}',
    };
    final episodes = [for (final e in (detail['episodes'] as List)) e as Map];
    final toJudge = episodes.where((e) => rubricTasks.contains(e['taskId'])).length;
    final judgeName = ws.config.judges[suite];
    final stored = RunStore(Directory(dir)).readJudgeProvenance();
    Json? judge;
    if (judgeName != null) {
      final path = ws.agentConfigPath(judgeName);
      final targets = modelTargets(Builtins.loadConfig(path));
      final paid = paidTargets(targets, _launcher.prices);
      final first = targets.isEmpty ? null : targets.first;
      judge = {
        'config': judgeName,
        'provider': first?.provider,
        'model': first?.model,
        'paid': paid.isNotEmpty,
        'hosts': hostsOf(targets, ws.config.hosts).toList(),
      };
    }
    return {
      'suite': suite,
      'known': tasks.isNotEmpty,
      'needsJudge': rubricTasks.isNotEmpty,
      'rubricTasks': rubricTasks.length,
      'episodes': episodes.length,
      'episodesToJudge': toJudge,
      'judge': judge,
      'noJudgePinned': judgeName == null && rubricTasks.isNotEmpty,
      'scored': File(p.join(dir, RunStore.verdictsFile)).existsSync(),
      'storedJudge': stored == null ? null : {'id': stored.judgeId, 'k': stored.k},
      'maxUsdPerJob': ws.config.budget.maxUsdPerJob,
      'maxUsdPerDay': ws.config.budget.maxUsdPerDay,
      'spentTodayUsd': jobs?.spentToday() ?? 0,
    };
  }

  String _suiteFor(Json body) =>
      _launcher.recipe(body['runner'] as String).suite ?? body['suite'] as String? ?? (throw const AibError('pick a suite'));

  List<String>? _tasks(Json body) {
    final suite = _suiteFor(body);
    final given = body['tasks'] == null ? null : _strings(body['tasks']);
    return _ws.tuningTasks(suite, given == null || given.isEmpty ? null : given);
  }

  Json _job(Job job) => job.toJson(path: (s) => p.isWithin(root, s) ? p.relative(s, from: root) : s);

  /// A new arm. The server's own rule is one changed path, which keeps a study
  /// attributable; a person may widen it for one arm (`allowMany`).
  Json _derive(AibWorkspace ws, Json body) {
    var target = ws;
    if (body['allowMany'] == true) {
      final c = ws.config;
      target = AibWorkspace(
        AibMcpConfig(
          root: c.root,
          writable: c.writable,
          maxChangedPaths: 1000,
          runners: c.runners,
          hosts: c.hosts,
          budget: c.budget,
          judges: c.judges,
          http: c.http,
          splits: c.splits,
        ),
      );
    }
    Object? patch = body['patch'];
    if (body['yaml'] is String) {
      final edited = _parseYaml(body['yaml'] as String);
      patch = mergePatchBetween(ws.loadAgentConfig(body['base'] as String), edited);
    }
    final derived = target.deriveAgentConfig(
      base: body['base'] as String,
      agent: body['agent'] as String,
      patch: patch,
      name: body['name'] as String,
      hypothesis: body['hypothesis'] as String,
    );
    return {...derived, 'patch': patch};
  }

  /// What a derived arm would change and whether it builds, without writing it.
  Json _preview(AibWorkspace ws, Json body) {
    final base = ws.loadAgentConfig(body['base'] as String);
    final Object? patch = body['yaml'] is String ? mergePatchBetween(base, _parseYaml(body['yaml'] as String)) : body['patch'];
    final derived = asJsonMap(mergePatch(base, patch));
    final changes = configChanges(base, derived);
    final check = ws.service.validateAgentConfig(agent: body['agent'] as String, config: derived);
    return {
      'changes': [for (final c in changes) c.toJson()],
      'check': check.toJson()..remove('path'),
      'allowed': changes.length <= ws.config.maxChangedPaths,
      'maxChangedPaths': ws.config.maxChangedPaths,
    };
  }

  Object? _parseYaml(String text) {
    try {
      return asJsonMap(yamlToJson(loadYaml(text)));
    } on Object catch (e) {
      throw AibError('yaml does not parse: $e');
    }
  }
}

final class _Raw {
  _Raw(this.type, this.bytes);
  final String type;
  final List<int> bytes;
}

/// The RFC 7386 merge patch that turns [base] into [edited].
Object? mergePatchBetween(Object? base, Object? edited) {
  if (base is Map && edited is Map) {
    final out = <String, Object?>{};
    for (final k in base.keys) {
      if (!edited.containsKey(k)) out['$k'] = null;
    }
    for (final e in edited.entries) {
      if (!base.containsKey(e.key)) {
        out['${e.key}'] = e.value;
      } else if (jsonEncode(base[e.key]) != jsonEncode(e.value)) {
        out['${e.key}'] = (base[e.key] is Map && e.value is Map) ? mergePatchBetween(base[e.key], e.value) : e.value;
      }
    }
    return out;
  }
  return edited;
}
