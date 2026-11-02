import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:test/test.dart';

const _list = Envelope(key: 'state.list', kind: .observe, payload: {'path': 'db.todos'});

Envelope _prefetched(Envelope e) => Envelope(
  key: e.key,
  kind: e.kind,
  payload: e.payload,
  decision: const AgentDecision(extra: {AgentDecision.prefetchKey: true}),
);

TaskSpec _task() => const TaskSpec(
  id: 't',
  title: 't',
  instruction: 'look',
  budget: Budget(maxSteps: 5, maxWallClockSeconds: 30, maxIdenticalRepeats: 1),
  fixture: FixtureRef(
    id: 'seed',
    data: {
      'db': {
        'todos': [
          {'title': 'a'},
        ],
      },
    },
  ),
);

Future<EpisodeTrace> _run(List<Envelope> script) async => (await BenchmarkEngine().runEpisode(
  task: _task(),
  agent: ScriptedAgent(defaultScript: script),
  environment: MockEnvironment(),
  meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'scripted', environmentId: 'mock', repetition: 1, startedAt: DateTime(2026)),
)).trace;

void main() {
  test('extra round-trips and is absent from traces that predate it', () {
    const decision = AgentDecision(extra: {'tools': 7, 'prefetch': true});
    final back = AgentDecision.fromJson(decision.toJson());
    expect(back.extra, {'tools': 7, 'prefetch': true});
    expect(back.isPrefetch, isTrue);
    expect(AgentDecision.fromJson(const {'tokensPrompt': 1}).extra, isNull);
    expect(const AgentDecision().toJson(), isNot(contains('extra')));
  });

  test('asking again for what was prefetched is not a repeat', () async {
    final trace = await _run([_prefetched(_list), _list]);
    expect(trace.endReason, 'done');
    expect(trace.exchanges().where((x) => x.result?.data['suppressed'] == true), isEmpty);
  });

  test('the same request twice without a prefetch still is', () async {
    final trace = await _run([_list, _list, _list]);
    expect(trace.exchanges().where((x) => x.result?.data['suppressed'] == true), isNotEmpty);
  });
}
