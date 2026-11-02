import 'dart:convert';

import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

/// P5 — judge calibration (§5.2: "κ is reported in the thesis").

EpisodeRecord _record(String episodeId, {required VerdictType type, Map<String, int>? votes, int k = 3}) => EpisodeRecord(
  runId: 'r',
  episodeId: episodeId,
  taskId: 'dash',
  agentId: 'genui',
  repetition: 1,
  verdict: Verdict(
    type: type,
    score: type == .success ? 1 : 0,
    details: votes == null
        ? const {}
        : {
            CriterionTypes.artifactRubric: {'score': type == .success ? 1.0 : 0.0, 'k': k, 'votes': votes},
          },
  ),
  metrics: const {},
);

void main() {
  group('parseLabels', () {
    test('accepts the documented spellings and skips header/comments', () {
      final labels = JudgeCalibration.parseLabels('''
# manual labels, 2026-08-06
episode_id,label
e1,success
e2,failure
e3,1
e4,0
e5,TRUE
e6,fail
''');
      expect(labels, {
        'e1': HumanLabel.success,
        'e2': HumanLabel.failure,
        'e3': HumanLabel.success,
        'e4': HumanLabel.failure,
        'e5': HumanLabel.success,
        'e6': HumanLabel.failure,
      });
    });

    test('rejects an unknown label instead of guessing', () {
      expect(() => JudgeCalibration.parseLabels('e1,maybe'), throwsFormatException);
      expect(() => JudgeCalibration.parseLabels('e1'), throwsFormatException);
    });
  });

  group('per-criterion calibration', () {
    test('one CSV carries both levels', () {
      const csv = '''
# labels
episode_id,label
e1,failure
e1,all_open,yes
e1,no_completed,no
e2,criterion with spaces , 1
''';
      expect(JudgeCalibration.parseLabels(csv), {'e1': HumanLabel.failure}, reason: 'three-column rows belong to the criterion level');
      expect(JudgeCalibration.parseCriterionLabels(csv), {
        (episodeId: 'e1', criterionId: 'all_open'): HumanLabel.success,
        (episodeId: 'e1', criterionId: 'no_completed'): HumanLabel.failure,
        (episodeId: 'e2', criterionId: 'criterion with spaces'): HumanLabel.success,
      });
    });

    test('κ stays informative where the episode verdict is constant', () {
      // Every episode earns partial credit, so every *episode* verdict is
      // "not success" and episode-level κ is undefined — while the judge
      // still answered 4 questions per episode, 3 of them correctly.
      final records = [
        _record('e1', type: .partial, votes: {'a': 3, 'b': 0, 'c': 3, 'd': 2}),
        _record('e2', type: .partial, votes: {'a': 3, 'b': 3, 'c': 0, 'd': 1}),
      ];
      final episodeLevel = JudgeCalibration.compare(records, const {'e1': HumanLabel.failure, 'e2': HumanLabel.failure});
      expect(episodeLevel.kappa, isNaN, reason: 'no variance in either rater');

      final perCriterion = CriterionCalibration.compare(records, const {
        // judge: yes,  no,  yes, yes(2/3 majority)
        (episodeId: 'e1', criterionId: 'a'): HumanLabel.success,
        (episodeId: 'e1', criterionId: 'b'): HumanLabel.failure,
        (episodeId: 'e1', criterionId: 'c'): HumanLabel.success,
        (episodeId: 'e1', criterionId: 'd'): HumanLabel.failure,
        // judge: yes, yes,  no,  no(1/3)
        (episodeId: 'e2', criterionId: 'a'): HumanLabel.success,
        (episodeId: 'e2', criterionId: 'b'): HumanLabel.success,
        (episodeId: 'e2', criterionId: 'c'): HumanLabel.failure,
        (episodeId: 'e2', criterionId: 'd'): HumanLabel.failure,
      });
      expect(perCriterion.n, 8);
      expect(perCriterion.truePositives, 4);
      expect(perCriterion.trueNegatives, 3);
      expect(perCriterion.falsePositives, 1, reason: 'e1/d: 2 of 3 votes yes');
      expect(perCriterion.disagreements, ['e1/d']);
      expect(perCriterion.kappa, greaterThan(0.7));
      expect(perCriterion.toMarkdown(), contains('judge: yes'));
    });

    test('labels for episodes or criteria the run lacks are reported', () {
      final calibration = CriterionCalibration.compare(
        [
          _record('e1', type: .partial, votes: {'a': 3}),
        ],
        const {(episodeId: 'e1', criterionId: 'nope'): HumanLabel.success, (episodeId: 'ghost', criterionId: 'a'): HumanLabel.success},
      );
      expect(calibration.n, 0);
      expect(calibration.missing, ['e1/nope', 'ghost/a']);
      expect(calibration.kappa, isNaN);
    });
  });

  group('compare', () {
    test('perfect agreement gives κ = 1 and F1 = 1', () {
      final calibration = JudgeCalibration.compare(
        [_record('e1', type: .success), _record('e2', type: .failure)],
        const {'e1': HumanLabel.success, 'e2': HumanLabel.failure},
      );
      expect(calibration.kappa, 1);
      expect(calibration.agreement, 1);
      expect(calibration.f1, 1);
      expect(calibration.disagreements, isEmpty);
    });

    test('confusion matrix and F1 on a mixed sample', () {
      // 2 TP, 1 FP, 1 FN, 2 TN
      final calibration = JudgeCalibration.compare(
        [
          _record('tp1', type: .success),
          _record('tp2', type: .success),
          _record('fp1', type: .success),
          _record('fn1', type: .failure),
          _record('tn1', type: .failure),
          _record('tn2', type: .failure),
        ],
        const {
          'tp1': HumanLabel.success,
          'tp2': HumanLabel.success,
          'fp1': HumanLabel.failure,
          'fn1': HumanLabel.success,
          'tn1': HumanLabel.failure,
          'tn2': HumanLabel.failure,
        },
      );
      expect(calibration.truePositives, 2);
      expect(calibration.falsePositives, 1);
      expect(calibration.falseNegatives, 1);
      expect(calibration.trueNegatives, 2);
      expect(calibration.agreement, closeTo(4 / 6, 1e-12));
      expect(calibration.precision, closeTo(2 / 3, 1e-12));
      expect(calibration.recall, closeTo(2 / 3, 1e-12));
      expect(calibration.f1, closeTo(2 / 3, 1e-12));
      expect(calibration.disagreements, ['fn1', 'fp1']);
    });

    test('partial verdicts count as "not solved" against a human success', () {
      final calibration = JudgeCalibration.compare([_record('e1', type: .partial)], const {'e1': HumanLabel.success});
      expect(calibration.falseNegatives, 1);
    });

    test('framework faults are excluded — there is nothing to label', () {
      final calibration = JudgeCalibration.compare(
        [_record('e1', type: .success), _record('crashed', type: .error)],
        const {'e1': HumanLabel.success, 'crashed': HumanLabel.failure},
      );
      expect(calibration.n, 1);
      expect(calibration.missing, ['crashed'], reason: 'the label has no scoreable episode to attach to');
    });

    test('unlabelled episodes are counted, not silently dropped', () {
      final calibration = JudgeCalibration.compare(
        [_record('e1', type: .success), _record('e2', type: .success), _record('e3', type: .success)],
        const {'e1': HumanLabel.success},
      );
      expect(calibration.n, 1);
      expect(calibration.unlabelled, 2);
    });

    test('κ discounts agreement that chance alone would produce', () {
      // The automatic verdict says success everywhere; so does the human.
      // Raw agreement is 1, but there is no variance to agree about, so
      // κ = 0/0. Reporting 1 here would advertise a perfect judge on a
      // sample that cannot show agreement at all — the calibration prints
      // "—" and serializes null instead, next to the raw agreement and n.
      final calibration = JudgeCalibration.compare(
        [for (var i = 0; i < 4; i++) _record('e$i', type: .success)],
        {for (var i = 0; i < 4; i++) 'e$i': HumanLabel.success},
      );
      expect(calibration.agreement, 1);
      expect(calibration.kappa, isNaN);
      expect(calibration.toJson()['kappa'], isNull);
      expect(calibration.toMarkdown(), contains("| Cohen's κ | — [—, —] |"));
    });
  });

  group('judge stability', () {
    test('counts non-unanimous majorities per rubric criterion', () {
      final calibration = JudgeCalibration.compare(
        [
          // unanimous yes, split 2:1, unanimous no
          _record('e1', type: .success, votes: const {'a': 3, 'b': 2, 'c': 0}),
        ],
        const {'e1': HumanLabel.success},
      );
      expect(calibration.judgedCriteria, 3);
      expect(calibration.splitDecisions, 1);
      expect(calibration.splitRate, closeTo(1 / 3, 1e-12));
    });

    test('runs without rubric criteria report no split rate', () {
      final calibration = JudgeCalibration.compare([_record('e1', type: .success)], const {'e1': HumanLabel.success});
      expect(calibration.judgedCriteria, 0);
      expect(calibration.splitRate, isNaN);
    });
  });

  test('the markdown artifact carries every number the thesis needs', () {
    // One true positive, one false positive, one true negative — so
    // precision, recall and F1 are all defined.
    final calibration = JudgeCalibration.compare(
      [
        _record('e1', type: .success, votes: const {'a': 3}),
        _record('e2', type: .success, votes: const {'a': 2}),
        _record('e3', type: .failure, votes: const {'a': 0}),
      ],
      const {'e1': HumanLabel.success, 'e2': HumanLabel.failure, 'e3': HumanLabel.failure},
    );
    final markdown = calibration.toMarkdown(runId: 'run-1', judgeId: 'claude-sonnet-4-6 (judge_v1)');

    expect(markdown, contains("Cohen's κ"));
    expect(markdown, contains('F1'));
    expect(markdown, contains('Confusion matrix'));
    expect(markdown, contains('Judge stability'));
    expect(markdown, contains('`e2`'), reason: 'disagreements are listed');
    expect(markdown, contains('claude-sonnet-4-6'));

    expect(calibration.precision, closeTo(0.5, 1e-12));
    expect(calibration.recall, 1.0);
    expect(calibration.f1, closeTo(2 / 3, 1e-12));
    expect(calibration.toJson()['f1'], isNotNull);
    expect(
      calibration.splitDecisions,
      1,
      reason:
          'e2 was decided 2:1 — exactly the episode the human '
          'disagreed with',
    );
  });

  test('a sheet labelled per criterion only prints no empty episode table', () {
    final markdown = JudgeCalibration.compare([_record('e1', type: .partial)], const {}).toMarkdown();
    expect(markdown, contains('Episode-level labels: none'));
    expect(markdown, isNot(contains('Confusion matrix')));
  });

  test('undefined statistics serialize as null, not NaN (JSON has no NaN)', () {
    // No automatic successes and no rubric criteria -> precision, recall, F1
    // and the split rate are all undefined.
    final json = JudgeCalibration.compare([_record('e1', type: .failure)], const {'e1': HumanLabel.failure}).toJson();

    expect(json['f1'], isNull);
    expect(json['precision'], isNull);
    expect(json['splitRate'], isNull);
    expect(json['agreement'], 1.0);
    expect(() => jsonEncode(json), returnsNormally);
  });
}
