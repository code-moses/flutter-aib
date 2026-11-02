@Tags(['live'])
library;

import 'dart:io';

import 'package:aib_jev/aib_jev.dart';
import 'package:test/test.dart';

/// Against a running Ollama — opt-in, because it needs the model pulled:
///
///     JEV_OLLAMA_MODEL=qwen3:4b fvm dart test -t live test/ollama_live_test.dart
///
/// Checks the things a mock cannot: that the rendered raw prompt puts the
/// labels among Ollama's top 20, that the answers point the right way on
/// obvious cases in both languages, and what a decision costs warm.
void main() {
  final model = Platform.environment['JEV_OLLAMA_MODEL'];
  final baseUrl = Platform.environment['JEV_OLLAMA_URL'] ?? 'http://localhost:11434';
  final skip = model == null ? 'set JEV_OLLAMA_MODEL to run against a live Ollama' : null;

  group('Ollama $model', skip: skip, () {
    late LogitJevClient client;
    late LogitJevClient reference;
    setUpAll(() async {
      final logits = OllamaJevLogits.auto(model: model!, baseUrl: baseUrl);
      client = LogitJevClient(logits: logits, template: .v1NoulDecimal);
      reference = LogitJevClient(logits: logits, template: .v1);
      await client.warmUp();
    });

    Future<JevResponse> ask(String state) => client.decide(
      JevRequest(
        state: JevState.text(state),
        questions: {
          'color': const JevChoice(instructions: 'Which color is the bicycle?', criteria: {'red': null, 'blue': null}),
          'deletes': const JevNoul(instructions: 'The task deletes data.'),
          'steps': const JevScore(instructions: 'How many steps does the task need?', levels: ['one', 'a few', 'many']),
        },
      ),
    );

    test('obvious answers point the right way, in English and German', () async {
      final en = await ask('The bicycle is blue. Task: delete every archived customer record.');
      expect(en.answer<JevChoiceAnswer>('color').choice, 'blue');
      expect(en.answer<JevNoulAnswer>('deletes').noul, greaterThan(0.5));

      final de = await ask('Das Fahrrad ist rot. Aufgabe: Zeige mir die Liste der Kunden.');
      expect(de.answer<JevChoiceAnswer>('color').choice, 'red');
      expect(de.answer<JevNoulAnswer>('deletes').noul, lessThan(0.5));
      expect(de.metadata.backend, 'ollama-raw');
      expect(de.metadata.templateVersion, 'v1-noul-decimal');
    });

    // The finding behind JevTemplate.v1NoulDecimal, kept as a test so it is
    // re-checked on every model this runs against: under the exact v1
    // prompt the model wants to write "0.x", and the noul cannot tell a
    // true statement from a false one.
    test('v1 noul collapses: the first token is "0"', () async {
      final plan = JevTemplate.v1.plan(
        JevRequest.ask('Task: delete every archived customer record.', 'q', const JevNoul(instructions: 'The task deletes data.')),
      );
      final branch = plan.branches.single;
      final read = await reference.logits.labelLogits(
        JevScoringPrompt(turns: plan.turnsFor(branch), answerPrefix: branch.answerPrefix, labels: ['0', ...branch.outputLabels]),
      );
      print('$model: logprob of "0" under v1 = ${read.logits.first.toStringAsFixed(3)}');
      expect(read.logits.first, greaterThan(read.logits.skip(1).reduce((a, b) => a > b ? a : b)));
    });

    test('warm latency per decision', () async {
      const runs = 5;
      final watch = Stopwatch()..start();
      for (var i = 0; i < runs; i++) {
        await client.decide(JevRequest.ask('Rename project X to Y.', 'harm', const JevNoul(instructions: 'The task deletes data.')));
      }
      final ms = watch.elapsedMilliseconds / runs;
      print('$model: ${ms.toStringAsFixed(0)} ms per one-question decision (warm, n=$runs)');
      expect(ms, lessThan(1500));
    });
  });
}
