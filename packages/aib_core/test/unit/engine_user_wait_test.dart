import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:test/test.dart';

EpisodeTrace _trace(List<TraceEvent> events) => EpisodeTrace(
  meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'hybrid', environmentId: 'env', repetition: 1, startedAt: DateTime(2026, 9, 3)),
  events: events,
);

void main() {
  group('engine: waiting for a human', () {
    test('user wait is excluded from the wall clock and reported apart', () async {
      final environment = _SlowUserEnvironment();
      final agent = ScriptedAgent(
        defaultScript: const [
          Envelope(key: 'user.ask', kind: .act, payload: {'type': 'confirm', 'prompt': 'ok?'}),
        ],
      );
      final result = await BenchmarkEngine().runEpisode(
        task: const TaskSpec(
          id: 't',
          title: 't',
          instruction: 'i',
          fixture: FixtureRef(id: 'f', data: {}),
          // One second of budget; the "user" takes longer than that.
          budget: Budget(maxSteps: 5, maxWallClockSeconds: 1),
        ),
        agent: agent,
        environment: environment,
        meta: _trace(const []).meta,
      );

      // Without the exclusion this episode would time out, and an agent that
      // correctly asked would score worse than one that guessed.
      expect(result.outcome.reason, TerminationReason.done);
      final waited = result.trace.events
          .where((e) => e.type == TraceEventTypes.envResult)
          .map((e) => e.data['userWaitMs'])
          .whereType<num>()
          .fold<int>(0, (a, b) => a + b.toInt());
      expect(waited, greaterThanOrEqualTo(1200));
    });
  });
}

final class _SlowUserEnvironment implements BenchmarkEnvironment {
  @override
  Future<EnvironmentDescriptor> describe() async => const EnvironmentDescriptor(
    environmentId: 'slow',
    envelopes: [EnvelopeSpec(key: 'user.ask', kind: .act, blocksOnUser: true)],
  );

  @override
  Future<EnvelopeResult> handle(Envelope envelope) async {
    if (envelope.key != 'user.ask') {
      return EnvelopeResult.unsupported(envelope.key);
    }
    const wait = Duration(milliseconds: 1300);
    await Future<void>.delayed(wait);
    return EnvelopeResult(status: .ok, payload: const {'answer': true}, userWaitMs: wait.inMilliseconds);
  }

  @override
  Future<void> reset(FixtureRef fixture) async {}

  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) async => const FinalStateSnapshot(results: []);
}
