import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

TraceEvent _e(int seq, String type, JsonMap data) => TraceEvent(seq: seq, tUs: seq * 1000, type: type, data: data);

/// One observation per entry of [results].
EpisodeTrace _trace(List<JsonMap> results) {
  final events = <TraceEvent>[];
  var seq = 0;
  for (var i = 0; i < results.length; i++) {
    events
      ..add(
        _e(seq++, TraceEventTypes.agentEnvelope, {
          'seq': i,
          'key': 'intents.invoke',
          'kind': 'observe',
          'payload': const {'intent': 'data.search'},
        }),
      )
      ..add(_e(seq++, TraceEventTypes.envResult, {'seq': i, 'status': 'ok', 'payload': results[i]}));
  }
  events.add(_e(seq++, TraceEventTypes.episodeEnd, const {'reason': 'done'}));
  return EpisodeTrace(
    meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'a', environmentId: 'env', repetition: 1, startedAt: DateTime.utc(2026)),
    events: events,
  );
}

TaskSpec _task(List<String> facts) => TaskSpec(
  id: 't',
  title: 't',
  instruction: 'x',
  budget: const Budget(maxSteps: 10, maxWallClockSeconds: 10),
  fixture: const FixtureRef(id: 'f'),
  requiredFacts: facts,
);

Map<String, num?> _metrics(EpisodeTrace trace, TaskSpec task) => MetricsRegistry.builtin().computeAll(MetricContext(trace: trace, task: task));

void main() {
  test('a fact that arrived is counted, with the turn it arrived on', () {
    final m = _metrics(
      _trace([
        const {'hits': []},
        const {
          'entry': {'Oid': '5E2F87CD-EACE'},
        },
      ]),
      _task(['5E2F87CD-EACE']),
    );
    expect(m['facts_seen_share'], 1.0);
    // Turns count exchanges, and the id arrived on the second.
    expect(m['turns_to_all_facts'], 2);
  });

  test('a fact that never arrived is the difference that matters', () {
    // The agent could not have used it: this is the app hiding something,
    // not the agent ignoring it.
    final m = _metrics(
      _trace([
        const {'hits': []},
      ]),
      _task(['5E2F87CD-EACE', 'Stunde']),
    );
    expect(m['facts_seen_share'], 0.0);
    expect(m['turns_to_all_facts'], isNull);
  });

  test('some seen, some not', () {
    final m = _metrics(
      _trace([
        const {
          'entry': {'Rechnungseinheit': 'Stunde'},
        },
      ]),
      _task(['Stunde', 'never-appears']),
    );
    expect(m['facts_seen_share'], 0.5);
    expect(m['turns_to_all_facts'], isNull, reason: 'one is still missing');
  });

  test('a task that declares no facts is not scored on them', () {
    final m = _metrics(
      _trace([
        const {'a': 1},
      ]),
      _task(const []),
    );
    expect(m['facts_seen_share'], isNull);
    expect(m['turns_to_all_facts'], isNull);
  });

  test('requiredFacts survives the wire, so a remote run can be scored', () {
    final task = _task(['Stunde']);
    expect(TaskSpec.fromJson(task.toJson()).requiredFacts, ['Stunde']);
    expect(_task(const []).toJson().containsKey('requiredFacts'), isFalse);
  });
}
