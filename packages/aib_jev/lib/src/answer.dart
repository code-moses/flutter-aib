import 'package:aib_core/transport.dart';

import 'request.dart' show JevRef;

/// One typed answer. Sealed, so a caller that does not know which question it
/// asked can switch over the three shapes exhaustively.
///
/// Every answer keeps the server's [raw] map: the advanced-metrics fields
/// differ between backends and versions, and a client that dropped what it
/// did not model would make a newer server unusable until it was updated.
sealed class JevAnswer {
  const JevAnswer({required this.raw});

  final JsonMap raw;

  /// `choice`, `score` or `noul`.
  String get type;

  /// Probability of the answer given, where the shape has one.
  double? get confidence;

  /// What the model that answered was, when a backend names it per answer
  /// (the hosted API does; simple-jev names it once for the response).
  String? get model => raw['model'] as String?;

  /// Whether the backend calibrated the probabilities. Absent without
  /// advanced metrics; `false` on every open implementation so far, which is
  /// why these numbers are preferences and not probabilities of correctness.
  bool? get calibrated => raw['calibrated'] as bool?;

  /// The backend's name for how it scored (`direct_label_logits`, …).
  String? get scoring => raw['scoring'] as String?;

  /// Dispatches on `type`, falling back to the field the answer carries —
  /// the hosted API has been known to omit `type`.
  static JevAnswer fromJson(JsonMap json) => switch (json['type']) {
    'choice' => JevChoiceAnswer.fromJson(json),
    'score' => JevScoreAnswer.fromJson(json),
    'noul' => JevNoulAnswer.fromJson(json),
    _ when json.containsKey('noul') => JevNoulAnswer.fromJson(json),
    _ when json.containsKey('score') => JevScoreAnswer.fromJson(json),
    _ => JevChoiceAnswer.fromJson(json),
  };
}

/// The answer to a [JevChoice].
final class JevChoiceAnswer extends JevAnswer {
  const JevChoiceAnswer({
    required this.choice,
    required this.confidence,
    required this.probabilities,
    this.margin,
    this.ties = const [],
    this.logits = const {},
    super.raw = const {},
  });

  @override
  String get type => 'choice';

  /// The candidate with the greatest logit.
  final String choice;

  @override
  final double confidence;

  /// Candidate id → probability, normalised over the candidates offered.
  final Map<String, double> probabilities;

  /// Gap between the top two probabilities (advanced metrics only). A
  /// thin margin is the signal to escalate rather than to act.
  final double? margin;

  /// Every candidate that tied for the top logit (advanced metrics only).
  final List<String> ties;

  /// Raw logits per candidate, when they were requested and the server
  /// exposes them.
  final Map<String, double> logits;

  double probabilityOf(String option) => probabilities[option] ?? 0;

  /// Candidates by probability, highest first — for reranking, where the
  /// order matters more than the winner.
  List<MapEntry<String, double>> get ranked => probabilities.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

  /// The [k] best candidates.
  List<String> top(int k) => [for (final e in ranked.take(k)) e.key];

  factory JevChoiceAnswer.fromJson(JsonMap json) {
    final probabilities = _numbers(json['probabilities']);
    final choice =
        json['choice'] as String? ??
        (probabilities.isEmpty ? '' : (probabilities.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key);
    return JevChoiceAnswer(
      choice: choice,
      confidence: (json['confidence'] as num?)?.toDouble() ?? probabilities[choice] ?? 0,
      probabilities: probabilities,
      margin: (json['margin'] as num?)?.toDouble(),
      ties: [for (final t in json['ties'] as List? ?? const []) '$t'],
      logits: _numbers(json['logits']),
      raw: json,
    );
  }
}

/// The answer to a [JevScore]: an expected position on the rubric.
final class JevScoreAnswer extends JevAnswer {
  const JevScoreAnswer({
    required this.score,
    required this.confidence,
    required this.probabilities,
    required this.legend,
    this.variance,
    super.raw = const {},
  });

  @override
  String get type => 'score';

  /// Expected zero-based level index, `sum(p[i] * i)`. Fractional: 1.035
  /// means "just past the second level".
  final double score;

  /// Probability of the most likely level — not an interval for [score].
  @override
  final double confidence;

  /// Level index → probability.
  final Map<int, double> probabilities;

  /// Level index → the rubric text it stands for, as the server echoes it.
  final Map<int, String> legend;

  /// Spread over the levels (advanced metrics only). High variance with a
  /// mid score means "the model is torn", not "the middle level".
  final double? variance;

  /// The nearest level's index.
  int get level => score.round();

  /// The nearest level's text, empty when no legend came back.
  String get levelName => legend[level] ?? '';

  /// [score] mapped onto 0–1, so rubrics of different lengths compare.
  double get normalized {
    final levels = legend.isNotEmpty ? legend.length : probabilities.length;
    return levels < 2 ? 0 : score / (levels - 1);
  }

  factory JevScoreAnswer.fromJson(JsonMap json, {List<String>? levels}) {
    final probabilities = <int, double>{};
    for (final entry in _numbers(json['probabilities']).entries) {
      final index = int.tryParse(entry.key);
      if (index != null) probabilities[index] = entry.value;
    }
    final legend = <int, String>{};
    for (final entry in asJsonMap(json['legend']).entries) {
      final index = int.tryParse(entry.key);
      if (index != null) legend[index] = '${entry.value}';
    }
    return JevScoreAnswer(
      score: (json['score'] as num?)?.toDouble() ?? 0,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      probabilities: probabilities,
      // The question knows the rubric even when the server does not echo it.
      legend: legend.isNotEmpty ? legend : {for (final (i, level) in (levels ?? const []).indexed) i: level},
      variance: (json['variance'] as num?)?.toDouble(),
      raw: json,
    );
  }
}

/// The answer to a [JevNoul]: how true the statement is.
final class JevNoulAnswer extends JevAnswer {
  const JevNoulAnswer({required this.noul, this.rating, super.raw = const {}});

