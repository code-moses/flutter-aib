import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:test/test.dart';

const _noop = Envelope(key: 'state.noop', kind: .act);

Future<List<String?>> _codes(BenchmarkEnvironment env, int calls) async {
  await env.reset(const FixtureRef(id: 'f'));
  return [for (var i = 0; i < calls; i++) (await env.handle(_noop)).error?.code];
}

void main() {
  BenchmarkEnvironment faults(BenchmarkEnvironment inner, FaultSchedule s) => PerturbedEnvironment.wrap(inner, [FaultPerturbation(s)]);

  group('FaultPerturbation', () {
    const schedule = FaultSchedule(seed: 7, failureRate: 0.3);

    test('the same seed meets the same faults, episode after episode', () async {
      final env = faults(MockEnvironment(), schedule);

      final first = await _codes(env, 40);
      final second = await _codes(env, 40);
      final other = await _codes(faults(MockEnvironment(), const FaultSchedule(seed: 8, failureRate: 0.3)), 40);

      expect(second, first);
      expect(first, contains('transient_failure'));
      expect(first, contains(isNull));
      expect(other, isNot(first));
    });

    test('meta envelopes and keys that wait on a user are never faulted', () async {
      final env = faults(_UserKeyEnvironment(), const FaultSchedule(seed: 1, failureRate: 1));
      // The user keys come from the descriptor, as the engine sees them.
      await env.describe();
      await env.reset(const FixtureRef(id: 'f'));

      final meta = await env.handle(const Envelope(key: 'meta.done', kind: .act));
      final ask = await env.handle(const Envelope(key: 'ask.person', kind: .act));
      final app = await env.handle(_noop);

      expect(meta.error?.details?['injected'], isNot(true));
      expect(ask.error?.details?['injected'], isNot(true));
      expect(app.error?.details?['injected'], isTrue);
    });

    test('one wrapper for any perturbations keeps the fingerprint probe', () async {
      final env = PerturbedEnvironment.wrap(MockEnvironment(), [FaultPerturbation(schedule), _Recorded()]);

      expect(env, isA<StateFingerprintProvider>());
      expect(await (env as ResourceSampler).sampleResources(), isEmpty);
      final perturbation = asJsonMap((await env.describe()).metadata['perturbation']);
      expect(asJsonMap(perturbation['faults'])['seed'], 7);
      expect(perturbation['recorded'], isTrue);
    });

    test('no perturbation is no wrapper', () {
      final inner = MockEnvironment();
      expect(PerturbedEnvironment.wrap(inner, const []), same(inner));
    });

    test('injected_fault_count counts only what was injected', () {
      TraceEvent result(int seq, Map<String, Object?> error) =>
          TraceEvent(seq: seq * 2 + 1, tUs: seq, type: TraceEventTypes.envResult, data: {'seq': seq, 'status': 'failed', 'error': error});
      TraceEvent envelope(int seq) =>
          TraceEvent(seq: seq * 2, tUs: seq, type: TraceEventTypes.agentEnvelope, data: {'seq': seq, 'key': 'state.noop', 'kind': 'act'});
      final trace = EpisodeTrace(
        meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'a', environmentId: 'mock', repetition: 0, startedAt: DateTime.utc(2026)),
        events: [
          envelope(0),
          result(0, {
            'code': 'transient_failure',
            'message': '',
            'details': {'injected': true},
          }),
          envelope(1),
          result(1, {'code': 'permission_denied', 'message': ''}),
        ],
      );

      final metrics = MetricsRegistry.builtin().computeAll(MetricContext(trace: trace));

      expect(metrics['injected_fault_count'], 1);
      expect(metrics['failed_envelope_count'], 2);
    });
  });
}

final class _Recorded extends Perturbation {
  @override
  JsonMap get record => {'recorded': true};
}

/// A mock environment that declares one key as waiting on a person.
final class _UserKeyEnvironment implements BenchmarkEnvironment {
  final _inner = MockEnvironment();

  @override
  Future<EnvironmentDescriptor> describe() async {
    final inner = await _inner.describe();
    return EnvironmentDescriptor(
      environmentId: inner.environmentId,
      envelopes: [
        ...inner.envelopes,
        const EnvelopeSpec(key: 'ask.person', blocksOnUser: true),
      ],
    );
  }

  @override
  Future<void> reset(FixtureRef fixture) => _inner.reset(fixture);

  @override
  Future<EnvelopeResult> handle(Envelope envelope) => _inner.handle(envelope);

  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) => _inner.captureFinalState(queries);
}
