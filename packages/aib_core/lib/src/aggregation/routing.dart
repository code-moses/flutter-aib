import 'dart:math' as math;

import 'aggregator.dart';

/// Which model an episode ran on.
enum RouteSide {
  local,
  cloud;

  static RouteSide? ofRecord(EpisodeRecord record) => switch (record.metrics[localMetric]) {
    null => null,
    final num flag => flag >= 0.5 ? RouteSide.local : RouteSide.cloud,
  };

  /// The 0/1 metric `routingMetrics` derives from `extra.modelRoute`.
  static const localMetric = 'route_local';
}

/// One arm's result on one task: the mean over its repetitions, with [episodes]
/// so a reader can see how many samples that is.
final class TaskScore {
  const TaskScore({required this.taskId, required this.score, required this.costUsd, required this.episodes});

  final String taskId;
  final double score;

  /// Null where no model in the episode was priced.
  final double? costUsd;
  final int episodes;

  static List<TaskScore> fold(List<EpisodeRecord> records) {
    final byTask = <String, List<EpisodeRecord>>{};
    for (final record in records) {
      // An episode that ended in a framework fault scored nothing; counting
      // it as 0 would blame the model for the harness.
      if (record.verdict.type == .error) continue;
      byTask.putIfAbsent(record.taskId, () => []).add(record);
    }
    return [
      for (final entry in byTask.entries)
        TaskScore(
          taskId: entry.key,
          score: _mean([for (final r in entry.value) r.verdict.score])!,
          costUsd: _mean([for (final r in entry.value) ?(r.metrics['cost_usd'])?.toDouble()]),
          episodes: entry.value.length,
        ),
    ]..sort((a, b) => a.taskId.compareTo(b.taskId));
  }
}

/// The per-task best of the two reference arms: the ceiling every decider is
/// scored against. It knows each task's outcome before choosing, so no router
/// can reach it.
final class RouteOracle {
  const RouteOracle({required this.local, required this.cloud, required this.choice, required this.tasks});

  final Map<String, TaskScore> local;
  final Map<String, TaskScore> cloud;

  /// Per task, the side that scored higher. Ties go local: same score for
  /// less money is the whole point of routing.
  final Map<String, RouteSide> choice;

  /// Tasks both arms ran, in order. Anything else cannot be routed between.
  final List<String> tasks;

  factory RouteOracle.from({required List<EpisodeRecord> local, required List<EpisodeRecord> cloud}) {
    final localByTask = {for (final score in TaskScore.fold(local)) score.taskId: score};
    final cloudByTask = {for (final score in TaskScore.fold(cloud)) score.taskId: score};
    final tasks = localByTask.keys.where(cloudByTask.containsKey).toList()..sort();
    return RouteOracle(
      local: localByTask,
      cloud: cloudByTask,
      tasks: tasks,
      choice: {for (final task in tasks) task: localByTask[task]!.score >= cloudByTask[task]!.score ? RouteSide.local : RouteSide.cloud},
    );
  }

  TaskScore scoreOf(String task, RouteSide side) => (side == .local ? local : cloud)[task]!;

  /// Tasks where the two arms disagree, so the routing decision has
  /// consequences. Routing accuracy is only meaningful over these: on a task
  /// both models solve, every decider is "right" and the number says nothing.
  List<String> get decisiveTasks => [
    for (final task in tasks)
      if (local[task]!.score != cloud[task]!.score) task,
  ];

  double get score => _mean([for (final task in tasks) scoreOf(task, choice[task]!).score])!;

  /// [score] over a subset of [tasks] (one language's, say); null when the
  /// subset holds none of them.
  double? scoreOver(Iterable<String> subset) => _mean([
    for (final task in subset)
      if (choice[task] case final side?) scoreOf(task, side).score,
  ]);

  /// A reference arm's score over a subset of [tasks].
  double? sideScoreOver(RouteSide side, Iterable<String> subset) => _mean([
    for (final task in subset)
      if (choice.containsKey(task)) scoreOf(task, side).score,
  ]);

