import 'dart:convert';
import 'dart:math' as math;

import 'package:aib_core/aib_core.dart';

/// One rubric the judge answered on one episode, with what it was shown.
typedef JudgedRubric = ({RubricSpec rubric, JsonMap artifact, JsonMap evidence});

/// One judged episode of a calibration sample (§5.2).
final class LabelItem {
  const LabelItem({
    required this.labelId,
    required this.runName,
    required this.trace,
    required this.task,
    required this.rubrics,
    required this.anyNo,
  });

  /// The id a label row names: the episode id, prefixed with the run
  /// directory's name when the sample spans runs (`aib calibrate --run` does
  /// the same, so the two agree).
  final String labelId;
  final String runName;
  final EpisodeTrace trace;
  final TaskSpec task;
  final List<JudgedRubric> rubrics;

  /// Whether the judge answered no to any criterion — a sampling stratum,
  /// never shown on the sheet.
  final bool anyNo;
}

/// The label id of [episodeId] in a sample over [runCount] runs.
String labelIdOf(String runName, String episodeId, {required int runCount}) => runCount > 1 ? '$runName/$episodeId' : episodeId;

/// Every episode of one run a rubric judge actually voted on.
///
/// Rebuilds the artifact and the evidence digest the way
/// `ArtifactRubricEvaluator` did when it asked the judge, so the person
/// labelling sees what the judge saw — not a re-implementation of it. A
/// criterion that recorded no votes (no artifact, skipped, empty) is left out:
/// there is no judge answer to agree or disagree with.
List<LabelItem> judgedEpisodes({
  required String runName,
  required int runCount,
  required List<EpisodeTrace> traces,
  required Map<String, Verdict> verdicts,
  required TaskSuite suite,
}) {
  final items = <LabelItem>[];
  for (final trace in traces) {
    final verdict = verdicts[trace.meta.episodeId];
    final task = suite.taskById(trace.meta.taskId);
    if (verdict == null || task == null) continue;
    final voted = <String, JsonMap>{
      for (final detail in verdict.detailsOfType(CriterionTypes.artifactRubric))
        if (detail case {'votes': Map(isNotEmpty: true), 'rubric': final String rubric}) rubric: detail,
    };
    if (voted.isEmpty) continue;

    final rubrics = <JudgedRubric>[];
    for (final criterion in task.successCriteria) {
      if (criterion.type != CriterionTypes.artifactRubric) continue;
      final spec = criterion.config['rubricSpec'];
      if (spec == null) continue;
      final rubric = RubricSpec.fromJson(asJsonMap(spec));
      if (!voted.containsKey(rubric.name)) continue;
      final artifact = ArtifactRubricEvaluator.extractArtifact(trace, artifactKeys: ArtifactRubricEvaluator.artifactKeysOf(criterion.config));
      if (artifact == null) continue;
      rubrics.add((rubric: rubric, artifact: artifact, evidence: criterion.config['evidence'] == true ? episodeEvidence(trace) : const {}));
    }
    if (rubrics.isEmpty) continue;

    final anyNo = voted.values.any((detail) {
      final k = (detail['k'] as num?)?.toInt() ?? 1;
      return asJsonMap(detail['votes']).values.any((v) => v is num && v.toInt() * 2 <= k);
    });
    items.add(
      LabelItem(
        labelId: labelIdOf(runName, trace.meta.episodeId, runCount: runCount),
        runName: runName,
        trace: trace,
        task: task,
        rubrics: rubrics,
        anyNo: anyNo,
      ),
    );
  }
  return items;
}

