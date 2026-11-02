import 'package:aib_core/transport.dart';

import 'answer.dart';
import 'chat_format.dart';
import 'client.dart';
import 'request.dart';
import 'scoring.dart';
import 'template.dart';

/// The one thing Dart cannot do itself: run the model and read the next-token
/// logits of the answer labels. Everything else is Dart, in [LogitJevClient],
/// so one small class per runtime serves every question shape.
abstract interface class JevLogits {
  /// The model the source runs, as the runtime names it.
  String get model;

  /// Recorded as `metadata.backend`, so a number says where it came from.
  String get backend;

  /// The most labels one call can read, or null for no limit. Ollama reports
  /// only the top 20 tokens: a 30-way choice there cannot be read, and the
  /// client refuses it rather than guessing the missing tail.
  int? get maxLabels;

  /// Logits (or log-probabilities — any per-call constant shift is fine) of
  /// each of [JevScoringPrompt.labels], in that order, at the position after
  /// the prompt.
  Future<JevLabelLogits> labelLogits(JevScoringPrompt prompt, {CancellationToken? cancellation});
}

/// One scoring position, as the template planned it.
final class JevScoringPrompt {
  const JevScoringPrompt({required this.turns, required this.answerPrefix, required this.labels});

  /// The branch's chat turns, before any chat template.
  final List<JevTurn> turns;

  /// Appended after the rendered open assistant turn.
  final String answerPrefix;

  /// The output labels whose logits are wanted.
  final List<String> labels;

  /// The raw prompt under [renderer].
  String render(JevPromptRenderer renderer) => renderer(turns, answerPrefix);
}

/// What a [JevLogits] read.
final class JevLabelLogits {
  const JevLabelLogits({required this.logits, this.promptTokens = 0, this.missing = const [], this.model, this.raw = const {}});

  /// One per label, in label order.
  final List<double> logits;

  /// Prompt tokens the runtime evaluated for this call. With a prefix cache
  /// that is the new suffix only, which is the honest cost of the call.
  final int promptTokens;

  /// Labels the runtime did not report (outside Ollama's top 20), whose
  /// logits are a floor below the lowest reported one rather than a reading.
  /// Recorded on the answer as `missing_labels`, so a decision that rests on
  /// floors is visible as one.
  final List<String> missing;

  /// The model that answered, when the runtime echoes it.
  final String? model;

  /// The runtime's own reply, for the fields not modelled here.
  final JsonMap raw;
}

/// A [JevClient] that plans and scores in Dart and reads logits from a
/// [JevLogits]: a local decision model without a Python server.
///
/// The answers are the ones simple-jev would give for the same logits
/// (golden-tested). The logits themselves can differ, so `metadata.backend`
/// records where they came from.
///
/// Branches run one after another by default: a runtime with a prefix cache
/// evaluates the shared prefix once only when branches arrive in order on the
/// same slot. [parallel] trades that for wall clock on a server with several
/// slots.
final class LogitJevClient implements JevClient, JevWarmUp, JevServerInfo {
  LogitJevClient({required this.logits, this.template = .v1NoulDecimal, this.parallel = false});

  final JevLogits logits;

  /// [JevTemplate.v1NoulDecimal] by default: under the exact v1 a noul
  /// carries no information on any model measured so far. Pass
  /// [JevTemplate.v1] to reproduce the reference, e.g. to compare against
  /// simple-jev.
  final JevTemplate template;
  final bool parallel;

  @override
  String get model => logits.model;

  @override
  Future<void> warmUp() async {
    if (logits case final JevWarmUp warmable) await warmable.warmUp();
  }

  /// The logit source's, where it has one (Ollama, llama-server); empty and
  /// null otherwise.
  @override
  Future<List<String>> models() async => switch (logits) {
    final JevServerInfo server => server.models(),
    _ => [logits.model],
  };

  @override
  Future<JsonMap?> health() async => switch (logits) {
    final JevServerInfo server => server.health(),
    _ => null,
  };

