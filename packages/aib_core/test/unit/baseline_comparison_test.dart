import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

EpisodeRecord _record(String task, int rep, {required bool success, Map<String, num?> metrics = const {}, JsonMap details = const {}}) =>
    EpisodeRecord(
      runId: 'r',
      episodeId: '$task-$rep',
      taskId: task,
      agentId: 'a',
      repetition: rep,
      verdict: success ? Verdict(type: .success, score: 1, details: details) : Verdict(type: .failure, score: 0, details: details),
      metrics: metrics,
    );

/// [successes] per task out of 3 repetitions.
List<EpisodeRecord> _run(Map<String, int> successes) => [
  for (final entry in successes.entries)
    for (var rep = 1; rep <= 3; rep++) _record(entry.key, rep, success: rep <= entry.value),
];

void main() {
  final tasks = [for (var i = 0; i < 12; i++) 't$i'];

  test('a run is summarised with both intervals and pass^k', () {
    final summary = BaselineComparison.summarise('a', _run({for (final t in tasks) t: 2}));
    expect(summary.episodes, 36);
    expect(summary.successRate, closeTo(2 / 3, 1e-9));
    expect(summary.clustered.low, lessThanOrEqualTo(summary.wilson.low));
    expect(summary.k, 3);
    expect(summary.passK, 0, reason: 'no task succeeds three times out of three');
  });

  test('the Bonferroni interval is wider than the 95 % one', () {
    final base = _run({for (final t in tasks) t: 1});
    final deltas = BaselineComparison.deltas(base, {
      'b': _run({for (final t in tasks) t: 3}),
      'c': _run({for (final t in tasks) t: 2}),
      'd': _run({for (final t in tasks) t: 1}),
    });
    final b = deltas.firstWhere((d) => d.label == 'b' && d.metric == 'success');
    expect(b.ci.meanDiff, closeTo(2 / 3, 1e-9));
    expect(b.significant, isTrue);
    final c = deltas.firstWhere((d) => d.label == 'c' && d.metric == 'success');
    expect(c.adjusted.high - c.adjusted.low, greaterThanOrEqualTo(c.ci.high - c.ci.low));
  });

  test('held-out tasks stay out of differences and per-task notes', () {
    final base = _run({'kept': 3, 'held': 0});
    final deltas = BaselineComparison.deltas(
      base,
      {
        'b': _run({'kept': 3, 'held': 3}),
      },
      heldOut: {'held'},
    );
    expect(deltas.every((d) => d.tasks == 1), isTrue);
    final suspects = BaselineComparison.suspects({'a': base}, heldOut: {'held'});
    expect(suspects.keys, isNot(contains('held')));
  });

  test('suspects name tasks no run solves and tasks every run scores alike', () {
    final suspects = BaselineComparison.suspects({
      'a': [
        _record('never', 1, success: false, metrics: {'budget_exhaustion': 1}),
        _record('fine', 1, success: true),
      ],
      'b': [_record('never', 1, success: false), _record('fine', 1, success: true)],
    });
    expect(suspects['never'], [contains('never a success'), contains('1 budget or timeout')]);
    expect(suspects.containsKey('fine'), isFalse);
  });

  test('a criterion can be set aside from the score', () {
    final record = EpisodeRecord(
      runId: 'r',
      episodeId: 'e',
      taskId: 't',
      agentId: 'a',
      repetition: 1,
      verdict: const Verdict(
        type: .partial,
        score: 0.5,
        details: {
          'finalStateMatch': {'score': 1.0, 'weight': 1.0},
          'artifactRubric:faithfulness_v2': {'score': 0.0, 'weight': 1.0},
        },
      ),
      metrics: const {},
    );
    expect(BaselineComparison.summarise('a', [record], setAside: 'faithfulness').scoreWithout, 1.0);
  });

  test('the Markdown names the baseline and the number of comparisons', () {
    final runs = {
      'base': _run({'t': 1}),
      'b': _run({'t': 3}),
    };
    final markdown = BaselineComparison.toMarkdown(
      [for (final e in runs.entries) BaselineComparison.summarise(e.key, e.value)],
      BaselineComparison.deltas(runs['base']!, {'b': runs['b']!}),
      const {},
    );
    expect(markdown, contains('Against `base`'));
    expect(markdown, contains('1 comparison(s)'));
  });
}