/// A seeded sample of [size] episodes, spread over tasks and over what the
/// judge answered.
///
/// Strata are task × "judge said no somewhere". Taking one episode per stratum
/// in turn avoids the constant-rater sample ADR 0008 warns about. The judge's
/// answer only picks the stratum; it is never shown to the person labelling.
List<LabelItem> stratifiedSample(List<LabelItem> items, {required int size, int seed = 42}) {
  final random = math.Random(seed);
  final shuffled = [...items]
    ..sort((a, b) => a.labelId.compareTo(b.labelId))
    ..shuffle(random);

  // A rubric every task carries would otherwise fill the sample, so the draw
  // alternates between episodes with a task-specific rubric and episodes
  // without one.
  final carriers = <String, int>{};
  for (final item in items) {
    for (final judged in item.rubrics) {
      carriers.update(judged.rubric.name, (n) => n + 1, ifAbsent: () => 1);
    }
  }
  bool specific(LabelItem item) => item.rubrics.any((r) => carriers[r.rubric.name]! * 2 < items.length);

  List<List<LabelItem>> strataOf(Iterable<LabelItem> group) {
    final strata = <String, List<LabelItem>>{};
    for (final item in group) {
      strata.putIfAbsent('${item.task.id}|${item.anyNo}', () => []).add(item);
    }
    final keys = strata.keys.toList()
      ..sort()
      ..shuffle(random);
    return [for (final key in keys) strata[key]!];
  }

  final groups = [strataOf(shuffled.where(specific)), strataOf(shuffled.where((item) => !specific(item)))];
  final cursors = [0, 0];
  final sample = <LabelItem>[];
  bool remaining(List<List<LabelItem>> strata) => strata.any((s) => s.isNotEmpty);
  while (sample.length < size && groups.any(remaining)) {
    for (final (g, strata) in groups.indexed) {
      if (sample.length >= size || !remaining(strata)) continue;
      // Next non-empty stratum of this group, round-robin.
      while (strata[cursors[g] % strata.length].isEmpty) {
        cursors[g]++;
      }
      sample.add(strata[cursors[g] % strata.length].removeAt(0));
      cursors[g]++;
    }
  }
  sample.sort((a, b) => a.labelId.compareTo(b.labelId));
  return sample;
}

/// `labels.csv`: one `?` row per criterion, so an unlabelled row fails
/// `aib calibrate` loudly instead of counting as a no.
String labelsCsv(List<LabelItem> sample) {
  final buffer = StringBuffer()
    ..writeln('# episode_id,rubric:criterion,label   (label: yes | no)')
    ..writeln('# Replace every ? — aib calibrate refuses the file otherwise.');
  for (final item in sample) {
    for (final judged in item.rubrics) {
      for (final criterion in judged.rubric.criteria) {
        buffer.writeln('${item.labelId},${judged.rubric.name}:${criterion.id},?');
      }
    }
  }
  return buffer.toString();
}

