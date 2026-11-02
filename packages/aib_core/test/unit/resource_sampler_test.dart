import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:test/test.dart';

/// A MockEnvironment that also reports a growing footprint.
final class _Sampling implements BenchmarkEnvironment, ResourceSampler {
  _Sampling({this.fails = false});

  final bool fails;
  final _inner = MockEnvironment();
  var _calls = 0;

  @override
  Future<JsonMap> sampleResources() async {
    if (fails) throw StateError('no counters here');
    _calls++;
    return {'rssBytes': 100 + _calls * 10, 'energyMj': 1000 + _calls * 5};
  }

  @override
  Future<EnvironmentDescriptor> describe() => _inner.describe();

  @override
  Future<void> reset(FixtureRef fixture) => _inner.reset(fixture);

  @override
  Future<EnvelopeResult> handle(Envelope envelope) => _inner.handle(envelope);

  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) => _inner.captureFinalState(queries);
}

final class _TwoStepAgent implements BenchmarkAgent {
  var _turn = 0;

  @override
  AgentManifest get manifest => const AgentManifest(agentId: 'two-step');

  @override
  Future<void> startEpisode(TaskSpec task, EnvironmentDescriptor environment) async {}

  @override
  Future<Envelope> next(EnvelopeResult? lastResult, BudgetStatus budget) async =>
      _turn++ < 2 ? const Envelope(key: 'state.noop', kind: .act) : Envelope.done(summary: 'ok');

  @override
  Future<void> endEpisode(EpisodeOutcome outcome) async {}
}

Future<EpisodeRunResult> _run(BenchmarkEnvironment environment) => BenchmarkEngine().runEpisode(
  task: const TaskSpec(
    id: 't',
    title: 't',
    instruction: 'Tu zweimal nichts.',
    budget: Budget(maxSteps: 9, maxWallClockSeconds: 30),
    fixture: FixtureRef(id: 'f', data: {}),
  ),
  agent: _TwoStepAgent(),
  environment: environment,
  meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'two-step', environmentId: 'mock', repetition: 1, startedAt: DateTime(2026)),
);

void main() {
  test('a sampler is read after reset and after every exchange', () async {
    final result = await _run(_Sampling());

    final samples = result.trace.byType(TraceEventTypes.resourceSample).toList();
    expect(samples.map((e) => e.data['seq']), [-1, 0, 1]);

    final metrics = MetricsRegistry.builtin().computeAll(MetricContext(trace: result.trace));
    expect(metrics['memory_peak_bytes'], 130);
    expect(metrics['energy_mj'], 10);
  });

  test('a sampler that fails costs a sample, not the episode', () async {
    final result = await _run(_Sampling(fails: true));

    expect(result.outcome.reason, TerminationReason.done);
    expect(result.trace.byType(TraceEventTypes.resourceSample), isEmpty);
    final metrics = MetricsRegistry.builtin().computeAll(MetricContext(trace: result.trace));
    expect(metrics['memory_peak_bytes'], isNull);
  });

  test('tokens_per_second leaves out the wait for the first token', () {
    TraceEvent envelope(int seq, Map<String, Object?> decision) => TraceEvent(
      seq: seq,
      tUs: seq,
      type: TraceEventTypes.agentEnvelope,
      data: {'seq': seq, 'key': 'state.noop', 'kind': 'act', 'decision': decision},
    );
    final trace = EpisodeTrace(
      meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'a', environmentId: 'mock', repetition: 0, startedAt: DateTime(2026)),
      events: [
        envelope(0, {'tokensCompletion': 50, 'llmLatencyMs': 1500, 'llmFirstTokenMs': 500}),
        envelope(1, {'tokensCompletion': 50, 'llmLatencyMs': 1000}),
      ],
    );

    final metrics = MetricsRegistry.builtin().computeAll(MetricContext(trace: trace));

    expect(metrics['tokens_per_second'], 50);
  });

  test('first_call_ttft_ms and tool_surface_changes read the per-call records', () {
    TraceEvent envelope(int seq, Map<String, Object?> decision) => TraceEvent(
      seq: seq,
      tUs: seq,
      type: TraceEventTypes.agentEnvelope,
      data: {'seq': seq, 'key': 'state.noop', 'kind': 'act', 'decision': decision},
    );
    Map<String, Object?> call(int ttft, String surface) => {'firstTokenMs': ttft, 'toolSurface': surface};
    final trace = EpisodeTrace(
      meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'a', environmentId: 'mock', repetition: 0, startedAt: DateTime(2026)),
      events: [
        // A decision without a model call (a prefetch) does not count as first.
        envelope(0, {'llmCalls': 0}),
        envelope(1, {
          'llmCalls': 2,
          'llmFirstTokenMs': 1400,
          'extra': {
            'llm': [call(1300, 'a'), call(100, 'a')],
          },
        }),
        envelope(2, {
          'llmCalls': 1,
          'extra': {
            'llm': [call(6500, 'b')],
          },
        }),
        envelope(3, {
          'llmCalls': 1,
          'extra': {
            'llm': [call(20, 'b')],
          },
        }),
      ],
    );

    final metrics = MetricsRegistry.builtin().computeAll(MetricContext(trace: trace));

    expect(metrics['first_call_ttft_ms'], 1300);
    expect(metrics['tool_surface_changes'], 1);
  });

  test('without per-call records the first calling decision stands in', () {
    final trace = EpisodeTrace(
      meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'a', environmentId: 'mock', repetition: 0, startedAt: DateTime(2026)),
      events: [
        TraceEvent(
          seq: 0,
          tUs: 0,
          type: TraceEventTypes.agentEnvelope,
          data: {
            'seq': 0,
            'key': 'state.noop',
            'kind': 'act',
            'decision': {'llmCalls': 1, 'llmFirstTokenMs': 900},
          },
        ),
      ],
    );

    final metrics = MetricsRegistry.builtin().computeAll(MetricContext(trace: trace));

    expect(metrics['first_call_ttft_ms'], 900);
    expect(metrics['tool_surface_changes'], isNull);
  });

  test('success_within_target scores a success against the task\'s targetSeconds', () {
    EpisodeTrace ended(int wallClockMs) => EpisodeTrace(
      meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'a', environmentId: 'mock', repetition: 0, startedAt: DateTime(2026)),
      events: [
        TraceEvent(seq: 0, tUs: 0, type: TraceEventTypes.episodeEnd, data: {'reason': 'done', 'wallClockMs': wallClockMs}),
      ],
    );
    TaskSpec task(int? target) => TaskSpec(
      id: 't',
      title: 't',
      instruction: 'open the list',
      budget: Budget(maxSteps: 5, maxWallClockSeconds: 120, targetSeconds: target),
      fixture: const FixtureRef(id: 'f', data: {}),
    );
    const success = Verdict(type: .success, score: 1);
    const failure = Verdict(type: .failure, score: 0);
    num? score(int ms, int? target, Verdict? verdict) =>
        MetricsRegistry.builtin().computeAll(MetricContext(trace: ended(ms), task: task(target), verdict: verdict))['success_within_target'];

    expect(score(9000, 10, success), 1);
    expect(score(10000, 10, success), 1);
    // Solved, but slower than the user waits.
    expect(score(60000, 10, success), 0);
    expect(score(5000, 10, failure), 0);
    expect(score(5000, null, success), isNull);
    expect(score(5000, 10, null), isNull);
  });
}
