import 'dart:convert';
import 'dart:io';

import 'package:aib_mcp/aib_mcp.dart' show yamlToJson;
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

typedef Json = Map<String, Object?>;

/// [v] as a JSON object; empty for anything else.
Json jsonObject(Object? v) => v is Map ? {for (final e in v.entries) '${e.key}': e.value} : {};

/// The holdout of suite [name], next to the suite at `splits/<name>.yaml`.
Set<String> readHoldout(String suitePath, String name) {
  final split = File(p.join(p.dirname(suitePath), 'splits', '$name.yaml'));
  if (!split.existsSync()) return const {};
  try {
    final y = loadYaml(split.readAsStringSync());
    return {for (final id in (y is Map ? y['holdout'] as List? : null) ?? const []) '$id'};
  } on Object {
    return const {};
  }
}

/// Reads run directories as plain files: `run_manifest.json`, `metrics.csv`,
/// `verdicts.json`, `traces/*.jsonl`. It knows the formats, not the framework,
/// so a folder copied from another machine or an older checkout reads the
/// same way — and nothing here writes into a run.
final class RunReader {
  RunReader({this.workspaceRoot, this.showHoldout = false});

  /// Whether task text of a suite's holdout split is shown. The framework hides
  /// it from tuning agents; a UI shows it to a person only on request.
  final bool showHoldout;

  /// The checkout, when one is known; suites are looked up under it.
  final String? workspaceRoot;

  static const manifestFile = 'run_manifest.json';

  final _summaries = <String, (String, Json)>{};
  final _details = <String, (String, Json)>{};

  static bool isRun(String dir) => File(p.join(dir, manifestFile)).existsSync();

  /// Run directories under [root] (a run is a directory with a manifest;
  /// the search stops at one), at most [depth] levels down.
  static List<String> find(String root, {int depth = 4}) {
    final found = <String>[];
    void walk(Directory dir, int left) {
      if (isRun(dir.path)) {
        found.add(dir.path);
        return;
      }
      if (left == 0) return;
      List<FileSystemEntity> children;
      try {
        children = dir.listSync(followLinks: false);
      } on FileSystemException {
        return;
      }
      for (final child in children.whereType<Directory>()) {
        if (p.basename(child.path).startsWith('.')) continue;
        walk(child, left - 1);
      }
    }

    walk(Directory(root), depth);
    found.sort();
    return found;
  }

  // Summary (the run list)

  String _signature(String dir) {
    String stamp(String name) {
      final f = File(p.join(dir, name));
      return f.existsSync() ? '${f.lastModifiedSync().microsecondsSinceEpoch}:${f.lengthSync()}' : '-';
    }

    final traces = Directory(p.join(dir, 'traces'));
    return [
      stamp(manifestFile),
      stamp('metrics.csv'),
      stamp('verdicts.json'),
      traces.existsSync() ? '${traces.statSync().modified.microsecondsSinceEpoch}' : '-',
    ].join('|');
  }

  Json summary(String dir, String libraryDir) {
    final sig = _signature(dir);
    final hit = _summaries[dir];
    if (hit != null && hit.$1 == sig) return {...hit.$2, 'id': p.relative(dir, from: libraryDir)};
    final built = _buildSummary(dir);
    _summaries[dir] = (sig, built);
    return {...built, 'id': p.relative(dir, from: libraryDir)};
  }