  double? localShareOver(Iterable<String> subset) {
    final routed = [for (final task in subset) ?choice[task]];
    return routed.isEmpty ? null : routed.where((s) => s == .local).length / routed.length;
  }

  double? get costUsd => _mean([for (final task in tasks) ?scoreOf(task, choice[task]!).costUsd]);

  double get localShare => tasks.isEmpty ? 0 : choice.values.where((s) => s == .local).length / tasks.length;

  /// The arms themselves, as the two trivial routers.
  ArmSummary get localArm => _arm('always-local', RouteSide.local);
  ArmSummary get cloudArm => _arm('always-cloud', RouteSide.cloud);

  ArmSummary _arm(String label, RouteSide side) => ArmSummary(
    label: label,
    score: _mean([for (final task in tasks) scoreOf(task, side).score])!,
    costUsd: _mean([for (final task in tasks) ?scoreOf(task, side).costUsd]),
    localShare: side == .local ? 1 : 0,
    tasks: tasks.length,
  );
}

/// A reference arm reduced to the three numbers a router is judged on.
final class ArmSummary {
  const ArmSummary({required this.label, required this.score, required this.costUsd, required this.localShare, required this.tasks});

  final String label;
  final double score;
  final double? costUsd;
  final double localShare;
  final int tasks;
}

/// What one decider actually achieved against [RouteOracle].
final class RoutedArm {
  const RoutedArm({required this.label, required this.decider, required this.routes, required this.oracle, required this.observed});

  final String label;

  /// Decider name as the run recorded it, empty when the run is not routed.
  final String decider;

  /// The side each task was routed to.
  final Map<String, RouteSide> routes;

  final RouteOracle oracle;

  /// The arm's own scores. These differ from the reference arms' because a
  /// routed episode is a different sample of the same condition.
  final Map<String, TaskScore> observed;

  factory RoutedArm.from({required String label, required List<EpisodeRecord> records, required RouteOracle oracle}) {
    final routes = <String, RouteSide>{};
    for (final record in records) {
      if (RouteSide.ofRecord(record) case final side?) {
        // The first repetition decides the label; a decider that answers
        // differently across repetitions is reported by [routeStability].
        routes.putIfAbsent(record.taskId, () => side);
      }
    }
    return RoutedArm(
      label: label,
      decider: _deciderOf(records),
      routes: routes,
      oracle: oracle,
      observed: {for (final score in TaskScore.fold(records)) score.taskId: score},
    );
  }

  static String _deciderOf(List<EpisodeRecord> records) {
    for (final record in records) {
      if (record.features['route_decider'] case final String decider) {
        return decider;
      }
    }
    return '';
  }

  /// Tasks routed *and* present in both reference arms.
  List<String> get tasks => [
    for (final task in oracle.tasks)
      if (routes.containsKey(task)) task,
  ];

  double? get score => _mean([for (final task in tasks) ?observed[task]?.score]);

  double? get costUsd => _mean([for (final task in tasks) ?observed[task]?.costUsd]);

  double get localShare => tasks.isEmpty ? 0 : tasks.where((t) => routes[t] == .local).length / tasks.length;

  /// Agreement with the oracle over the tasks where the choice mattered.
  /// Null when no task is decisive — the honest answer, not 1.0.
  double? get accuracy => accuracyOver(oracle.tasks);

  /// [accuracy] over a subset of the tasks (one language's).
  double? accuracyOver(Iterable<String> subset) {
    final wanted = subset.toSet();
    final decisive = [
      for (final task in oracle.decisiveTasks)
        if (routes.containsKey(task) && wanted.contains(task)) task,
    ];
    if (decisive.isEmpty) return null;
    final hits = decisive.where((t) => routes[t] == oracle.choice[t]).length;
    return hits / decisive.length;
  }

  /// This arm's own score over a subset of its tasks.
  double? scoreOver(Iterable<String> subset) {
    final mine = tasks.toSet();
    return _mean([
      for (final task in subset)
        if (mine.contains(task)) ?observed[task]?.score,
    ]);
  }

