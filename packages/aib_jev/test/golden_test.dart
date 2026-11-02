import 'dart:convert';
import 'dart:io';

import 'package:aib_jev/aib_jev.dart';
import 'package:test/test.dart';

/// The port against the reference: every string the v1 template produces,
/// the Qwen3.5 rendering of every branch, and every scored answer, compared
/// with what simple-jev's own code produced for the same requests
/// (`tool/jev_golden.py`, pinned commit). A difference here is a different
/// decider, not a formatting detail.
void main() {
  final golden = asJsonMap(jsonDecode(File('test/fixtures/golden_v1.json').readAsStringSync()));
  final cases = asJsonMap(golden['cases']);

  for (final MapEntry(key: name, value: raw) in cases.entries) {
    final fixture = asJsonMap(raw);
    group(name, () {
      final request = JevRequest.fromJson(asJsonMap(fixture['request']));
      final plan = JevTemplate.v1.plan(request);

      test('shared strings', () {
        expect(plan.systemPromptPrefix, fixture['system_prompt_prefix']);
        expect(plan.prefixInstruction, fixture['prefix_instruction']);
        expect(plan.suffixInstruction, fixture['suffix_instruction']);
      });

      final branches = fixture['branches']! as List;
      test('branches, labels and answer prefixes', () {
        expect(plan.branches, hasLength(branches.length));
        for (final (i, rawBranch) in branches.indexed) {
          final expected = asJsonMap(rawBranch);
          final branch = plan.branches[i];
          expect(branch.branchId, expected['branch_id']);
          expect(branch.questionId, expected['question_id']);
          expect(branch.instruction, expected['instruction'], reason: 'instruction of ${branch.questionId}');
          expect(branch.answerPrefix, expected['answer_prefix']);
          expect(branch.outputLabels, expected['output_labels']);
          expect(branch.answerLabels, expected['answer_labels']);
        }
      });

      test('chat turns per branch', () {
        for (final (i, rawBranch) in branches.indexed) {
          final expected = [for (final m in asJsonMap(rawBranch)['messages']! as List) asJsonMap(m)];
          expect([for (final turn in plan.turnsFor(plan.branches[i])) turn.toJson()], expected);
        }
      });

      test('Qwen3.5 rendering matches the tokenizer\'s own chat template', () {
        for (final (i, rawBranch) in branches.indexed) {
          final branch = plan.branches[i];
          expect(JevChatFormat.qwen35.render(plan.turnsFor(branch), branch.answerPrefix), asJsonMap(rawBranch)['rendered_qwen35']);
        }
      });

      for (final MapEntry(key: setName, value: rawSet) in asJsonMap(fixture['scored']).entries) {
        test('scoring: $setName logits', () {
          final set = asJsonMap(rawSet);
          final logits = asJsonMap(set['logits']);
          final expected = asJsonMap(asJsonMap(set['response'])['answers']);
          for (final branch in plan.branches) {
            final row = asJsonMap(logits[branch.branchId]);
            final answer = scoreBranch(branch, [
              for (final label in branch.outputLabels) (row[label]! as num).toDouble(),
            ], rawLogits: request.options.rawLogits);
            _expectJsonClose(answer.raw, asJsonMap(expected[branch.questionId]), path: '$name.${branch.questionId}');
          }
        });
      }
    });
  }

  test('canonical JSON writes floats the way Python does', () {
    expect([1.0, 2.5, 1e16, 1.5e16, 1e15, 1e-5, 0.0001, 123456.789, -0.0, 1e20, 5e-324].map(jevPythonFloat).toList(), [
      '1.0',
      '2.5',
      '1e+16',
      '1.5e+16',
      '1000000000000000.0',
      '1e-05',
      '0.0001',
      '123456.789',
      '-0.0',
      '1e+20',
      '5e-324',
    ]);
    expect(jevCanonicalJson({'b': 1, 'a': 'ü\u0001', 'c': null}), '{"a":"ü\\u0001","b":1,"c":null}');
    expect(() => jevCanonicalJson(double.nan), throwsArgumentError);
  });
}

/// Equal as JSON, with numbers compared to 1e-5: the reference computes in
/// float32, the port in float64 after rounding its inputs to float32.
void _expectJsonClose(Object? actual, Object? expected, {required String path}) {
  switch (expected) {
    case final Map<String, Object?> map:
      expect(actual, isA<Map<String, Object?>>(), reason: path);
      final got = actual! as Map<String, Object?>;
      expect(got.keys.toSet(), map.keys.toSet(), reason: '$path keys');
      for (final key in map.keys) {
        _expectJsonClose(got[key], map[key], path: '$path.$key');
      }
    case final List<Object?> list:
      expect(actual, isA<List<Object?>>(), reason: path);
      final got = actual! as List<Object?>;
      expect(got, hasLength(list.length), reason: path);
      for (var i = 0; i < list.length; i++) {
        _expectJsonClose(got[i], list[i], path: '$path[$i]');
      }
    case final num value:
      expect(actual, isA<num>(), reason: path);
      expect((actual! as num).toDouble(), closeTo(value.toDouble(), 1e-5 + value.abs() * 1e-5), reason: path);
    default:
      expect(actual, expected, reason: path);
  }
}