  Json _buildSummary(String dir) {
    final Json manifest;
    try {
      manifest = _readJson(p.join(dir, manifestFile)) as Json;
    } on Object catch (e) {
      return {'dir': dir, 'name': p.basename(dir), 'error': 'manifest unreadable: $e'};
    }
    final agents = [for (final e in jsonObject(manifest['agents']).entries) _agentView(e.key, jsonObject(e.value))];
    final models = jsonObject(jsonObject(manifest['extra'])['models']);
    for (final a in agents) {
      final m = jsonObject(models[a['id']]);
      a['provider'] ??= m['provider'];
      a['model'] ??= m['model'];
      if (m['details'] is Map) a['modelDetails'] = m['details'];
      a['digest'] = m['digest'];
    }
    final launches = _launches(dir);
    final launch = launches.isEmpty ? null : launches.last;
    final traces = Directory(p.join(dir, 'traces'));
    final traceCount = traces.existsSync() ? traces.listSync().where((f) => f.path.endsWith('.jsonl')).length : 0;
    final verdicts = _readVerdictsFile(dir);
    final judge = jsonObject(verdicts?['judge']);
    final stats = _statsFromCsv(dir);
    final suite = jsonObject(manifest['suite']);
    final platform = jsonObject(manifest['platform']);

    Set<String> collect(String key) => {
      for (final a in agents)
        if (a[key] != null && '${a[key]}'.isNotEmpty) '${a[key]}',
    };
    final facets = <String, List<String>>{
      'suite': ['${suite['name']}'],
      'agent': collect('id').toList(),
      'kind': collect('version').toList(),
      'model': collect('model').toList(),
      'provider': collect('provider').toList(),
      'prompt': collect('promptVersion').toList(),
      'router': collect('router').toList(),
      'toolCalling': collect('toolCalling').toList(),
      'environment': ['${jsonObject(manifest['environment'])['id']}'],
      if (launch?['study'] != null) 'study': ['${launch!['study']}'],
      if (launch?['config'] != null) 'config': ['${launch!['config']}'],
      if (launch?['runner'] != null) 'runner': ['${launch!['runner']}'],
      if (judge['judgeId'] != null) 'judge': ['${judge['judgeId']}'],
      if (platform['operatingSystem'] != null) 'os': ['${platform['operatingSystem']}'],
      'evaluated': [verdicts != null ? 'yes' : 'no'],
    };
    return {
      'dir': dir,
      'name': p.basename(dir),
      'runId': manifest['runId'],
      'createdAt': manifest['createdAt'],
      'suite': suite['name'],
      'suiteHash': suite['hash'],
      'environment': jsonObject(manifest['environment'])['id'],
      'repetitions': manifest['repetitions'],
      'seed': manifest['seed'],
      'taskCount': (manifest['taskOrder'] as List?)?.length ?? 0,
      'agents': agents,
      'facets': facets,
      'cfg': _flatConfig(agents, manifest),
      'launch': launch,
      'launches': launches.length,
      'traces': traceCount,
      'evaluated': verdicts != null,
      'judge': judge.isEmpty ? null : {'id': judge['judgeId'], 'k': judge['k'], 'model': judge['pinnedModel'], 'at': judge['evaluatedAt']},
      'stats': stats,
      'framework': manifest['frameworkVersion'],
    };
  }

  Json _agentView(String id, Json a) {
    final md = jsonObject(a['metadata']);
    final cfg = jsonObject(md['agentConfig']);
    final router = jsonObject(md['routerConfig']);
    final llm = jsonObject(md['llm']);
    return {
      'id': id,
      'version': a['version'],
      'description': a['description'],
      'model': md['model'] ?? llm['model'],
      'provider': md['provider'] ?? llm['provider'],
      'temperature': md['temperature'] ?? cfg['temperature'],
      'promptVersion': md['promptVersion'],
      'promptHash': md['promptHash'],
      'agentConfigHash': md['agentConfigHash'],
      'routerConfigHash': md['routerConfigHash'],
      'router': router['router'] == null
          ? null
          : '${router['router']}${router['strategies'] is List ? ' · ${(router['strategies'] as List).join('+')}' : ''}',
      'profile': router['profile'],
      'toolCalling': cfg['toolCalling'],
      'contextWindow': md['contextWindow'],
    };
  }

  Json _flatConfig(List<Json> agents, Json manifest) {
    final out = <String, Object?>{};
    final all = jsonObject(manifest['agents']);
    final multi = all.length > 1;
    for (final e in all.entries) {
      final md = jsonObject(jsonObject(e.value)['metadata']);
      final flat = <String, Object?>{};
      _flatten('', md, flat);
      _flatten('', {'version': jsonObject(e.value)['version']}, flat);
      for (final f in flat.entries) {
        out[multi ? '${e.key}:${f.key}' : f.key] = f.value;
      }
    }
    return out;
  }

