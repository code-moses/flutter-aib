import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

/// A hosted decider in front of a local episode: the case the whole
/// side-call mechanism exists for (`AgentDecision.sideCallsKey`).
const _pricing = PriceTable(
  models: {
    'qwen3:8b': ModelPrice(promptPerMTok: 0, completionPerMTok: 0, nominal: true),
    'jev-1': ModelPrice(promptPerMTok: 0.042, completionPerMTok: 0),
  },
);

EpisodeTrace _trace({JsonMap extra = const {}}) {
  var seq = 0;
  var t = 0;
  TraceEvent event(String type, JsonMap data) => TraceEvent(seq: seq++, tUs: t += 1000, type: type, data: data);
  return EpisodeTrace(
    meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'prepared', environmentId: 'env', repetition: 1, startedAt: DateTime(2026)),
    events: [
      event(TraceEventTypes.episodeStart, const {}),
      event(TraceEventTypes.agentEnvelope, {
        'seq': 0,
        'key': 'intents.catalog',
        'kind': 'observe',
        'payload': const <String, Object?>{},
        'decision': AgentDecision(model: 'qwen3:8b', tokensPrompt: 1000000, tokensCompletion: 0, extra: extra).toJson(),
      }),
      event(TraceEventTypes.envResult, const {'seq': 0, 'status': 'ok'}),
      event(TraceEventTypes.episodeEnd, const {'reason': 'done', 'wallClockMs': 1}),
    ],
  );
}

Map<String, num?> _metrics(EpisodeTrace trace) => MetricsRegistry.builtin(pricing: _pricing).computeAll(
  MetricContext(
    trace: trace,
    task: const TaskSpec(
      id: 't',
      title: 't',
      instruction: 'do it',
      budget: Budget(maxSteps: 9, maxWallClockSeconds: 9),
      fixture: FixtureRef(id: 'f', data: {}),
    ),
    verdict: Verdict.success(),
  ),
);

void main() {
  test('a side call is priced by its own model, not the episode\'s', () {
    final m = _metrics(
      _trace(
        extra: {
          AgentDecision.sideCallsKey: [const SideCall(purpose: 'route', model: 'jev-1.13.0', tokensPrompt: 1000000, latencyMs: 300).toJson()],
        },
      ),
    );
    // The episode's own million tokens are nominal (local); the decider's
    // million cost the hosted rate.
    expect(m['cost_usd'], closeTo(0.042, 1e-9));
    expect(m['side_call_cost_usd'], closeTo(0.042, 1e-9));
    expect(m['side_call_tokens'], 1000000);
    expect(m['side_call_count'], 1);
    expect(m['side_call_latency_ms'], 300);
    // Side-call tokens are not the agent's own context and must not inflate
    // the budget the episode is measured against.
    expect(m['tokens_total'], 1000000);
  });

  test('an episode without side calls reports none, not zero', () {
    final m = _metrics(_trace());
    expect(m['cost_usd'], 0);
    expect(m['side_call_cost_usd'], isNull);
    expect(m['side_call_count'], isNull);
  });

  test('a side call on an unpriced model leaves the cost unclaimed', () {
    final m = _metrics(
      _trace(
        extra: {
          AgentDecision.sideCallsKey: [const SideCall(purpose: 'route', model: 'some-unlisted-decider', tokensPrompt: 500).toJson()],
        },
      ),
    );
    expect(m['side_call_cost_usd'], isNull);
    expect(m['side_call_tokens'], 500, reason: 'tokens are known either way');
  });

  test('SideCall survives a round trip through the trace', () {
    const call = SideCall(purpose: 'route', model: 'jev-1.13.0', tokensPrompt: 612, latencyMs: 705);
    final decision = AgentDecision(
      model: 'qwen3:8b',
      extra: {
        AgentDecision.sideCallsKey: [call.toJson()],
      },
    );
    final restored = AgentDecision.fromJson(decision.toJson()).sideCalls.single;
    expect(restored.purpose, 'route');
    expect(restored.model, 'jev-1.13.0');
    expect(restored.tokensTotal, 612);
    expect(restored.latencyMs, 705);
    expect(restored.calls, 1);
  });
}