  double? localShareOver(Iterable<String> subset) {
    final mine = tasks.toSet();
    final routed = [
      for (final task in subset)
        if (mine.contains(task)) routes[task]!,
    ];
    return routed.isEmpty ? null : routed.where((s) => s == .local).length / routed.length;
  }

  /// Agreement over every routed task, decisive or not — what a confusion
  /// matrix of this arm would show.
  double? get agreement {
    if (tasks.isEmpty) return null;
    return tasks.where((t) => routes[t] == oracle.choice[t]).length / tasks.length;
  }

  /// What the oracle would have scored on the same tasks, minus what this
  /// arm scored: the ceiling still unclaimed.
  double? get regret {
    final mine = score;
    if (mine == null || tasks.isEmpty) return null;
    final ceiling = _mean([for (final task in tasks) oracle.scoreOf(task, oracle.choice[task]!).score])!;
    return ceiling - mine;
  }

  /// Cloud spend avoided against always-cloud, as a share of it. Null when
  /// either side is unpriced.
  double? get costSaved {
    final mine = costUsd;
    final cloud = _mean([for (final task in tasks) ?oracle.cloud[task]?.costUsd]);
    if (mine == null || cloud == null || cloud == 0) return null;
    return (cloud - mine) / cloud;
  }

  /// Mean decider spend per episode, where the run priced it.
  double? deciderCostUsd(List<EpisodeRecord> records) => _mean([for (final record in records) ?(record.metrics['side_call_cost_usd'])?.toDouble()]);
}

/// The whole comparison: two reference arms, their oracle, and every decider
/// measured against it.
final class RouteReport {
  const RouteReport({required this.oracle, required this.arms, this.languages = const {}});

  final RouteOracle oracle;
  final List<RoutedArm> arms;

  /// Task id → language (ISO 639-1). The report splits every number by it.
  /// Empty means no split.
  final Map<String, String> languages;

  /// Task languages from what the runs recorded: a `lang:xx` tag first (set
  /// by whoever wrote the task), then the `route_language` feature (the
  /// router's detection of the instruction). Tasks with neither are left
  /// out; [fallback] can name them.
  static Map<String, String> languagesOf(Iterable<EpisodeRecord> records, {Map<String, String> fallback = const {}}) {
    final tagged = <String, String>{};
    final detected = <String, String>{};
    for (final record in records) {
      for (final tag in record.tags) {
        if (tag.startsWith('lang:')) tagged.putIfAbsent(record.taskId, () => tag.substring(5));
      }
      if (record.features[languageFeature] case final String language) {
        detected.putIfAbsent(record.taskId, () => language);
      }
    }
    return {...fallback, ...detected, ...tagged};
  }

  /// The feature `routingMetrics` records the instruction's language under.
  static const languageFeature = 'route_language';

