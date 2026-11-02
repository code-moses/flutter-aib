import 'dart:convert';
import 'dart:io';

import 'package:aib_ui/aib_ui.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A run directory as the framework writes it, small enough to read by eye.
void writeRun(String dir, {bool evaluated = true}) {
  Directory(p.join(dir, 'traces')).createSync(recursive: true);
  File(p.join(dir, 'run_manifest.json')).writeAsStringSync(
    jsonEncode({
      'aib': '1.0',
      'runId': 'run-1',
      'createdAt': '2026-09-26T18:17:08',
      'suite': {'name': 'demo', 'hash': 'abc', 'path': '../suites/demo.yaml'},
      'agents': {
        'hybrid': {
          'agentId': 'hybrid',
          'version': 'hybrid_v4',
          'metadata': {
            'model': 'qwen3:8b',
            'promptVersion': 'hybrid_v4',
            'agentConfig': {'temperature': 0.0, 'toolCalling': 'constrained'},
            'routerConfig': {
              'router': 'union',
              'strategies': ['intents', 'user'],
            },
          },
        },
      },
      'environment': {'id': 'env', 'version': '1'},
      'repetitions': 2,
      'seed': 1,
      'taskOrder': ['t.one'],
      'platform': {'operatingSystem': 'macos'},
      'extra': {
        'models': {
          'hybrid': {'provider': 'ollama', 'model': 'qwen3:8b'},
        },
        'pricing': {'models': <String, Object?>{}},
      },
    }),
  );
  File(p.join(dir, 'aib_mcp_launch.json')).writeAsStringSync(
    jsonEncode(<Object?>[
      <String, Object?>{'config': 'experiments/x', 'study': 's1', 'runner': 'r'},
    ]),
  );
  if (evaluated) {
    File(p.join(dir, 'metrics.csv')).writeAsStringSync(
      [
        'run_id,episode_id,task_id,agent_id,repetition,verdict,score,metric,value',
        'run-1,t.one__hybrid__rep1,t.one,hybrid,1,success,1.0,tokens_total,1200',
        'run-1,t.one__hybrid__rep1,t.one,hybrid,1,success,1.0,success,1',
        'run-1,t.one__hybrid__rep1,t.one,hybrid,1,success,1.0,weighted_score,1.0',
        'run-1,t.one__hybrid__rep2,t.one,hybrid,2,failure,0.0,tokens_total,800',
        'run-1,t.one__hybrid__rep2,t.one,hybrid,2,failure,0.0,success,0',
        'run-1,t.one__hybrid__rep2,t.one,hybrid,2,failure,0.0,weighted_score,0.0',
      ].join('\n'),
    );
    File(p.join(dir, 'verdicts.json')).writeAsStringSync(
      jsonEncode({
        'judge': {'judgeId': 'j', 'k': 3, 'pinnedModel': 'm'},
        'verdicts': {
          't.one__hybrid__rep1': {
            'type': 'success',
            'score': 1.0,
            'details': {
              'finalStateMatch': {'score': 1.0, 'weight': 1.0, 'detail': 'ok'},
            },
          },
        },
      }),
    );
  }
  for (final rep in [1, 2]) {
    File(p.join(dir, 'traces', 't.one__hybrid__rep$rep.jsonl')).writeAsStringSync(
      [
        {
          'type': 'episode.meta',
          'data': {'taskId': 't.one', 'agentId': 'hybrid', 'repetition': rep, 'startedAt': '2026-09-26T18:18:00'},
        },
        {
          'seq': 0,
          'tUs': 1,
          'type': 'episode.start',
          'data': {
            'task': {
              'id': 't.one',
              'title': 'One',
              'budget': {'maxSteps': 5},
            },
          },
        },
        {
          'seq': 1,
          'tUs': 2,
          'type': 'agent.envelope',
          'data': {
            'seq': 0,
            'key': 'intents.invoke',
            'kind': 'act',
            'payloadBytes': 2,
            'payload': {'intent': 'a'},
            'decision': {'tokensPrompt': 100, 'tokensCompletion': 5, 'llmLatencyMs': 40},
          },
        },
        {
          'seq': 2,
          'tUs': 3,
          'type': 'env.result',
          'data': {'seq': 0, 'status': 'ok', 'payloadBytes': 2, 'payload': <String, Object?>{}, 'handleMs': 1},
        },
        {
          'seq': 3,
          'tUs': 4,
          'type': 'episode.end',
          'data': {'reason': 'done', 'message': 'fin', 'wallClockMs': 50},
        },
      ].map(jsonEncode).join('\n'),
    );
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('aib_ui_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('RunReader', () {
    test('finds runs up to a depth and stops at a manifest', () {
      writeRun(p.join(tmp.path, 'a'));
      writeRun(p.join(tmp.path, 'group', 'b'));
      Directory(p.join(tmp.path, 'a', 'nested')).createSync();
      expect(RunReader.find(tmp.path).map((d) => p.relative(d, from: tmp.path)), ['a', 'group/b']);
    });

    test('summarises config characteristics and headline numbers without opening traces', () {
      writeRun(p.join(tmp.path, 'a'));
      final s = RunReader().summary(p.join(tmp.path, 'a'), tmp.path);
      expect(s['id'], 'a');
      expect((s['facets'] as Map)['model'], ['qwen3:8b']);
      expect((s['facets'] as Map)['study'], ['s1']);
      expect((s['facets'] as Map)['toolCalling'], ['constrained']);
      expect((s['stats'] as Map)['success'], 0.5);
      expect((s['stats'] as Map)['tokens'], 1000);
      expect((s['cfg'] as Map)['agentConfig.toolCalling'], 'constrained');
    });

    test('an unevaluated run still lists, with episodes from its traces', () {
      writeRun(p.join(tmp.path, 'a'), evaluated: false);
      final reader = RunReader();
      expect(reader.summary(p.join(tmp.path, 'a'), tmp.path)['stats'], isNull);
      final d = reader.detail(p.join(tmp.path, 'a'), tmp.path);
      expect((d['episodes'] as List), hasLength(2));
      expect(((d['episodes'] as List).first as Map)['trace'], containsPair('steps', 1));
    });

    test('detail joins metrics, verdict criteria and trace summary per episode, minus the price table', () {
      writeRun(p.join(tmp.path, 'a'));
      final d = RunReader().detail(p.join(tmp.path, 'a'), tmp.path);
      final first = (d['episodes'] as List).first as Map;
      expect(first['verdict'], 'success');
      expect((first['criteria'] as Map).keys, ['finalStateMatch']);
      expect((first['metrics'] as Map)['tokens_total'], 1200);
      expect((first['trace'] as Map)['tokens'], 105);
      expect(((d['manifest'] as Map)['extra'] as Map).containsKey('pricing'), isFalse);
    });

    test('a cached summary is rebuilt when the files change', () async {
      final dir = p.join(tmp.path, 'a');
      writeRun(dir);
      final reader = RunReader();
      expect((reader.summary(dir, tmp.path)['stats'] as Map)['episodes'], 2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      File(
        p.join(dir, 'metrics.csv'),
      ).writeAsStringSync('run_id,episode_id,task_id,agent_id,repetition,verdict,score,metric,value\nr,e1,t,a,1,success,1,success,1\n');
      expect((reader.summary(dir, tmp.path)['stats'] as Map)['episodes'], 1);
    });

    test('csv cells may be quoted', () {
      expect(RunReader.parseCsvLine('a,"b,c","d ""e"""'), ['a', 'b,c', 'd "e"']);
    });

    test('the holdout split keeps its task text out unless asked', () {
      const yaml =
          'suite: s\ntasks:\n  - id: a\n    title: A\n    instruction: do a\n    tags: [x]\n  - id: b\n    title: B\n    instruction: do b\n';
      final hidden = RunReader.suiteTasks(yaml, holdout: {'b'}, hideHoldout: true);
      expect(hidden[1], containsPair('instruction', null));
      expect(hidden[1], containsPair('holdout', true));
      expect(hidden[0], containsPair('instruction', 'do a'));
      expect(RunReader.suiteTasks(yaml, holdout: {'b'})[1], containsPair('instruction', 'do b'));
    });

    test('a trace reads back event by event, and refuses a path as an episode id', () {
      writeRun(p.join(tmp.path, 'a'));
      final events = RunReader().trace(p.join(tmp.path, 'a'), 't.one__hybrid__rep1');
      expect(events.map((e) => e['type']), ['episode.meta', 'episode.start', 'agent.envelope', 'env.result', 'episode.end']);
      expect(() => RunReader().trace(p.join(tmp.path, 'a'), '../x'), throwsArgumentError);
    });
  });

  group('UiServer', () {
    late UiServer server;
    late HttpClient client;
    late String base;

    setUp(() async {
      writeRun(p.join(tmp.path, 'runs', 'a'));
      Directory(p.join(tmp.path, 'web')).createSync();
      File(p.join(tmp.path, 'web', 'index.html')).writeAsStringSync('<!doctype html>shell');
      server = await UiServer.serve(root: tmp.path, library: p.join(tmp.path, 'runs'), webDir: p.join(tmp.path, 'web'), port: 0);
      client = HttpClient();
      base = 'http://127.0.0.1:${server.port}';
    });
    tearDown(() async {
      client.close(force: true);
      await server.close();
    });

    Future<(int, String)> call(String method, String path, {Map<String, String> headers = const {}, Object? body}) async {
      final req = await client.openUrl(method, Uri.parse('$base$path'));
      headers.forEach(req.headers.set);
      if (body != null) req.write(jsonEncode(body));
      final res = await req.close();
      return (res.statusCode, await utf8.decoder.bind(res).join());
    }

    test('serves the shell and falls back to it for client routes', () async {
      expect((await call('GET', '/')).$2, contains('shell'));
      expect((await call('GET', '/run/whatever')).$2, contains('shell'));
      expect((await call('GET', '/missing.js')).$1, 404);
    });

    test('lists runs and reads one; without aib_mcp.yaml the framework routes say so', () async {
      final runs = jsonDecode((await call('GET', '/api/runs')).$2) as Map;
      expect((runs['runs'] as List).single['id'], 'a');
      final run = jsonDecode((await call('GET', '/api/run?run=a')).$2) as Map;
      expect(run['episodes'], hasLength(2));
      final fw = await call('GET', '/api/fw/suites');
      expect(fw.$1, 424);
      expect((jsonDecode((await call('GET', '/api/info')).$2) as Map)['framework'], false);
    });

    test('a file from a run folder is sandboxed, so its script cannot reach the API', () async {
      File(p.join(tmp.path, 'runs', 'a', 'report.html')).writeAsStringSync('<script></script>');
      final request = await client.getUrl(Uri.parse('$base/api/file?run=a&name=report.html'));
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 200);
      expect(response.headers.value('content-security-policy'), 'sandbox');
    });

    test('a run id cannot leave the opened folder', () async {
      expect((await call('GET', '/api/run?run=..%2F..')).$1, anyOf(403, 404));
      expect((await call('GET', '/api/file?run=a&name=..%2Fx')).$1, 400);
      expect((await call('GET', '/api/trace?run=a&episode=..%2Fx')).$1, 400);
    });

    test('refuses a foreign Host and a write without the header', () async {
      expect((await call('GET', '/api/info', headers: {'Host': 'evil.example'})).$1, 403);
      expect((await call('POST', '/api/user/annotate', body: {'dir': 'x'})).$1, 403);
    });

    test('lists a folder for the picker, marking runs', () async {
      final fs = jsonDecode((await call('GET', '/api/fs?path=${Uri.encodeComponent(p.join(tmp.path, 'runs'))}')).$2) as Map;
      expect((fs['entries'] as List).single, containsPair('isRun', true));
    });
  });

  test('mergePatchBetween produces the RFC 7386 patch that turns one config into another', () {
    final patch = mergePatchBetween(
      {
        'a': 1,
        'b': {'c': 2, 'd': 3},
        'gone': true,
      },
      {
        'a': 1,
        'b': {'c': 2, 'd': 4},
        'new': [1],
      },
    );
    expect(patch, {
      'b': {'d': 4},
      'gone': null,
      'new': [1],
    });
  });
}
