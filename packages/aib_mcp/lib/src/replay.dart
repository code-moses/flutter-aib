import 'dart:io';

import 'package:aib_cli/aib_cli.dart';
import 'package:aib_core/aib_core.dart';

/// Replays a decision threshold from what a run recorded, without re-running.
///
/// Routing is exact: the route is the only thing its threshold changes, and
/// every routed episode recorded p(local). A completion check, a guard or a
/// selection is replayed **counterfactually**: where a decision would have
/// gone the other way, the episode would have continued differently, and
/// what it would then have scored is not in the trace. Those episodes are
/// counted as not followable instead of being guessed.
abstract final class ThresholdReplay {
  /// [routed] scored with the `routing` provider; the oracle from the two
  /// reference arms prices each route.
  static JsonMap route({required EvaluatedRun routed, required EvaluatedRun local, required EvaluatedRun cloud, required List<double> thresholds}) {
    final oracle = RouteOracle.from(local: local.records, cloud: cloud.records);
    final decisive = oracle.decisiveTasks.toSet();
    final episodes = [
      for (final record in routed.records)
        if (oracle.choice.containsKey(record.taskId))
          (record: record, p: record.metrics['route_probability_local']?.toDouble(), recorded: RouteSide.ofRecord(record)),
    ];
    JsonMap at(double? threshold) {
      var changed = 0;
      var hits = 0;
      var decisiveEpisodes = 0;
      var local = 0;
      final scores = <double>[];
      final routes = <String, String>{};
      for (final e in episodes) {
        final side = threshold == null || e.p == null ? e.recorded : (e.p! >= threshold ? RouteSide.local : RouteSide.cloud);
        if (side == null) continue;
        if (side != e.recorded) changed++;
        if (side == .local) local++;
        scores.add(oracle.scoreOf(e.record.taskId, side).score);
        if (decisive.contains(e.record.taskId)) {
          decisiveEpisodes++;
          if (side == oracle.choice[e.record.taskId]) hits++;
        }
        routes.putIfAbsent('${e.record.taskId}#${e.record.repetition}', () => side.name);
      }
      return {
        'threshold': ?threshold,
        'localShare': scores.isEmpty ? null : local / scores.length,
        'accuracy': decisiveEpisodes == 0 ? null : hits / decisiveEpisodes,
        'expectedScore': scores.isEmpty ? null : scores.reduce((a, b) => a + b) / scores.length,
        'changedEpisodes': changed,
        'routes': routes,
      };
    }

    return {
      'decision': 'route',
      'exact': true,
      'episodes': episodes.length,
      'notReplayable': episodes.where((e) => e.p == null).length,
      'recordedThreshold': recordedRouteThreshold(routed.manifest),
      'recorded': at(null),
      'replays': [for (final t in thresholds) at(t)],
      'note':
          'expectedScore prices each route with the reference arm that took it (the oracle runs), '
          'so it is comparable across thresholds but not to the routed run\'s own score.',
    };
  }

  /// `modelRouter.jev.threshold` of the routed agent, where the run recorded
  /// one.
  static double? recordedRouteThreshold(RunManifest manifest) {
    for (final agent in manifest.agents.values) {
      final router = asJsonMap(asJsonMap(asJsonMap(asJsonMap(agent['metadata'])['configBlocks'])['modelRouter'])['config']);
      if (asJsonMap(router['jev'])['threshold'] case final num t) return t.toDouble();
    }
    return null;
  }

