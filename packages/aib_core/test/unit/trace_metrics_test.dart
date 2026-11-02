import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

EpisodeTrace _trace(List<TraceEvent> events) => EpisodeTrace(
  meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'hybrid', environmentId: 'env', repetition: 1, startedAt: DateTime(2026, 9, 3)),
  events: events,
);

TraceEvent _envelope(int seq, {required String key, String kind = 'act', JsonMap payload = const {}, String? note}) => TraceEvent(
  seq: seq * 2,
  tUs: seq * 1000,
  type: TraceEventTypes.agentEnvelope,
  data: {
    'seq': seq,
    'key': key,
    'kind': kind,
    'payloadBytes': jsonSizeBytes(payload),
    'payload': payload,
    if (note != null) 'decision': {'note': note, 'tokensPrompt': 0, 'tokensCompletion': 0},
  },
);

TraceEvent _result(int seq, {String status = 'ok', JsonMap payload = const {}, JsonMap? error, int? userWaitMs}) => TraceEvent(
  seq: seq * 2 + 1,
  tUs: seq * 1000 + 500,
  type: TraceEventTypes.envResult,
  data: {
    'seq': seq,
    'status': status,
    'payloadBytes': jsonSizeBytes(payload),
    'payload': payload,
    'handleMs': 1,
    'userWaitMs': ?userWaitMs,
    'error': ?error,
  },
);

TraceEvent _end(String reason, {String? message}) =>
    TraceEvent(seq: 999, tUs: 999000, type: TraceEventTypes.episodeEnd, data: {'reason': reason, 'message': ?message, 'wallClockMs': 1000});

num? _metric(String name, EpisodeTrace trace) => MetricsRegistry.builtin().computeAll(MetricContext(trace: trace))[name];

void main() {
  group('metrics read off the trace', () {
    test('user.ask is not counted as a redundant app action', () {
      // Two app actions (one changed state, one did not) plus one user.ask.
      // Without the exclusion the ratio would be 2/3 instead of 1/2.
      final trace = _trace([
        TraceEvent(
          seq: 98,
          tUs: 0,
          type: TraceEventTypes.envDescriptor,
          data: const {
            'envelopes': [
              {'key': 'user.ask', 'blocksOnUser': true},
            ],
          },
        ),
        // Initial state, recorded right after reset.
        TraceEvent(seq: 99, tUs: 1, type: TraceEventTypes.stateFingerprint, data: {'seq': -1, 'fingerprint': 'a'}),
        _envelope(0, key: 'intents.invoke'),
        _result(0),
        TraceEvent(seq: 100, tUs: 100, type: TraceEventTypes.stateFingerprint, data: {'seq': 0, 'fingerprint': 'b'}),
        _envelope(1, key: 'user.ask', payload: {'type': 'pick'}),
        _result(1, userWaitMs: 4000),
        TraceEvent(seq: 101, tUs: 101, type: TraceEventTypes.stateFingerprint, data: {'seq': 1, 'fingerprint': 'b'}),
        _envelope(2, key: 'intents.invoke'),
        _result(2),
        TraceEvent(seq: 102, tUs: 102, type: TraceEventTypes.stateFingerprint, data: {'seq': 2, 'fingerprint': 'b'}),
        _end('done'),
      ]);
      expect(_metric('redundant_action_ratio', trace), closeTo(0.5, 1e-9));
      expect(_metric('user_wait_ms', trace), 4000);
    });

    test('routing is read back off the decision notes', () {
      final trace = _trace([
        _envelope(0, key: 'intents.catalog', kind: 'observe', note: 'bootstrap route=intents'),
        _result(0),
        _envelope(1, key: 'intents.invoke', note: 'route=intents'),
        _result(1, status: 'failed'),
        _envelope(2, key: 'semantics.tap', note: 'route=semantics reason=escalation from intents on failed'),
        _result(2),
        _end('done'),
      ]);
      expect(_metric('strategy_switch_count', trace), 1);
      expect(_metric('escalation_count', trace), 1);
    });

    test('an agent that routes nothing reports null, not zero', () {
      final trace = _trace([_envelope(0, key: 'semantics.tree', kind: 'observe'), _result(0), _end('done')]);
      expect(_metric('strategy_switch_count', trace), isNull);
      expect(_metric('escalation_count', trace), isNull);
    });

    test('a context-length abort is not the same as giving up', () {
      final overflow = _trace([
        _envelope(0, key: 'semantics.tree', kind: 'observe'),
        _result(0),
        _end('abort', message: 'llm_error:contextLength: maximum context length'),
      ]);
      expect(_metric('abort_context_length', overflow), 1);
      expect(_metric('abort_agent_decision', overflow), 0);

      final gaveUp = _trace([
        _envelope(0, key: 'semantics.tree', kind: 'observe'),
        _result(0),
        _end('abort', message: 'no way to do this without a delete action'),
      ]);
      expect(_metric('abort_context_length', gaveUp), 0);
      expect(_metric('abort_agent_decision', gaveUp), 1);

      final finished = _trace([_envelope(0, key: 'semantics.tree', kind: 'observe'), _result(0), _end('done')]);
      expect(_metric('abort_context_length', finished), isNull);
      expect(_metric('abort_agent_decision', finished), isNull);
    });

    test('schema violations are counted apart from app failures', () {
      final trace = _trace([
        _envelope(0, key: 'intents.invoke'),
        _result(0, status: 'failed', error: {'code': 'bad_params', 'message': 'x'}),
        _envelope(1, key: 'intents.invoke'),
        _result(1, status: 'failed', error: {'code': 'handler_error', 'message': 'y'}),
        _end('done'),
      ]);
      expect(_metric('invalid_tool_call_count', trace), 1);
      expect(_metric('failed_envelope_count', trace), 2);
    });

    test('truncated results are visible in the report', () {
      final trace = _trace([
        _envelope(0, key: 'intents.invoke', kind: 'observe'),
        _result(0, payload: {'truncated': true, 'totalCount': 900}),
        _end('done'),
      ]);
      expect(_metric('truncated_result_count', trace), 1);
    });
  });
}