  static void _flatten(String prefix, Object? v, Map<String, Object?> out) {
    if (v is Map) {
      for (final e in v.entries) {
        _flatten(prefix.isEmpty ? '${e.key}' : '$prefix.${e.key}', e.value, out);
      }
    } else if (v is List) {
      out[prefix] = v.every((x) => x is! Map && x is! List) ? v.join(', ') : jsonEncode(v);
    } else {
      out[prefix] = v;
    }
  }

  List<Json> _launches(String dir) {
    for (final name in ['aib_mcp_launch.json', 'aib_ui_launch.json']) {
      final f = File(p.join(dir, name));
      if (!f.existsSync()) continue;
      try {
        final v = jsonDecode(f.readAsStringSync());
        if (v is List) return [for (final x in v) jsonObject(x)];
        if (v is Map) return [jsonObject(v)];
      } on Object {
        return const [];
      }
    }
    return const [];
  }

  Json? _readVerdictsFile(String dir) {
    final f = File(p.join(dir, 'verdicts.json'));
    if (!f.existsSync()) return null;
    try {
      return jsonObject(jsonDecode(f.readAsStringSync()));
    } on Object {
      return null;
    }
  }

  /// Headline numbers from metrics.csv, without a pass over the traces.
  Json? _statsFromCsv(String dir) {
    final rows = readMetrics(dir);
    if (rows == null) return null;
    final episodes = rows.values.toList();
    double? mean(String metric) {
      final xs = [
        for (final e in episodes)
          if ((e['metrics'] as Map)[metric] case final num v) v.toDouble(),
      ];
      return xs.isEmpty ? null : xs.reduce((a, b) => a + b) / xs.length;
    }

    double? sum(String metric) {
      final xs = [
        for (final e in episodes)
          if ((e['metrics'] as Map)[metric] case final num v) v.toDouble(),
      ];
      return xs.isEmpty ? null : xs.reduce((a, b) => a + b);
    }

    final verdicts = <String, int>{};
    for (final e in episodes) {
      verdicts['${e['verdict']}'] = (verdicts['${e['verdict']}'] ?? 0) + 1;
    }
    return {
      'episodes': episodes.length,
      'success': mean('success'),
      'weighted': mean('weighted_score'),
      'tokens': mean('tokens_total'),
      'costUsd': sum('cost_usd'),
      'wallMs': mean('wall_clock_ms'),
      'steps': mean('action_count'),
      'verdicts': verdicts,
    };
  }

  // metrics.csv

  /// episode id → {taskId, agentId, rep, verdict, score, metrics{name: value}}.
  Map<String, Json>? readMetrics(String dir) {
    final f = File(p.join(dir, 'metrics.csv'));
    if (!f.existsSync()) return null;
    final out = <String, Json>{};
    var first = true;
    late List<String> header;
    for (final line in const LineSplitter().convert(f.readAsStringSync())) {
      if (line.isEmpty) continue;
      final cells = parseCsvLine(line);
      if (first) {
        header = cells;
        first = false;
        continue;
      }
      final row = {for (var i = 0; i < header.length && i < cells.length; i++) header[i]: cells[i]};
      final id = row['episode_id'] ?? '';
      final ep = out.putIfAbsent(
        id,
        () => <String, Object?>{
          'id': id,
          'taskId': row['task_id'],
          'agentId': row['agent_id'],
          'rep': int.tryParse(row['repetition'] ?? ''),
          'verdict': row['verdict'],
          'score': double.tryParse(row['score'] ?? ''),
          'metrics': <String, Object?>{},
        },
      );
      final v = row['value'] ?? '';
      (ep['metrics'] as Map<String, Object?>)[row['metric'] ?? ''] =
          num.tryParse(v) ??
          (v == 'true'
              ? 1
              : v == 'false'
              ? 0
              : v);
    }
    return out;
  }

