/// Doubles for code that decides with a [JevClient]: a scripted client, and a
/// scripted logit source that runs the real template and scoring.
library;

import 'aib_jev.dart';

/// Scripted [JevClient]: answers every `choice` with [probabilities] (option
/// id → p), every `noul` with [noul], and records each request. [error], when
/// set, is thrown instead — the router's fallback path.
final class FakeJevClient implements JevClient {
  FakeJevClient({
    this.model = 'fake-jev',
    this.probabilities = const {},
    this.noul = 0.5,
    this.noulFor,
    this.score = 0,
    this.error,
    this.latencyMs = 0,
  });

  @override
  final String model;
  final Map<String, double> probabilities;
  final double noul;

  /// Per-question truth, from the noul's instructions; [noul] when null.
  /// Selection and guard tests need different answers for different
  /// candidates in one request.
  final double Function(String instructions)? noulFor;

  /// Reported as every response's latency.
  final int latencyMs;
  final double score;
  final Exception? error;

  final List<JevRequest> requests = [];

  @override
  Future<JevResponse> decide(JevRequest request, {CancellationToken? cancellation}) async {
    cancellation?.throwIfCancelled();
    requests.add(request);
    if (error case final error?) throw error;
    return JevResponse(
      model: model,
      latencyMs: latencyMs,
      usage: JevUsage(inputTokens: _stateLength(request.state) ~/ 4),
      answers: {
        for (final MapEntry(:key, :value) in request.questions.entries)
          key: switch (value) {
            JevChoice(:final criteria) => () {
              final p = {for (final option in criteria.keys) option: probabilities[option] ?? 0.0};
              final best = p.entries.reduce((a, b) => b.value > a.value ? b : a);
              return JevChoiceAnswer(choice: best.key, confidence: best.value, probabilities: p);
            }(),
            JevScore(:final levels) => JevScoreAnswer(
              score: score,
              confidence: 1,
              probabilities: const {},
              legend: {for (final (i, l) in levels.indexed) i: l},
            ),
            JevNoul(:final instructions) => JevNoulAnswer(noul: noulFor?.call(instructions) ?? noul),
          },
      },
    );
  }
}

int _stateLength(JevState state) => switch (state) {
  JevText(:final text) => text.length,
  JevJson(:final value) => '$value'.length,
  JevChat(:final messages) => messages.fold(0, (n, m) => n + m.text.length),
};

/// A [JevLogits] whose logits come from [logitsFor], recording every prompt.
/// Wrap it in a [LogitJevClient] to test the real template and scoring end
/// to end without a model.
final class FakeJevLogits implements JevLogits {
  FakeJevLogits(this.logitsFor, {this.model = 'fake-logits', this.maxLabels, this.promptTokens = 10, this.renderer});

  /// Logits for the labels of [prompt], in label order.
  final List<double> Function(JevScoringPrompt prompt) logitsFor;

  @override
  final String model;

  @override
  final int? maxLabels;

  final int promptTokens;

  /// When set, every prompt is also rendered, into [rendered].
  final JevPromptRenderer? renderer;

  final List<JevScoringPrompt> prompts = [];
  final List<String> rendered = [];

  @override
  String get backend => 'fake';

  @override
  Future<JevLabelLogits> labelLogits(JevScoringPrompt prompt, {CancellationToken? cancellation}) async {
    cancellation?.throwIfCancelled();
    prompts.add(prompt);
    if (renderer case final render?) rendered.add(prompt.render(render));
    return JevLabelLogits(logits: logitsFor(prompt), promptTokens: promptTokens, model: model);
  }
}