  @override
  Future<JevResponse> decide(JevRequest request, {CancellationToken? cancellation}) async {
    final watch = Stopwatch()..start();
    final plan = template.plan(request);
    if (logits.maxLabels case final max?) {
      for (final branch in plan.branches) {
        if (branch.outputLabels.length > max) {
          throw JevUnsupported(
            'question "${branch.questionId}" has ${branch.outputLabels.length} labels; ${logits.backend} reads at most $max per call. '
            'Split the candidates (JevAsk.judgeEach) or use a backend with full logits.',
          );
        }
      }
    }
    Future<JevLabelLogits> read(JevBranch branch) {
      cancellation?.throwIfCancelled();
      return logits.labelLogits(
        JevScoringPrompt(turns: plan.turnsFor(branch), answerPrefix: branch.answerPrefix, labels: branch.outputLabels),
        cancellation: cancellation,
      );
    }

    final readings = parallel ? await Future.wait(plan.branches.map(read)) : [for (final branch in plan.branches) await read(branch)];

    final answers = <String, JevAnswer>{};
    var tokens = 0;
    String? answeredBy;
    for (final (i, branch) in plan.branches.indexed) {
      final reading = readings[i];
      tokens += reading.promptTokens;
      answeredBy ??= reading.model;
      answers[branch.questionId] = scoreBranch(
        branch,
        reading.logits,
        rawLogits: request.options.rawLogits,
        extra: {if (reading.missing.isNotEmpty) 'missing_labels': reading.missing},
      );
    }
    return JevResponse(
      answers: answers,
      model: answeredBy ?? logits.model,
      usage: JevUsage(inputTokens: tokens),
      metadata: JevMetadata(raw: {'backend': logits.backend, 'template_version': template.id, 'calibration': 'not_calibrated'}),
      latencyMs: watch.elapsedMilliseconds,
    );
  }
}

/// Reads label logits out of a runtime's top-k list: `token → logprob`.
///
/// Tokens come back with their leading space (`" B"`), so a label matches a
/// token exactly or after trimming, exact first. A label that is not in the
/// list is *below* the last reported entry, not impossible: it gets the
/// lowest reported value minus [missingPenalty] and is named in `missing`.
/// When no label at all was reported, the model wanted to write something
/// else entirely, and a uniform "answer" would be invented — that throws.
JevLabelLogits readTopLogprobs(
  List<String> labels,
  List<(String token, double logprob)> top, {
  double missingPenalty = 1.0,
  int promptTokens = 0,
  String? model,
  JsonMap raw = const {},
}) {
  final values = <double?>[];
  for (final label in labels) {
    double? exact;
    double? loose;
    for (final (token, logprob) in top) {
      if (token == label) {
        if (exact == null || logprob > exact) exact = logprob;
      } else if (token.trim() == label) {
        if (loose == null || logprob > loose) loose = logprob;
      }
    }
    values.add(exact ?? loose);
  }
  final missing = [
    for (final (i, value) in values.indexed)
      if (value == null) labels[i],
  ];
  if (missing.length == labels.length) {
    throw JevLabelsUnreadable(labels: labels, seen: [for (final (token, _) in top) token]);
  }
  final floor = top.map((e) => e.$2).reduce((a, b) => a < b ? a : b) - missingPenalty;
  return JevLabelLogits(logits: [for (final value in values) value ?? floor], missing: missing, promptTokens: promptTokens, model: model, raw: raw);
}

/// None of the answer labels was among the tokens the runtime reported: the
/// model was not going to answer in the requested format at all (a wrong
/// chat template is the usual cause).
final class JevLabelsUnreadable implements Exception {
  const JevLabelsUnreadable({required this.labels, required this.seen});

  final List<String> labels;
  final List<String> seen;

  @override
  String toString() =>
      'JevLabelsUnreadable: none of ${labels.join(' ')} among the next tokens (${seen.take(8).map((t) => '"$t"').join(', ')}…) — '
      'check the chat format';
}