  static List<String> parseCsvLine(String line) {
    final cells = <String>[];
    final b = StringBuffer();
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (quoted) {
        if (c == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            b.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          b.write(c);
        }
      } else if (c == '"') {
        quoted = true;
      } else if (c == ',') {
        cells.add(b.toString());
        b.clear();
      } else {
        b.write(c);
      }
    }
    cells.add(b.toString());
    return cells;
  }

  // Detail

  Json detail(String dir, String libraryDir) {
    final sig = _signature(dir);
    final hit = _details[dir];
    if (hit != null && hit.$1 == sig) return hit.$2;
    final built = _buildDetail(dir, libraryDir);
    _details[dir] = (sig, built);
    return built;
  }

  Json _buildDetail(String dir, String libraryDir) {
    final manifest = _readJson(p.join(dir, manifestFile)) as Json;
    final extra = Map<String, Object?>.of(jsonObject(manifest['extra']));
    final pricing = extra.remove('pricing');
    final verdicts = _readVerdictsFile(dir);
    final metrics = readMetrics(dir) ?? <String, Json>{};
    final traces = <String, Json>{};
    final traceDir = Directory(p.join(dir, 'traces'));
    if (traceDir.existsSync()) {
      final files = traceDir.listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl')).toList()..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        traces[p.basenameWithoutExtension(f.path)] = _traceSummary(f);
      }
    }
    final verdictMap = jsonObject(verdicts?['verdicts']);
    final ids = <String>{...metrics.keys, ...traces.keys, ...verdictMap.keys}.toList()..sort();
    final episodes = <Json>[];
    for (final id in ids) {
      final m = metrics[id];
      final t = traces[id];
      final v = jsonObject(verdictMap[id]);
      episodes.add({
        'id': id,
        'taskId': m?['taskId'] ?? t?['taskId'],
        'agentId': m?['agentId'] ?? t?['agentId'],
        'rep': m?['rep'] ?? t?['rep'],
        'verdict': m?['verdict'] ?? v['type'],
        'score': m?['score'] ?? v['score'],
        'label': v['label'],
        'criteria': v['details'],
        'metrics': m?['metrics'] ?? <String, Object?>{},
        'trace': t,
      });
    }
    final launches = _launches(dir);
    final files = [
      for (final e in Directory(dir).listSync().whereType<File>())
        {'name': p.basename(e.path), 'bytes': e.lengthSync(), 'modified': e.lastModifiedSync().toIso8601String()},
    ]..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    return {
      ...summary(dir, libraryDir),
      'manifest': {...manifest, 'extra': extra},
      'pricing': pricing,
      'judgeFull': verdicts == null
          ? null
          : {'judge': verdicts['judge'], 'scoredWith': verdicts['scoredWith'], 'metricProviders': verdicts['metricProviders']},
      'launchesFull': launches,
      'taskOrder': manifest['taskOrder'],
      'episodes': episodes,
      'tasks': _tasks(dir, jsonObject(manifest['suite'])),
      'files': files,
    };
  }

  /// First/last lines are enough for identity and the end; one pass counts
  /// the steps and tokens.
  Json _traceSummary(File f) {
    String? taskId, agentId, startedAt, endReason, endMessage, title;
    int? rep, wallMs;
    var steps = 0, errors = 0, tokens = 0, promptTokens = 0, completionTokens = 0, llmMs = 0, events = 0, budgetSteps = 0;
    for (final line in f.readAsLinesSync()) {
      if (line.isEmpty) continue;
      events++;
      // Cheap type sniff before decoding: payloads can be large.
      final isEnv = line.contains('"type":"agent.envelope"') || line.contains('"type": "agent.envelope"');
      Json? r;
      final badResult = line.contains('"env.result"') && !line.contains('"status":"ok"') && !line.contains('"status": "ok"');
      if (events <= 2 || line.contains('"episode.end"') || isEnv || badResult || line.contains('"episode.start"')) {
        try {
          r = jsonObject(jsonDecode(line));
        } on Object {
          continue;
        }
      }
      if (r == null) continue;
      final data = jsonObject(r['data']);
      switch (r['type']) {
        case 'episode.meta':
          taskId = data['taskId'] as String?;
          agentId = data['agentId'] as String?;
          rep = (data['repetition'] as num?)?.toInt();
          startedAt = data['startedAt'] as String?;
        case 'episode.start':
          final task = jsonObject(data['task']);
          title = task['title'] as String?;
          budgetSteps = (jsonObject(task['budget'])['maxSteps'] as num?)?.toInt() ?? 0;
        case 'agent.envelope':
          steps++;
          final d = jsonObject(data['decision']);
          promptTokens += (d['tokensPrompt'] as num?)?.toInt() ?? 0;
          completionTokens += (d['tokensCompletion'] as num?)?.toInt() ?? 0;
          llmMs += (d['llmLatencyMs'] as num?)?.toInt() ?? 0;
        case 'env.result':
          if (data['status'] != 'ok') errors++;
        case 'episode.end':
          endReason = data['reason'] as String?;
          endMessage = data['message'] as String?;
          wallMs = (data['wallClockMs'] as num?)?.toInt();
      }
    }
    tokens = promptTokens + completionTokens;
    return {
      'taskId': taskId,
      'agentId': agentId,
      'rep': rep,
      'startedAt': startedAt,
      'title': title,
      'endReason': endReason,
      'endMessage': endMessage,
      'wallMs': wallMs,
      'steps': steps,
      'maxSteps': budgetSteps,
      'envErrors': errors,
      'tokens': tokens,
      'tokensPrompt': promptTokens,
      'tokensCompletion': completionTokens,
      'llmMs': llmMs,
      'events': events,
      'bytes': f.lengthSync(),
    };
  }

  List<Json> trace(String dir, String episodeId) {
    if (!RegExp(r'^[^/\\]+$').hasMatch(episodeId)) throw ArgumentError('bad episode id');
    final f = File(p.join(dir, 'traces', '$episodeId.jsonl'));
    if (!f.existsSync()) throw FileSystemException('no trace', f.path);
    final out = <Json>[];
    for (final line in f.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      try {
        out.add(jsonObject(jsonDecode(line)));
      } on Object {
        out.add({
          'type': 'trace.unreadable',
          'data': {'line': line.length > 300 ? '${line.substring(0, 300)}…' : line},
        });
      }
    }
    return out;
  }

  // Suites

  /// Tasks of the run's suite, when the suite file can be found: next to a
  /// checkout above the run, or in the workspace. Ground truth stays out.
  List<Json> _tasks(String dir, Json suite) {
    final name = '${suite['name']}';
    final candidates = <String>[
      if (workspaceRoot != null) p.join(workspaceRoot!, 'suites', '$name.yaml'),
      if (workspaceRoot != null && suite['path'] is String) p.normalize(p.join(workspaceRoot!, 'apps', 'todo_app', suite['path'] as String)),
    ];
    var d = p.dirname(dir);
    for (var i = 0; i < 5; i++) {
      candidates.add(p.join(d, 'suites', '$name.yaml'));
      final up = p.dirname(d);
      if (up == d) break;
      d = up;
    }
    for (final path in candidates) {
      final f = File(path);
      if (!f.existsSync()) continue;
      try {
        return suiteTasks(f.readAsStringSync(), holdout: readHoldout(path, name), hideHoldout: !showHoldout);
      } on Object {
        continue;
      }
    }
    return const [];
  }

  static List<Json> suiteTasks(String yamlText, {Set<String> holdout = const {}, bool hideHoldout = false}) {
    final y = yamlToJson(loadYaml(yamlText));
    final root = jsonObject(y);
    final defaults = jsonObject(root['defaults']);
    return [
      for (final t in (root['tasks'] as List? ?? const []))
        if (t is Map)
          if (hideHoldout && holdout.contains(t['id']))
            {
              'id': t['id'],
              'title': null,
              'instruction': null,
              'tags': const [],
              'requiredTools': const [],
              'criteria': const [],
              'budget': const {},
              'holdout': true,
            }
          else
            {
              'id': t['id'],
              'title': t['title'],
              'instruction': t['instruction'] is String ? (t['instruction'] as String).trim() : t['instruction'],
              'tags': t['tags'] ?? const [],
              'optimalSteps': t['optimalSteps'],
              'requiredTools': t['requiredTools'] ?? const [],
              'repetitions': t['repetitions'] ?? defaults['repetitions'],
              'budget': {...jsonObject(defaults['budget']), ...jsonObject(t['budget'])},
              'criteria': [
                for (final c in [...?(defaults['criteria'] as List?), ...?(t['successCriteria'] as List?)])
                  if (c is Map) {'type': c['type'], 'weight': c['weight']},
              ],
              'holdout': holdout.contains(t['id']),
            },
    ];
  }

  static Object? _readJson(String path) => jsonDecode(File(path).readAsStringSync());
}
