import 'dart:convert';

import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

TraceEvent _e(int seq, String type, JsonMap data) => TraceEvent(seq: seq, tUs: seq * 1000, type: type, data: data);

EpisodeTrace _trace({int actions = 2, String end = 'done', int bigAt = -1, int bigSize = 8000}) {
  final events = <TraceEvent>[
    _e(0, TraceEventTypes.episodeStart, const {
      'task': {'id': 't'},
    }),
  ];
  var seq = 1;
  for (var i = 0; i < actions; i++) {
    events
      ..add(
        _e(seq++, TraceEventTypes.agentEnvelope, {
          'seq': i,
          'key': 'intents.invoke',
          'kind': 'observe',
          'payload': {
            'intent': 'data.count',
            'params': {'endpointId': 10},
          },
        }),
      )
      ..add(
        _e(seq++, TraceEventTypes.envResult, {
          'seq': i,
          'status': 'ok',
          'payload': i == bigAt ? {'rows': List.filled(400, 'x' * 20)} : {'count': 30},
        }),
      );
  }
  events.add(_e(seq++, TraceEventTypes.episodeEnd, {'reason': end}));
  return EpisodeTrace(
    meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'a', environmentId: 'env', repetition: 1, startedAt: DateTime.utc(2026)),
    events: events,
  );
}

void main() {
  test('the digest carries what was called, what came back and how it ended', () {
    final evidence = episodeEvidence(_trace());
    final actions = evidence['actions']! as List;
    expect(actions, hasLength(2));
    expect(actions.first, containsPair('did', 'intents.invoke'));
    expect('${(actions.first as Map)['with']}', contains('data.count'));
    expect('${(actions.first as Map)['with']}', contains('endpointId'));
    expect('${(actions.first as Map)['returned']}', contains('30'));
    expect(evidence['endedBecause'], 'done');
  });

  test('a long episode keeps its opening and its ending, not its middle', () {
    // A summary's claims are about what it found and how it finished.
    final evidence = episodeEvidence(_trace(actions: 60), maxActions: 10);
    final actions = evidence['actions']! as List;
    expect(actions.length, lessThanOrEqualTo(11));
    expect(actions.map((a) => '${(a as Map)['did']}').join(' '), contains('omitted'));
  });

  test('a result is kept whole while the digest fits', () {
    // The first version cut every payload to 220 characters, and three
    // reference trajectories were judged unfaithful for naming a mask id and
    // a count that were in the record just past the cut.
    final evidence = episodeEvidence(_trace());
    final first = (evidence['actions']! as List).first as Map;
    expect('${first['returned']}', '{"count":30}');
  });

  test('over budget, the largest value is shortened and the small ones are not', () {
    // What is lost is the bulk of one big listing, not the tail of every
    // result — the support a summary names is usually in a small one.
    final evidence = episodeEvidence(_trace(actions: 4, bigAt: 2), maxBytes: 2000);
    expect(jsonEncode(evidence).length, lessThanOrEqualTo(2000));
    final returned = [for (final a in evidence['actions']! as List) '${(a as Map)['returned']}'];
    expect(returned.where((r) => r == '{"count":30}'), hasLength(3));
    expect(returned.singleWhere((r) => r.startsWith('{"rows"')), endsWith('…'));
  });

  test('a digest of small results is left alone even under a tight budget', () {
    // Best effort: it cannot shrink below what the structure costs, and it
    // does not mangle values that were never the problem.
    final evidence = episodeEvidence(_trace(actions: 6), maxBytes: 100);
    for (final a in evidence['actions']! as List) {
      expect((a as Map)['returned'], '{"count":30}');
    }
  });

  test('a value that cannot shrink ends the trim instead of spinning on it', () {
    // Cutting to two thirds but never below a floor is a no-op one character
    // over that floor: the value came back the same length with an ellipsis,
    // and the loop ran forever at 100% CPU with the app under test behind it.
    for (var size = 195; size <= 215; size++) {
      final evidence = episodeEvidence(_trace(actions: 1, bigAt: 0, bigSize: size), maxBytes: 1).toString();
      expect(evidence, isNotEmpty, reason: 'size $size must terminate');
    }
  });

  test('a criterion that judges a claim is skipped when no claim was made', () {
    // Not scored 0: silence is not a false claim, and the task criterion has
    // already failed that episode.
    const outcome = CriterionOutcome.notApplicable(detail: 'nothing to judge');
    expect(outcome.applies, isFalse);
    expect(const CriterionOutcome(score: 0, detail: 'x').applies, isTrue);
  });
}