  /// Completion checks (`completion`), guards (`guard`) or selections
  /// (`select-*`) of [run], replayed at [thresholds].
  ///
  /// Without [scored] (a judged suite whose run was never judged), the
  /// replay counts decisions and followable episodes but reports no score.
  static JsonMap decisions({required EvaluatedRun run, required String purpose, required List<double> thresholds, bool scored = true}) {
    final store = RunStore(Directory(run.runDir));
    final scores = {for (final r in run.records) r.episodeId: r.verdict.score};
    final tasks = {for (final t in run.suite.tasks) t.id: t};
    final episodes = <({String id, String task, List<JsonMap> records})>[];
    for (final trace in store.readTraces(onUnreadable: (_, _) {})) {
      if (!scores.containsKey(trace.meta.episodeId)) continue; // outside the scored tasks
      episodes.add((
        id: trace.meta.episodeId,
        task: trace.meta.taskId,
        records: [
          for (final event in trace.events)
            if (event.type == TraceEventTypes.agentEnvelope)
              for (final r in asJsonMap(asJsonMap(asJsonMap(event.data['decision'])['extra']))['decisions'] as List? ?? const [])
                if (_matches(asJsonMap(r)['purpose'] as String?, purpose)) asJsonMap(r),
        ],
      ));
    }
    final guard = asJsonMap(asJsonMap(_decisionsConfig(run.manifest))['guard']);
    final denyBelow = (guard['denyBelow'] as num?)?.toDouble() ?? 0;

    JsonMap at(double t) {
      var followable = 0;
      var decided = 0;
      final changedFirst = <String, int>{};
      final followedScores = <double>[];
      final recalls = <double>[];
      final kept = <int>[];
      for (final e in episodes) {
        var same = true;
        for (final (i, r) in e.records.indexed) {
          if (r['enforced'] == false || r['verdict'] == 'error') continue;
          final String? replayed;
          final String? recorded;
          if (purpose.startsWith('select')) {
            final candidates = asJsonMap(r['scores']).map((k, v) => MapEntry(k, (v as num).toDouble()));
            if (candidates.isEmpty) continue;
            final recordedThreshold = (r['threshold'] as num?)?.toDouble() ?? 0.5;
            final now = {
              for (final c in candidates.entries)
                if (c.value >= t) c.key,
            };
            final then = {
              for (final c in candidates.entries)
                if (c.value >= recordedThreshold) c.key,
            };
            kept.add(now.length);
            final required = tasks[e.task]?.requiredTools ?? const <String>[];
            if (r['purpose'] == 'select-tools' && required.isNotEmpty) {
              recalls.add(required.where(now.contains).length / required.length);
            }
            replayed = (now.toList()..sort()).join(',');
            recorded = (then.toList()..sort()).join(',');
          } else {
            final noul = (r['noul'] as num?)?.toDouble();
            if (noul == null) continue;
            replayed = purpose == 'completion' ? (noul >= t ? 'accept' : 'reject') : (noul >= t ? 'allow' : (noul < denyBelow ? 'deny' : 'confirm'));
            recorded = r['verdict'] as String?;
          }
          if (i == 0) decided++;
          if (replayed != recorded) {
            if (same) changedFirst.update('$recorded -> $replayed', (n) => n + 1, ifAbsent: () => 1);
            same = false;
          }
        }
        if (same) {
          followable++;
          followedScores.add(scores[e.id]!);
        }
      }
      double? mean(List<num> xs) => xs.isEmpty ? null : xs.reduce((a, b) => a + b) / xs.length;
      return {
        'threshold': t,
        'episodesWithDecision': decided,
        'followable': followable,
        'notFollowable': episodes.length - followable,
        'firstChange': changedFirst,
        'meanScoreFollowable': scored ? mean(followedScores) : null,
        if (kept.isNotEmpty) 'meanKept': mean(kept),
        if (recalls.isNotEmpty) 'recallRequiredTools': mean(recalls),
      };
    }

    final missingScores = purpose.startsWith('select') && episodes.every((e) => e.records.every((r) => r['scores'] == null));
    if (missingScores && episodes.any((e) => e.records.isNotEmpty)) {
      throw AibError(
        'this run recorded its $purpose decisions without per-candidate nouls '
        '(runs from before they were recorded); a selection threshold cannot be replayed from it',
      );
    }
    return {
      'decision': purpose,
      'exact': false,
      'label':
          'counterfactual, first decision only: an episode where a decision would have gone the other way '
          'continues differently, so it counts as not followable instead of being scored',
      'episodes': episodes.length,
      'scored': scored,
      'recordedMeanScore': !scored || episodes.isEmpty ? null : episodes.map((e) => scores[e.id]!).reduce((a, b) => a + b) / episodes.length,
      'replays': [for (final t in thresholds) at(t)],
    };
  }

  static bool _matches(String? recorded, String wanted) =>
      recorded != null && (recorded == wanted || (wanted == 'select-*' && recorded.startsWith('select')));

  static Object? _decisionsConfig(RunManifest manifest) {
    for (final agent in manifest.agents.values) {
      final block = asJsonMap(asJsonMap(asJsonMap(agent['metadata'])['configBlocks'])['decisions'])['config'];
      if (block != null) return block;
    }
    return null;
  }
}
