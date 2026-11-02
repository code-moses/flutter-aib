import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

typedef _Step = ({String key, String kind, JsonMap payload, JsonMap result, JsonMap decision});

_Step _step(
  String key, {
  String kind = 'observe',
  JsonMap payload = const {},
  JsonMap result = const {'status': 'ok', 'payload': <String, Object?>{}},
  JsonMap decision = const {},
}) => (key: key, kind: kind, payload: payload, result: result, decision: decision);

EpisodeTrace _trace(List<_Step> steps, {String end = 'done', String? message, JsonMap agent = const {}}) {
  var seq = 0;
  var t = 0;
  TraceEvent event(String type, JsonMap data) => TraceEvent(seq: seq++, tUs: t += 1000, type: type, data: data);
  return EpisodeTrace(
    meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'a', environmentId: 'env', repetition: 1, startedAt: DateTime(2026)),
    events: [
      event(TraceEventTypes.episodeStart, {'agent': agent}),
      // The user bridge declares its key as waiting on a person; that is
      // how the core tells asking the user from operating the app.
      event(TraceEventTypes.envDescriptor, const {
        'envelopes': [
          {'key': 'user.ask', 'blocksOnUser': true},
        ],
      }),
      for (final (i, s) in steps.indexed) ...[
        event(TraceEventTypes.agentEnvelope, {'seq': i, 'key': s.key, 'kind': s.kind, 'payload': s.payload, 'decision': s.decision}),
        event(TraceEventTypes.envResult, {'seq': i, ...s.result}),
      ],
      event(TraceEventTypes.episodeEnd, {'reason': end, 'message': ?message, 'wallClockMs': 1}),
    ],
  );
}

TaskSpec _task({bool abortIsAnAnswer = false, String instruction = 'do it'}) => TaskSpec(
  id: 't',
  title: 't',
  instruction: instruction,
  budget: const Budget(maxSteps: 9, maxWallClockSeconds: 9),
  fixture: const FixtureRef(id: 'f', data: {}),
  abortIsAnAnswer: abortIsAnAnswer,
);

Map<String, num?> _metrics(EpisodeTrace trace, {TaskSpec? task, Verdict? verdict}) =>
    MetricsRegistry.builtin().computeAll(MetricContext(trace: trace, task: task ?? _task(), verdict: verdict ?? Verdict.failure('x')));

void main() {
  test('the same answer to a different request is uninformative; a repeat is not', () {
    final m = _metrics(
      _trace([
        _step('app.endpoints'),
        _step('app.endpoints', result: {'status': 'ok', 'answerIndex': 1}),
        _step('app.endpoints', result: {'status': 'ok', 'answerIndex': 2, 'repeatIndex': 1}),
      ]),
    );
    expect(m['uninformative_result_count'], 1);
  });

  test('discovery is what was read before the first app action', () {
    final m = _metrics(
      _trace([
        _step('intents.catalog'),
        _step('user.ask', kind: 'act'),
        _step('intents.describe'),
        _step('intents.invoke', kind: 'act'),
        _step('intents.invoke'),
      ]),
    );
    expect(m['turns_to_first_act'], 3);
    expect(m['discovery_turn_count'], 2);
    expect(m['time_to_first_act_ms'], 8);
  });

  test('never acting leaves the discovery metrics null', () {
    final m = _metrics(_trace([_step('intents.catalog')]));
    expect(m['turns_to_first_act'], isNull);
    expect(m['discovery_turn_count'], isNull);
  });

  test('peak prompt and its share of the declared window', () {
    final m = _metrics(
      _trace(
        [
          _step('a', decision: {'tokensPrompt': 1000, 'llmCalls': 1, 'llmLatencyMs': 100}),
          _step('b', decision: {'tokensPrompt': 3000, 'llmCalls': 2, 'llmLatencyMs': 800}),
        ],
        agent: {
          'metadata': {'contextWindow': 4096},
        },
      ),
    );
    expect(m['peak_prompt_tokens'], 3000);
    expect(m['context_utilization'], closeTo(3000 / 4096, 1e-9));
    expect(m['llm_call_latency_p95'], greaterThan(100));
  });

  test('caching and reasoning are shares of what was spent, or nothing', () {
    final m = _metrics(
      _trace([
        _step('a', decision: {'tokensPrompt': 1000, 'tokensCompletion': 200, 'tokensCachedPrompt': 800, 'tokensReasoning': 150, 'llmCalls': 1}),
        _step('b', decision: {'tokensPrompt': 1000, 'tokensCompletion': 200, 'tokensCachedPrompt': 200, 'tokensReasoning': 50, 'llmCalls': 1}),
      ]),
    );
    expect(m['cache_hit_ratio'], closeTo(1000 / 2000, 1e-9));
    expect(m['reasoning_token_share'], closeTo(200 / 400, 1e-9));
  });

  test('a provider that reports no caching is null, never a missed cache', () {
    // Every local provider, and every run recorded before the field existed.
    // Zero would read as a cache that was there and missed.
    final m = _metrics(
      _trace([
        _step('a', decision: {'tokensPrompt': 1000, 'tokensCompletion': 200, 'llmCalls': 1}),
      ]),
    );
    expect(m['cache_hit_ratio'], isNull);
    expect(m['reasoning_token_share'], isNull);
  });

  test('refusing where refusing is not the answer is unwarranted', () {
    final aborted = _trace([_step('x')], end: 'abort', message: 'cannot be done');
    expect(_metrics(aborted)['unwarranted_abort'], 1);
    expect(_metrics(aborted, task: _task(abortIsAnAnswer: true))['unwarranted_abort'], 0);
    final llmFailure = _trace([_step('x')], end: 'abort', message: 'llm_error:contextLength: too long');
    expect(_metrics(llmFailure)['unwarranted_abort'], 0);
  });

  test('intent health groups by what the label names', () {
    String label(Exchange x) => x.key == 'intents.invoke' ? '${asJsonMap(x.envelope.data['payload'])['intent']}' : x.key;
    final rows = intentHealth(label: label, [
      _trace([
        _step(
          'intents.invoke',
          payload: {'intent': 'data.count'},
          result: {
            'status': 'failed',
            'error': {'code': 'bad_params', 'message': ''},
          },
        ),
        _step('intents.invoke', payload: {'intent': 'data.count'}),
        _step('intents.catalog'),
      ]),
    ]);
    final count = rows.firstWhere((r) => r.name == 'data.count');
    expect(count.calls, 2);
    expect(count.failed, 1);
    expect(count.badParams, 1);
    expect(intentHealthMarkdown(rows, episodes: 1), contains('| `data.count` | 2 | 100% | 50% | 50% |'));
  });
}
