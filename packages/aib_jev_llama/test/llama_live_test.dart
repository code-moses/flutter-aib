@Tags(['live'])
library;

import 'dart:io';

import 'package:aib_jev/aib_jev.dart';
import 'package:aib_jev_llama/aib_jev_llama.dart';
import 'package:test/test.dart';

/// Needs a GGUF file — an Ollama blob works:
///
///     JEV_GGUF=~/.ollama/models/blobs/sha256-… JEV_OLLAMA_MODEL=qwen3:1.7b \
///       fvm dart test -t live
///
/// With JEV_OLLAMA_MODEL naming the same weights in Ollama, the in-process
/// probabilities are compared against Ollama's for the same prompts: same
/// weights, same Dart-rendered prompt, two runtimes.
void main() {
  final gguf = Platform.environment['JEV_GGUF'];
  final ollamaModel = Platform.environment['JEV_OLLAMA_MODEL'];

  group('llama.cpp in-process', skip: gguf == null ? 'set JEV_GGUF to a GGUF file' : null, () {
    late LlamaJevLogits logits;
    late LogitJevClient client;

    setUpAll(() async {
      logits = LlamaJevLogits(modelPath: gguf!, renderer: JevChatFormat.qwen3.renderer, model: ollamaModel ?? 'gguf');
      client = LogitJevClient(logits: logits, template: .v1NoulDecimal);
      final watch = Stopwatch()..start();
      await client.warmUp();
      print('load: ${watch.elapsedMilliseconds} ms');
    });
    tearDownAll(() => logits.close());

    JevRequest request(String state) => JevRequest(
      state: JevState.text(state),
      questions: {
        'color': const JevChoice(instructions: 'Which color is the bicycle?', criteria: {'red': null, 'blue': null}),
        'deletes': const JevNoul(instructions: 'The task deletes data.'),
        'tool': JevChoice(
          instructions: 'Which tool fits the task?',
          criteria: {for (var i = 0; i < 30; i++) 'tool_$i': i == 17 ? 'delete records' : 'tool number $i'},
        ),
      },
    );

    test('answers, with the shared prefix served from the KV cache', () async {
      final response = await client.decide(request('The bicycle is blue. Task: delete every archived customer record.'));
      expect(response.answer<JevChoiceAnswer>('color').choice, 'blue');
      // 30 candidates: more than Ollama could read, no floor needed here.
      expect(response.answer<JevChoiceAnswer>('tool').raw['missing_labels'], isNull);
      expect(response.metadata.backend, 'llama.cpp');
      print('evaluated ${response.usage.inputTokens} tokens for 3 branches');

      final watch = Stopwatch()..start();
      const runs = 5;
      for (var i = 0; i < runs; i++) {
        await client.decide(JevRequest.ask('Rename project X to Y.', 'harm', const JevNoul(instructions: 'The task deletes data.')));
      }
      print('warm: ${(watch.elapsedMilliseconds / runs).toStringAsFixed(0)} ms per one-question decision');
    });

    test('agrees with Ollama on the same weights and prompt', skip: ollamaModel == null ? 'set JEV_OLLAMA_MODEL to compare' : null, () async {
      final ollama = LogitJevClient(
        logits: OllamaJevLogits(model: ollamaModel!, renderer: JevChatFormat.qwen3.renderer),
        template: .v1NoulDecimal,
      );
      for (final state in [
        'The bicycle is blue. Task: delete every archived customer record.',
        'Das Fahrrad ist rot. Aufgabe: Zeige mir die Liste der Kunden.',
      ]) {
        final small = JevRequest(state: JevState.text(state), questions: {...request(state).questions}..remove('tool'));
        final a = await client.decide(small);
        final b = await ollama.decide(small);
        final pa = a.answer<JevChoiceAnswer>('color').probabilityOf('blue');
        final pb = b.answer<JevChoiceAnswer>('color').probabilityOf('blue');
        final na = a.answer<JevNoulAnswer>('deletes').noul;
        final nb = b.answer<JevNoulAnswer>('deletes').noul;
        print(
          'p(blue) llama.cpp ${pa.toStringAsFixed(4)} vs ollama ${pb.toStringAsFixed(4)} · noul ${na.toStringAsFixed(3)} vs ${nb.toStringAsFixed(3)}',
        );
        expect(pa, closeTo(pb, 0.05));
        expect(na, closeTo(nb, 0.1));
      }
    });
  });
}