  @override
  String get type => 'noul';

  /// Truth on [0.01, 0.99]. A transformed expected rating, **not** a
  /// calibrated probability and not a binary softmax: compare it against a
  /// threshold chosen on your own data, never read it as "93 % sure".
  final double noul;

  /// The nine-bin rating this was derived from (advanced metrics only).
  final JevRating? rating;

  /// Noul has no separate confidence; distance from the middle is the
  /// closest honest equivalent.
  @override
  double? get confidence => null;

  /// How far from undecided, on 0–1.
  double get decisiveness => (noul - 0.5).abs() * 2;

  bool isTrue({double threshold = 0.5}) => noul >= threshold;

  factory JevNoulAnswer.fromJson(JsonMap json) => JevNoulAnswer(
    noul: (json['noul'] as num?)?.toDouble() ?? 0,
    rating: json['rating'] == null ? null : JevRating.fromJson(asJsonMap(json['rating'])),
    raw: json,
  );
}

/// The rating distribution behind a noul.
final class JevRating {
  const JevRating({this.bins = const [], this.probabilities = const [], this.expectedScore, this.variance, this.entropy, this.logits = const []});

  final List<double> bins;
  final List<double> probabilities;
  final double? expectedScore;
  final double? variance;

  /// In natural-log units. High entropy on a yes/no question is a model
  /// saying it cannot tell — worth more than the noul itself.
  final double? entropy;
  final List<double> logits;

  factory JevRating.fromJson(JsonMap json) => JevRating(
    bins: _doubles(json['bins']),
    probabilities: _doubles(json['probabilities']),
    expectedScore: (json['expected_score'] as num?)?.toDouble(),
    variance: (json['variance'] as num?)?.toDouble(),
    entropy: (json['entropy'] as num?)?.toDouble(),
    logits: _doubles(json['logits']),
  );
}

/// What the call cost. A decision model emits no tokens, so
/// [outputTokens] is 0 on every backend that reads logits.
final class JevUsage {
  const JevUsage({this.inputTokens = 0, this.outputTokens = 0});

  final int inputTokens;
  final int outputTokens;

  int get totalTokens => inputTokens + outputTokens;

  factory JevUsage.fromJson(JsonMap json) =>
      JevUsage(inputTokens: (json['input_tokens'] as num?)?.toInt() ?? 0, outputTokens: (json['output_tokens'] as num?)?.toInt() ?? 0);
}

/// Provenance the backend reports about itself: which engine, which weights,
/// which prompt template, whether it was calibrated. The template version
/// decides what the probabilities mean.
final class JevMetadata {
  const JevMetadata({this.raw = const {}});

  final JsonMap raw;

  String? get backend => raw['backend'] as String?;
  String? get modelRevision => raw['model_revision'] as String?;
  String? get templateVersion => raw['template_version'] as String?;
  String? get calibration => raw['calibration'] as String?;

  bool get isEmpty => raw.isEmpty;

  JsonMap toJson() => raw;
}

/// One reply: the answers, what they cost, and what produced them.
final class JevResponse {
  const JevResponse({
    required this.answers,
    required this.model,
    this.usage = const JevUsage(),
    this.metadata = const JevMetadata(),
    this.latencyMs = 0,
    this.raw = const {},
  });

  /// Question id → answer.
  final Map<String, JevAnswer> answers;

  /// The model that answered, as the backend reports it.
  final String model;

  final JevUsage usage;
  final JevMetadata metadata;

  /// Wall clock of the call as the client saw it, network included.
  final int latencyMs;

  /// The whole reply, for fields no version of this client models.
  final JsonMap raw;

  /// The answer to [id], typed. Throws when it is missing or is another
  /// shape than asked for: a router that silently read a `noul` as a choice
  /// would produce a decision nobody asked for.
  A answer<A extends JevAnswer>(String id) {
    final answer = answers[id];
    if (answer == null) {
      throw JevAnswerMissing(id, answers.keys.toList());
    }
    if (answer is! A) {
      throw JevAnswerMismatch(id, expected: '$A', actual: answer.type);
    }
    return answer;
  }

  /// The answer to a question held by handle, typed by that handle.
  A get<A extends JevAnswer>(JevRef<A> ref) => answer<A>(ref.id);
}

final class JevAnswerMissing implements Exception {
  const JevAnswerMissing(this.id, this.available);

  final String id;
  final List<String> available;

  @override
  String toString() => 'jev returned no answer for "$id" (got: ${available.join(', ')})';
}

final class JevAnswerMismatch implements Exception {
  const JevAnswerMismatch(this.id, {required this.expected, required this.actual});

  final String id;
  final String expected;
  final String actual;

  @override
  String toString() => 'jev answered "$id" with a $actual, which is not a $expected';
}

Map<String, double> _numbers(Object? raw) => {
  for (final entry in asJsonMap(raw).entries)
    if (entry.value is num) entry.key: (entry.value! as num).toDouble(),
};

List<double> _doubles(Object? raw) => [
  for (final value in raw as List? ?? const [])
    if (value is num) value.toDouble(),
];