  /// Markdown, in the shape the thesis reports a sweep: the reference arms
  /// first, then the oracle ceiling, then each decider.
  String toMarkdown() {
    String pct(double? v) => v == null ? '—' : '${(v * 100).toStringAsFixed(1)}%';
    String num3(double? v) => v == null ? '—' : v.toStringAsFixed(3);
    String usd(double? v) => v == null ? '—' : '\$${v.toStringAsFixed(5)}';

    final lines = <String>[
      '# Model routing',
      '',
      '${oracle.tasks.length} task(s) in both reference arms, '
          '${oracle.decisiveTasks.length} of them decisive '
          '(the two models score differently).',
      '',
      '| arm | score | cost | local share | routing accuracy | regret |',
      '|---|---:|---:|---:|---:|---:|',
    ];
    for (final arm in [oracle.localArm, oracle.cloudArm]) {
      lines.add(
        '| ${arm.label} | ${num3(arm.score)} | ${usd(arm.costUsd)} | '
        '${pct(arm.localShare)} | — | '
        '${num3(oracle.score - arm.score)} |',
      );
    }
    lines.add(
      '| **oracle** | **${num3(oracle.score)}** | ${usd(oracle.costUsd)} | '
      '${pct(oracle.localShare)} | 100% | 0.000 |',
    );
    for (final arm in arms) {
      lines.add(
        '| ${arm.label}${arm.decider.isEmpty ? '' : ' (${arm.decider})'} | '
        '${num3(arm.score)} | ${usd(arm.costUsd)} | ${pct(arm.localShare)} | '
        '${pct(arm.accuracy)} | ${num3(arm.regret)} |',
      );
    }
    if (arms.isNotEmpty) {
      lines
        ..add('')
        ..add('## Per task')
        ..add('')
        ..add('| task | local | cloud | oracle | ${arms.map((a) => a.label).join(' | ')} |')
        ..add('|---|---:|---:|:--|${arms.map((_) => ':--|').join()}');
      for (final task in oracle.tasks) {
        final decisive = oracle.local[task]!.score != oracle.cloud[task]!.score;
        lines.add(
          '| ${decisive ? '**$task**' : task} '
          '| ${num3(oracle.local[task]!.score)} '
          '| ${num3(oracle.cloud[task]!.score)} '
          '| ${oracle.choice[task]!.name} '
          '| ${arms.map((a) => switch (a.routes[task]) {
            null => '—',
            final side => '${side.name}${side == oracle.choice[task] ? '' : ' ✗'}',
          }).join(' | ')} |',
        );
      }
    }
    lines.addAll(_byLanguage(pct, num3));
    return '${lines.join('\n')}\n';
  }

  /// One table per language: the same columns, over that language's tasks.
  List<String> _byLanguage(String Function(double?) pct, String Function(double?) num3) {
    final codes = {for (final task in oracle.tasks) ?languages[task]}.toList()..sort();
    if (codes.isEmpty) return const [];
    final unlabelled = oracle.tasks.where((t) => !languages.containsKey(t)).length;
    final lines = <String>[
      '',
      '## By language',
      '',
      'Accuracy is over the decisive tasks of each language; with few of them '
          'a single task moves it by a lot.'
          '${unlabelled == 0 ? '' : ' $unlabelled task(s) have no language and appear in no table.'}',
    ];
    for (final code in codes) {
      final tasks = [
        for (final task in oracle.tasks)
          if (languages[task] == code) task,
      ];
      final decisive = oracle.decisiveTasks.where(tasks.contains).length;
      lines
        ..add('')
        ..add('### $code — ${tasks.length} task(s), $decisive decisive')
        ..add('')
        ..add('| arm | score | local share | routing accuracy |')
        ..add('|---|---:|---:|---:|')
        ..add('| always-local | ${num3(oracle.sideScoreOver(RouteSide.local, tasks))} | 100.0% | — |')
        ..add('| always-cloud | ${num3(oracle.sideScoreOver(RouteSide.cloud, tasks))} | 0.0% | — |')
        ..add('| **oracle** | **${num3(oracle.scoreOver(tasks))}** | ${pct(oracle.localShareOver(tasks))} | 100% |');
      for (final arm in arms) {
        lines.add(
          '| ${arm.label}${arm.decider.isEmpty ? '' : ' (${arm.decider})'} | '
          '${num3(arm.scoreOver(tasks))} | ${pct(arm.localShareOver(tasks))} | ${pct(arm.accuracyOver(tasks))} |',
        );
      }
    }
    return lines;
  }
}

double? _mean(List<double> values) => values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length;

/// How often a decider gave the same answer across repetitions of a task —
/// 1.0 when every repetition of every task agreed. Null at n=1, where the
/// question does not arise.
double? routeStability(List<EpisodeRecord> records) {
  final byTask = <String, List<RouteSide>>{};
  for (final record in records) {
    if (RouteSide.ofRecord(record) case final side?) {
      byTask.putIfAbsent(record.taskId, () => []).add(side);
    }
  }
  final repeated = byTask.values.where((sides) => sides.length > 1).toList();
  if (repeated.isEmpty) return null;
  return _mean([
    for (final sides in repeated) math.max(sides.where((s) => s == .local).length, sides.where((s) => s == .cloud).length) / sides.length,
  ]);
}
