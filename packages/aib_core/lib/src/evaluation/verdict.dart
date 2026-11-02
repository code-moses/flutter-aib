import '../common/json.dart';

enum VerdictType {
  success,
  partial,
  failure,

  /// Framework fault — excluded from agent scoring, counted separately
  /// (`infrastructure_error` in reports, spec §5.2).
  error,
}

final class Verdict {
  const Verdict({required this.type, required this.score, this.label, this.reason, this.details = const {}});

  final VerdictType type;

  /// success = 1.0, partial = credit ∈ (0,1), failure = 0, error = 0.
  final double score;
  final String? label;
  final String? reason;
  final JsonMap details;

  /// Every details entry a criterion of [type] wrote — one per criterion, see
  /// `EpisodeEvaluator.detailsKey`.
  Iterable<JsonMap> detailsOfType(String type) => [
    for (final entry in details.entries)
      if ((entry.key == type || entry.key.startsWith('$type:') || entry.key.startsWith('$type#')) && entry.value is Map) asJsonMap(entry.value),
  ];

  factory Verdict.success({String? label}) => Verdict(type: .success, score: 1, label: label);

  factory Verdict.partial(double credit, {String? label}) => Verdict(type: .partial, score: credit, label: label);

  factory Verdict.failure(String reason, {JsonMap details = const {}}) => Verdict(type: .failure, score: 0, reason: reason, details: details);

  factory Verdict.frameworkError(String reason) => Verdict(type: .error, score: 0, reason: reason);

  JsonMap toJson() => {
    'type': type.name,
    'score': score,
    if (label != null) 'label': label,
    if (reason != null) 'reason': reason,
    if (details.isNotEmpty) 'details': details,
  };

  factory Verdict.fromJson(JsonMap json) => Verdict(
    type: VerdictType.values.byName(json['type'] as String),
    score: (json['score'] as num).toDouble(),
    label: json['label'] as String?,
    reason: json['reason'] as String?,
    details: asJsonMap(json['details']),
  );
}