/// `labels.md`: per episode the instruction, the artifact, the record the
/// judge was given, and the questions — without the judge's answers.
String labelsMarkdown(List<LabelItem> sample, {required List<String> runs, required int population, required int seed}) {
  const encoder = JsonEncoder.withIndent('  ');
  final buffer = StringBuffer()
    ..writeln('# Manual labels for judge calibration')
    ..writeln()
    ..writeln(
      '${sample.length} of $population judged episodes, seed $seed, from: '
      '${runs.map((r) => '`$r`').join(', ')}.',
    )
    ..writeln()
    ..writeln('How to label:')
    ..writeln()
    ..writeln(
      '1. Read the instruction, what the agent said, and — where a rubric '
      'checks the claim against the record — the record. It is the digest '
      'the judge was given, including its cuts; judge from it, not from what '
      'you know about the app.',
    )
    ..writeln(
      '2. Answer each question with `yes` or `no` in `labels.csv` (same '
      'episode id, same `rubric:criterion`). The judge\'s answers are not on '
      'this sheet on purpose; `aib calibrate` lists every disagreement '
      'afterwards.',
    )
    ..writeln(
      '3. Answer the question as written, even where you think it is the '
      'wrong question. A rubric defect is a finding; note it separately.',
    )
    ..writeln(
      '4. A rubric with a scope line judges only what the scope says. For a '
      'claim rubric that means: is the statement true of the record — not '
      'whether the agent did the right thing. A true report of a wrong action '
      'is a yes.',
    )
    ..writeln(
      '5. The statement answers the last user message in the record, which is '
      'not always the instruction: follow-ups and corrections are listed in '
      'the record where they were said.',
    )
    ..writeln(
      '6. Values in the list below are cut for reading. Open the full record '
      'before answering no for a value you cannot find: the judge saw all of '
      'it. `aib_ui` (Label view) shows everything uncut.',
    );

  for (final (index, item) in sample.indexed) {
    buffer
      ..writeln()
      ..writeln('---')
      ..writeln()
      ..writeln('## ${index + 1} · `${item.labelId}`')
      ..writeln()
      ..writeln(
        'Task `${item.task.id}` · agent `${item.trace.meta.agentId}` · '
        'run `${item.runName}` · ended: '
        '`${item.trace.endReason ?? 'unknown'}`',
      )
      ..writeln()
      ..writeln('**Instruction**')
      ..writeln()
      ..writeln('> ${item.task.instruction.trim().replaceAll('\n', '\n> ')}');

    // Rubrics of one episode usually judge the same artifact; show it once.
    final shownArtifacts = <String>{};
    var evidenceShown = false;
    for (final judged in item.rubrics) {
      final artifact = encoder.convert(judged.artifact);
      if (shownArtifacts.add(artifact)) {
        buffer
          ..writeln()
          ..writeln('**What the agent said / produced**')
          ..writeln()
          ..writeln('```json')
          ..writeln(artifact)
          ..writeln('```');
      }
      if (judged.evidence.isNotEmpty && !evidenceShown) {
        evidenceShown = true;
        buffer
          ..writeln()
          ..writeln('**The record** (what the judge saw)')
          ..writeln()
          ..write(_recordMarkdown(judged.evidence));
      }
    }

    buffer
      ..writeln()
      ..writeln('**Questions**')
      ..writeln();
    for (final judged in item.rubrics) {
      if (judged.rubric.scope case final scope?) {
        buffer.writeln('*Scope of `${judged.rubric.name}`: ${scope.replaceAll(RegExp(r'\s+'), ' ')}*\n');
      }
      for (final criterion in judged.rubric.criteria) {
        buffer.writeln(
          '- `${judged.rubric.name}:${criterion.id}` — '
          '${criterion.question.trim().replaceAll(RegExp(r'\s+'), ' ')}',
        );
      }
    }
  }
  return buffer.toString();
}

/// The evidence digest as a readable list, the whole digest folded below it.
String _recordMarkdown(JsonMap evidence) {
  const preview = 400;
  String cut(Object? value) {
    final text = '$value';
    return text.length <= preview ? text : '${text.substring(0, preview)}…';
  }

  final buffer = StringBuffer();
  final actions = evidence['actions'] as List? ?? const [];
  for (final (index, raw) in actions.indexed) {
    final action = asJsonMap(raw);
    if (action['user'] case final said?) {
      buffer.writeln('${index + 1}. **user** (${action['when'] ?? 'later'}): ${'$said'.replaceAll('\n', ' ')}');
      continue;
    }
    buffer.writeln(
      '${index + 1}. `${action['did']}`'
      '${action['result'] == null ? '' : ' → ${action['result']}'}'
      '${action['changedTheApp'] == true ? ' (changed the app)' : ''}',
    );
    for (final key in const ['with', 'returned', 'error']) {
      if (action[key] case final value?) {
        buffer.writeln('   - $key: `${cut(value).replaceAll('`', "'")}`');
      }
    }
  }
  buffer
    ..writeln()
    ..writeln(
      'Ended because `${evidence['endedBecause']}`; any change to the app: '
      '${evidence['anyChangeToTheApp']}.',
    );
  if (evidence['finalState'] case final state?) {
    buffer.writeln('Final state: `${cut(state).replaceAll('`', "'")}`');
  }
  buffer
    ..writeln()
    ..writeln(
      '<details><summary>Full record (values above are cut at $preview '
      'characters)</summary>',
    )
    ..writeln()
    ..writeln('```json')
    ..writeln(const JsonEncoder.withIndent('  ').convert(evidence))
    ..writeln('```')
    ..writeln()
    ..writeln('</details>');
  return buffer.toString();
}
