import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

EpisodeRecord _record(
  String taskId, {
  required double score,
  double? cost,
  bool? local,
  String decider = 'jev',
  int repetition = 1,
  VerdictType type = .partial,
  double? sideCost,
}) => EpisodeRecord(
  runId: 'r',
  episodeId: '$taskId-$repetition',
  taskId: taskId,
  agentId: 'prepared',
  repetition: repetition,
  verdict: Verdict(type: type, score: score),
  metrics: {'cost_usd': cost, if (local != null) 'route_local': local ? 1 : 0, 'side_call_cost_usd': ?sideCost},
  features: {if (local != null) 'route_decider': decider},
);

/// t1: local wins · t2: cloud wins · t3: a tie the oracle keeps local.
List<EpisodeRecord> get _local => [_record('t1', score: 1, cost: 0), _record('t2', score: 0, cost: 0), _record('t3', score: 1, cost: 0)];

List<EpisodeRecord> get _cloud => [_record('t1', score: 0.5, cost: 0.10), _record('t2', score: 1, cost: 0.10), _record('t3', score: 1, cost: 0.10)];

void main() {
  group('RouteOracle', () {
    final oracle = RouteOracle.from(local: _local, cloud: _cloud);

    test('takes the better side per task, ties local', () {
      expect(oracle.choice, {'t1': RouteSide.local, 't2': RouteSide.cloud, 't3': RouteSide.local});
      expect(oracle.score, 1.0);
      expect(oracle.localShare, closeTo(2 / 3, 1e-9));
      // Two of three tasks local at 0, one cloud at 0.10.
      expect(oracle.costUsd, closeTo(0.10 / 3, 1e-9));
    });

    test('decisive tasks are the ones the choice changes', () {
      expect(oracle.decisiveTasks, ['t1', 't2']);
    });

    test('the reference arms are the two trivial routers', () {
      expect(oracle.localArm.score, closeTo(2 / 3, 1e-9));
      expect(oracle.cloudArm.score, closeTo(2.5 / 3, 1e-9));
      expect(oracle.cloudArm.costUsd, closeTo(0.10, 1e-9));
    });

    test('only tasks both arms ran can be routed between', () {
      final partial = RouteOracle.from(local: [..._local, _record('t4', score: 1)], cloud: _cloud);
      expect(partial.tasks, ['t1', 't2', 't3']);
    });

    test('an episode that errored is not scored as a failure', () {
      final withError = RouteOracle.from(
        local: [
          ..._local,
          _record('t1', score: 0, repetition: 2, type: .error),
        ],
        cloud: _cloud,
      );
      expect(withError.local['t1']!.score, 1.0);
      expect(withError.local['t1']!.episodes, 1);
    });
  });

  group('RoutedArm', () {
    final oracle = RouteOracle.from(local: _local, cloud: _cloud);

    test('accuracy counts only the decisive tasks', () {
      // Right on t1, wrong on t2, and t3 (a tie) cannot be wrong.
      final arm = RoutedArm.from(
        label: 'jev',
        oracle: oracle,
        records: [
          _record('t1', score: 1, cost: 0, local: true),
          _record('t2', score: 0, cost: 0, local: true),
          _record('t3', score: 1, cost: 0.10, local: false),
        ],
      );
      expect(arm.accuracy, 0.5, reason: '1 of 2 decisive tasks');
      expect(arm.agreement, closeTo(1 / 3, 1e-9));
      expect(arm.decider, 'jev');
      expect(arm.localShare, closeTo(2 / 3, 1e-9));
    });

    test('scores the arm by what it did, not by the reference arms', () {
      final arm = RoutedArm.from(
        label: 'rules',
        oracle: oracle,
        records: [
          // Routed local everywhere, but scored 0.25 on t2 this time.
          _record('t1', score: 1, cost: 0, local: true, decider: 'rules'),
          _record('t2', score: 0.25, cost: 0, local: true, decider: 'rules'),
          _record('t3', score: 1, cost: 0, local: true, decider: 'rules'),
        ],
      );
      expect(arm.score, closeTo(2.25 / 3, 1e-9));
      expect(arm.regret, closeTo(1 - 2.25 / 3, 1e-9));
      expect(arm.costSaved, 1.0, reason: 'never went to the paid model');
      expect(arm.deciderCostUsd([_record('t1', score: 1, sideCost: 0.002)]), closeTo(0.002, 1e-9));
    });

    test('accuracy is null when no task was decisive', () {
      final flat = [_record('t1', score: 1), _record('t2', score: 1)];
      final arm = RoutedArm.from(
        label: 'x',
        oracle: RouteOracle.from(local: flat, cloud: flat),
        records: [_record('t1', score: 1, local: true), _record('t2', score: 1, local: false)],
      );
      expect(arm.accuracy, isNull);
    });

    test('an unrouted run contributes no routes', () {
      final arm = RoutedArm.from(label: 'plain', oracle: oracle, records: [_record('t1', score: 1)]);
      expect(arm.tasks, isEmpty);
      expect(arm.score, isNull);
      expect(arm.decider, '');
    });
  });

  test('routeStability reports disagreement across repetitions', () {
    expect(
      routeStability([
        _record('t1', score: 1, local: true),
        _record('t1', score: 1, local: false, repetition: 2),
        _record('t2', score: 1, local: true),
        _record('t2', score: 1, local: true, repetition: 2),
      ]),
      closeTo(0.75, 1e-9),
      reason: 't1 split 1/2, t2 agreed 2/2',
    );
    expect(routeStability([_record('t1', score: 1, local: true)]), isNull);
  });

  group('by language', () {
    // t1 and t2 are German, t3 English. The rules arm keeps everything
    // local: right on t1, wrong on t2, and t3 is a tie, so not decisive.
    final oracle = RouteOracle.from(local: _local, cloud: _cloud);
    final arm = RoutedArm.from(
      label: 'rules',
      oracle: oracle,
      records: [
        _record('t1', score: 1, local: true, decider: 'rules'),
        _record('t2', score: 0, local: true, decider: 'rules'),
        _record('t3', score: 1, local: true, decider: 'rules'),
      ],
    );

    test('accuracy is split over each language\'s decisive tasks', () {
      expect(arm.accuracyOver(['t1', 't2']), 0.5);
      expect(arm.accuracyOver(['t3']), isNull, reason: 'a tie decides nothing');
      expect(arm.scoreOver(['t1', 't2']), 0.5);
      expect(oracle.scoreOver(['t1', 't2']), 1.0);
      expect(oracle.sideScoreOver(RouteSide.cloud, ['t1', 't2']), 0.75);
      expect(oracle.localShareOver(['t1', 't2']), 0.5);
    });

    test('the report gets a table per language', () {
      final md = RouteReport(oracle: oracle, arms: [arm], languages: const {'t1': 'de', 't2': 'de', 't3': 'en'}).toMarkdown();
      expect(md, contains('## By language'));
      expect(md, contains('### de — 2 task(s), 2 decisive'));
      expect(md, contains('### en — 1 task(s), 0 decisive'));
      expect(md, contains('| rules (rules) | 0.500 | 100.0% | 50.0% |'));
      expect(md, contains('| rules (rules) | 1.000 | 100.0% | — |'));
    });

    test('without languages there is no split', () {
      expect(RouteReport(oracle: oracle, arms: [arm]).toMarkdown(), isNot(contains('By language')));
    });

    test('a lang: tag beats the detected language, which beats the fallback', () {
      EpisodeRecord tagged(String task, {List<String> tags = const [], String? detected}) => EpisodeRecord(
        runId: 'r',
        episodeId: task,
        taskId: task,
        agentId: 'a',
        repetition: 1,
        verdict: const Verdict(type: .success, score: 1),
        metrics: const {},
        tags: tags,
        features: {RouteReport.languageFeature: ?detected},
      );
      final languages = RouteReport.languagesOf(
        [
          tagged('t1', tags: ['lang:de'], detected: 'en'),
          tagged('t2', detected: 'en'),
        ],
        fallback: const {'t2': 'de', 't3': 'de'},
      );
      expect(languages, {'t1': 'de', 't2': 'en', 't3': 'de'});
    });
  });

  test('the report names the arms, the ceiling and the misses', () {
    final report = RouteReport(
      oracle: RouteOracle.from(local: _local, cloud: _cloud),
      arms: [
        RoutedArm.from(
          label: 'routed-jev',
          oracle: RouteOracle.from(local: _local, cloud: _cloud),
          records: [
            _record('t1', score: 1, cost: 0, local: true),
            _record('t2', score: 0, cost: 0, local: true),
            _record('t3', score: 1, cost: 0, local: true),
          ],
        ),
      ],
    );
    final md = report.toMarkdown();
    expect(md, contains('always-local'));
    expect(md, contains('| **oracle** |'));
    expect(md, contains('routed-jev (jev)'));
    expect(md, contains('**t2**'), reason: 'decisive tasks are marked');
    expect(md, contains('local ✗'), reason: 't2 was routed against the oracle');
  });
}
