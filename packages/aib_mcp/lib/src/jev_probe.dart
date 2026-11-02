import 'dart:convert';
import 'dart:io';

import 'package:aib_agents/aib_agents.dart';
import 'package:path/path.dart' as p;

import 'workspace.dart';

/// Compares tool-selection prompts and decision backends on labelled tasks,
/// without running an agent (`bin/jev_probe.dart`).
///
/// The fixture is built from runs ([extract]): the catalogue the app published,
/// and as labels the intents the successful episodes of each task invoked. It
/// holds the app's catalogue text, so it belongs under `results/`. Task texts
/// come from the tuning split only.
abstract final class JevProbe {
  /// A fixture from [runs] of [suite]: the tuning tasks with their
  /// instructions, the catalogue of the first run that recorded one, and per
  /// task the intents invoked by at least [minShare] of its successful
  /// episodes (`needed`) or by at least [usefulShare] (`useful`).
  ///
  /// A task no run solved has no labels and is marked `unlabelled`; edit the
  /// fixture by hand to label it.
  static JsonMap extract({
    required AibWorkspace workspace,
    required String suite,
    required List<String> runs,
    double minShare = 0.5,
    double usefulShare = 0.2,
  }) {
    final described = workspace.describeSuite(suite);
    final tasks = [for (final task in described['tasks'] as List) asJsonMap(task)];
    final tune = {for (final task in tasks) task['id'] as String};

    List<JsonMap>? catalogue;
    final successes = <String, int>{};
    final used = <String, Map<String, int>>{};
    for (final run in runs) {
      final verdicts = _verdicts(run);
      final traces = Directory(p.join(run, 'traces'));
      if (!traces.existsSync()) throw ArgumentError('$run has no traces');
      for (final file in traces.listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl'))) {
        final episodeId = p.basenameWithoutExtension(file.path);
        String? taskId;
        final invoked = <String>{};
        for (final line in file.readAsLinesSync()) {
          if (line.trim().isEmpty) continue;
          final event = asJsonMap(jsonDecode(line));
          final data = asJsonMap(event['data']);
          switch (event['type']) {
            case 'episode.meta':
              taskId = data['taskId'] as String?;
            case 'env.result' when catalogue == null && asJsonMap(data['payload'])['intents'] is List:
              catalogue = [
                for (final raw in asJsonMap(data['payload'])['intents'] as List)
                  {
                    'name': asJsonMap(raw)['name'],
                    'summary': asJsonMap(raw)['summary'] ?? '',
                    'aliases': asJsonMap(raw)['aliases'] ?? const [],
                    'kind': ?asJsonMap(raw)['kind'],
                  },
              ];
            case 'agent.envelope' when data['key'] == 'intents.invoke':
              final decision = asJsonMap(data['decision']);
              if (asJsonMap(decision['extra'])['prefetch'] == true) continue;
              if (asJsonMap(data['payload'])['intent'] case final String intent) invoked.add(intent);
          }
        }
        if (taskId == null || !tune.contains(taskId) || verdicts[episodeId] != 'success') continue;
        successes[taskId] = (successes[taskId] ?? 0) + 1;
        final counts = used.putIfAbsent(taskId, () => {});
        for (final intent in invoked) {
          counts[intent] = (counts[intent] ?? 0) + 1;
        }
      }
    }
    if (catalogue == null) throw ArgumentError('none of the runs recorded an intents catalogue');
    final listed = {for (final intent in catalogue) intent['name']};

    return {
      'suite': described['name'],
      'source': {'runs': runs, 'minShare': minShare, 'usefulShare': usefulShare},
      'catalogue': catalogue,
      'tasks': [
        for (final task in tasks)
          () {
            final id = task['id'] as String;
            final n = successes[id] ?? 0;
            final counts = used[id] ?? const <String, int>{};
            // Only what a selection can choose: an intent that appears later
            // (form.set, once form.open unlocked it) is not in the catalogue.
            List<String> share(double low, double high) => [
              for (final e in counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
                if (e.value / n >= low && e.value / n < high && listed.contains(e.key)) e.key,
            ];
            return {
              'id': id,
              'instruction': task['instruction'],
              'language': ?task['language'],
              'successes': n,
              if (n == 0) 'unlabelled': true,
              'needed': n == 0 ? <String>[] : share(minShare, double.infinity),
              'useful': n == 0 ? <String>[] : share(usefulShare, minShare),
            };
          }(),
      ],
    };
  }

  /// Episode id → verdict, from a judged run's `metrics.csv`.
  static Map<String, String> _verdicts(String run) {
    final file = File(p.join(run, 'metrics.csv'));
    if (!file.existsSync()) throw ArgumentError('$run is not evaluated (no metrics.csv); run aib evaluate first');
    final lines = file.readAsLinesSync();
    final header = lines.first.split(',');
    final episode = header.indexOf('episode_id');
    final verdict = header.indexOf('verdict');
    return {
      for (final line in lines.skip(1))
        if (line.split(',') case final cells when cells.length > verdict) cells[episode]: cells[verdict],
    };
  }

  /// Every [variants] × [backends] combination over the labelled tasks of
  /// [fixture]: per-task scores and the summary [summarise] reports.
  ///
  /// A variant is `{id, statement?, ifTrue?, ifFalse?, state?, candidate?}`;
  /// an id alone names a built-in [JevSelectionPrompt]. A backend is a `jev:`
  /// block. [onProgress] hears about every selection as it finishes.
  static Future<JsonMap> run({
    required JsonMap fixture,
    required List<JsonMap> variants,
    required Map<String, JsonMap> backends,
    Set<String>? taskIds,
    int repetitions = 1,
    void Function(String line)? onProgress,
    JevClient Function(JsonMap block) clientFor = LlmClientFactory.jevFromConfig,
  }) async {
    final catalogue = [for (final raw in fixture['catalogue'] as List) asJsonMap(raw)];
    final tasks = [
      for (final raw in fixture['tasks'] as List)
        if (asJsonMap(raw) case final task when taskIds == null || taskIds.contains(task['id'])) task,
    ];
    final results = <JsonMap>[];
    for (final MapEntry(key: backendName, value: block) in backends.entries) {
      final client = clientFor(block);
      if (client case final JevWarmUp warmable) await warmable.warmUp();
      for (final variant in variants) {
        final prompt = JevSelectionPrompt.fromJson(variant);
        final candidateText = _candidateText(variant['candidate']);
        final candidates = {
          for (final intent in catalogue)
            intent['name'] as String: candidateText.render(
              summary: '${intent['summary']}',
              aliases: [for (final alias in intent['aliases'] as List? ?? const []) '$alias'],
              kind: intent['kind'] as String?,
            ),
        };
        for (final task in tasks) {
          final language = task['language'] as String?;
          final selector = JevSelector(
            client: client,
            prompt: prompt,
            language: language == null ? const JevLanguagePolicy.matchState() : JevLanguagePolicy.fixed(language),
          );
          for (var rep = 1; rep <= repetitions; rep++) {
            final watch = Stopwatch()..start();
            try {
              final selection = await selector.selectFor(task: task['instruction'] as String, candidates: candidates);
              results.add({
                'backend': backendName,
                'variant': prompt.id,
                'candidate': candidateText.name,
                'task': task['id'],
                'rep': rep,
                'latencyMs': selection.spend.latencyMs > 0 ? selection.spend.latencyMs : watch.elapsedMilliseconds,
                'model': selection.spend.model,
                'scores': selection.scores,
              });
              onProgress?.call('$backendName ${_variantLabel(prompt.id, candidateText)} ${task['id']} ${watch.elapsedMilliseconds} ms');
            } on Exception catch (e) {
              results.add({
                'backend': backendName,
                'variant': prompt.id,
                'candidate': candidateText.name,
                'task': task['id'],
                'rep': rep,
                'error': '$e',
              });
              onProgress?.call('$backendName ${_variantLabel(prompt.id, candidateText)} ${task['id']} ERROR $e');
            }
          }
        }
      }
    }
    return {
      'fixture': {'suite': fixture['suite'], 'source': fixture['source']},
      'variants': variants,
      'backends': {for (final e in backends.entries) e.key: _redacted(e.value)},
      'selections': results,
    };
  }

  static String _variantLabel(String id, CandidateText text) => text == .summaryAliases ? id : '$id/${text.name}';

  static CandidateText _candidateText(Object? raw) => switch (raw) {
    null => CandidateText.summaryAliases,
    final String name when CandidateText.values.any((v) => v.name == name) => CandidateText.values.byName(name),
    _ => throw FormatException('candidate must be one of ${CandidateText.values.map((v) => v.name).join(', ')}, got $raw'),
  };

  /// A backend block without anything that looks like a secret.
  static JsonMap _redacted(JsonMap block) => {
    for (final e in block.entries)
      if (!RegExp('key|token|secret', caseSensitive: false).hasMatch(e.key) || e.key == 'apiKeyEnv') e.key: e.value,
  };

  /// Per backend × variant over the tasks with labels: recall at each
  /// threshold and floor, how many intents each keeps, whether every needed
  /// intent is in the top k, and how well the scores separate needed from
  /// not needed (AUC; 0.5 is chance).
  static List<JsonMap> summarise({
    required JsonMap fixture,
    required JsonMap result,
    List<double> thresholds = const [0.4, 0.5],
    List<int> ks = const [3, 5, 8],
    int minKeep = 5,
  }) {
    final needed = {
      for (final raw in fixture['tasks'] as List)
        if (asJsonMap(raw) case final task when (task['needed'] as List? ?? const []).isNotEmpty)
          task['id'] as String: {for (final name in task['needed'] as List) '$name'},
    };
    final summaries = {for (final raw in fixture['catalogue'] as List) '${asJsonMap(raw)['name']}': '${asJsonMap(raw)['summary']}'};
    final groups = <String, List<JsonMap>>{};
    for (final raw in result['selections'] as List) {
      final selection = asJsonMap(raw);
      groups.putIfAbsent('${selection['backend']}|${selection['variant']}|${selection['candidate']}', () => []).add(selection);
    }
    double mean(Iterable<num> values) => values.isEmpty ? double.nan : values.fold<double>(0, (a, b) => a + b) / values.length;

    return [
      for (final MapEntry(key: group, value: selections) in groups.entries)
        () {
          final [backend, variant, candidate] = group.split('|');
          final scored = [
            for (final s in selections)
              if (s['scores'] != null && needed.containsKey(s['task']))
                (task: s['task'] as String, scores: {for (final e in asJsonMap(s['scores']).entries) e.key: (e.value as num).toDouble()}),
          ];
          final recall = <String, double>{};
          final kept = <String, double>{};
          for (final t in thresholds) {
            recall['$t'] = mean([for (final s in scored) _recall(s.scores, needed[s.task]!, threshold: t)]);
            kept['$t'] = mean([for (final s in scored) s.scores.values.where((v) => v >= t).length]);
            recall['$t+min$minKeep'] = mean([for (final s in scored) _recall(s.scores, needed[s.task]!, threshold: t, minKeep: minKeep)]);
            kept['$t+min$minKeep'] = mean([for (final s in scored) _ranked(s.scores).indexed.where((e) => e.$2.value >= t || e.$1 < minKeep).length]);
            // SelectionExpand.references, as the preparer applies it.
            List<String> expanded(Map<String, double> scores) => SelectionExpand.references.expand([
              for (final e in _ranked(scores))
                if (e.value >= t) e.key,
            ], summaries);
            recall['$t+refs'] = mean([for (final s in scored) needed[s.task]!.where(expanded(s.scores).contains).length / needed[s.task]!.length]);
            kept['$t+refs'] = mean([for (final s in scored) expanded(s.scores).length]);
          }
          return {
            'backend': backend,
            'variant': variant,
            'candidate': candidate,
            'tasks': scored.length,
            'errors': selections.where((s) => s['error'] != null).length,
            'recall': recall,
            'kept': kept,
            'allNeededInTop': {
              for (final k in ks)
                '$k': mean([for (final s in scored) _ranked(s.scores).take(k).map((e) => e.key).toSet().containsAll(needed[s.task]!) ? 1 : 0]),
            },
            'worstNeededRank': mean([
              for (final s in scored)
                [
                  for (final (rank, e) in _ranked(s.scores).indexed)
                    if (needed[s.task]!.contains(e.key)) rank + 1,
                ].fold(0, (a, b) => a > b ? a : b),
            ]),
            'auc': mean([for (final s in scored) _auc(s.scores, needed[s.task]!)]),
            'meanNeeded': mean([for (final s in scored) ...s.scores.entries.where((e) => needed[s.task]!.contains(e.key)).map((e) => e.value)]),
            'meanOther': mean([for (final s in scored) ...s.scores.entries.where((e) => !needed[s.task]!.contains(e.key)).map((e) => e.value)]),
            'latencyMs': mean([
              for (final s in selections)
                if (s['latencyMs'] case final num ms) ms,
            ]),
          };
        }(),
    ];
  }

  static List<MapEntry<String, double>> _ranked(Map<String, double> scores) => scores.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

  static double _recall(Map<String, double> scores, Set<String> needed, {required double threshold, int minKeep = 0}) {
    final kept = {
      for (final (rank, e) in _ranked(scores).indexed)
        if (e.value >= threshold || rank < minKeep) e.key,
    };
    return needed.where(kept.contains).length / needed.length;
  }

  /// Probability that a needed intent outscores one that is not; ties half.
  static double _auc(Map<String, double> scores, Set<String> needed) {
    final pos = [
      for (final e in scores.entries)
        if (needed.contains(e.key)) e.value,
    ];
    final neg = [
      for (final e in scores.entries)
        if (!needed.contains(e.key)) e.value,
    ];
    if (pos.isEmpty || neg.isEmpty) return double.nan;
    var wins = 0.0;
    for (final a in pos) {
      for (final b in neg) {
        wins += a > b ? 1 : (a == b ? 0.5 : 0);
      }
    }
    return wins / (pos.length * neg.length);
  }

  /// [summarise] as a Markdown table, best AUC first.
  static String table(List<JsonMap> rows, {List<double> thresholds = const [0.4, 0.5], int minKeep = 5}) {
    String f(Object? v, [int digits = 2]) => v is num && !v.isNaN ? v.toStringAsFixed(digits) : '–';
    final sorted = [...rows]..sort((a, b) => ((b['auc'] as num?) ?? 0).compareTo((a['auc'] as num?) ?? 0));
    final columns = [
      for (final t in thresholds) ...['recall@$t', 'kept@$t'],
      'recall@${thresholds.last}+min$minKeep',
      'kept@${thresholds.last}+min$minKeep',
      'recall@${thresholds.last}+refs',
      'kept@${thresholds.last}+refs',
    ];
    return [
      '| backend | variant | candidate | AUC | needed | other | ${columns.join(' | ')} | all in top 5 | worst rank | ms |',
      '|${List.filled(9 + columns.length, '---').join('|')}|',
      for (final row in sorted)
        () {
          final recall = asJsonMap(row['recall']);
          final kept = asJsonMap(row['kept']);
          final cells = [
            for (final t in thresholds) ...[f(recall['$t']), f(kept['$t'], 1)],
            f(recall['${thresholds.last}+min$minKeep']),
            f(kept['${thresholds.last}+min$minKeep'], 1),
            f(recall['${thresholds.last}+refs']),
            f(kept['${thresholds.last}+refs'], 1),
          ];
          return '| ${row['backend']} | ${row['variant']} | ${row['candidate']} | ${f(row['auc'])} | ${f(row['meanNeeded'])} | '
              '${f(row['meanOther'])} | ${cells.join(' | ')} | ${f(asJsonMap(row['allNeededInTop'])['5'])} | ${f(row['worstNeededRank'], 1)} | '
              '${f(row['latencyMs'], 0)} |';
        }(),
    ].join('\n');
  }
}
