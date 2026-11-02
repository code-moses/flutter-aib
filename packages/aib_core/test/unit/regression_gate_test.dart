import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

EpisodeRecord _ep(String task, int rep, VerdictType type, {String agent = 'a', double? score, int wallClockMs = 1500, String? reason}) =>
    EpisodeRecord(
      runId: 'r',
      episodeId: '${task}__${agent}__rep$rep',
      taskId: task,
      agentId: agent,
      repetition: rep,
      verdict: Verdict(type: type, score: score ?? (type == .success ? 1 : 0), reason: reason),
      metrics: {'wall_clock_ms': wallClockMs},
    );

List<EpisodeRecord> _reps(String task, List<VerdictType> types, {String agent = 'a'}) => [
  for (final (i, type) in types.indexed) _ep(task, i + 1, type, agent: agent),
];

const _s = VerdictType.success;
const _f = VerdictType.failure;

void main() {
  group('RegressionGate', () {
    test('newly failing, score drop and turned flaky; an improvement is none of them', () {
      final baseline = [
        ..._reps('open', [_s, _f, _s]),
        ..._reps('count', [_s, _s, _s]),
        ..._reps('form', [_s, _s, _s]),
        ..._reps('better', [_f, _f, _f]),
        ..._reps('steady', [_s, _s, _s]),
      ];
      final candidate = [
        ..._reps('open', [_f, _f, _f]),
        ..._reps('count', [_s, _f, _f]),
        ..._reps('form', [_s, _s, _f]),
        ..._reps('better', [_s, _s, _s]),
        ..._reps('steady', [_s, _s, _s]),
        ..._reps('new', [_f]),
      ];
      final result = const RegressionGate(tolerance: 0.4).check(baseline, candidate);
      expect(
        {for (final r in result.regressions) r.task: r.kind},
        {'open': RegressionKind.newlyFailing, 'count': RegressionKind.scoreDrop, 'form': RegressionKind.turnedFlaky},
      );
      expect(result.unmatched, ['new']);
      expect(result.passed, isFalse);
      expect(result.regressions.first.toString(), 'open newly failing: 2/3 -> 0/3');
    });

    test('two single-agent runs are matched by task whatever the agents are called', () {
      final result = const RegressionGate().check(_reps('open', [_s], agent: 'hybrid'), _reps('open', [_s], agent: 'prepared'));
      expect(result.passed, isTrue);
      expect(result.unmatched, isEmpty);
    });

    test('runs with several agents are matched by agent too', () {
      final result = const RegressionGate().check(
        [
          ..._reps('open', [_s], agent: 'x'),
          ..._reps('open', [_s], agent: 'y'),
        ],
        [
          ..._reps('open', [_s], agent: 'x'),
          ..._reps('open', [_f], agent: 'y'),
        ],
      );
      expect(result.regressions.single.label, 'y/open');
    });
  });

  test('the junit reporter writes one testcase per episode, a failure with its reason', () {
    final xml = JunitReporter().render(
      RunReportData(
        records: [
          _ep('open', 1, _s, wallClockMs: 2500),
          _ep('open & close', 2, _f, reason: 'list "Artikel" never opened'),
          _ep('count', 1, VerdictType.partial, score: 0.5),
          _ep('count', 2, VerdictType.error, reason: 'judge down'),
        ],
        aggregates: const [],
      ),
    );
    expect(xml, startsWith('<?xml'));
    expect(xml, contains('<testsuites name="r" tests="4" failures="2" errors="1">'));
    expect(xml, contains('<testcase classname="a.open" name="rep1" time="2.500"/>'));
    expect(xml, contains('classname="a.open &amp; close"'));
    expect(xml, contains('<failure type="failure" message="failure: list &quot;Artikel&quot; never opened">'));
    expect(xml, contains('message="partial: score 0.50"'));
    expect(xml, contains('<error type="error" message="error: judge down">'));
    expect(ReporterRegistry()['junit'], isA<JunitReporter>());
  });
}
