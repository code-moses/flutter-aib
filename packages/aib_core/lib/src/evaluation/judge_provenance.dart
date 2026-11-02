import '../common/json.dart';
import '../task/task.dart';
import 'artifact_rubric.dart';
import 'verdict.dart';

/// Everything needed to say *who* produced the rubric scores of a run (spec
/// §5.1 `judgeModel: pinned`, §5.3).
///
/// Using one model as agent backbone and as evaluator threatens validity
/// (SPA-Bench, ICLR 2025), so the judge is recorded next to the results and the
/// reports print agent and judge models side by side.
final class JudgeProvenance {
  const JudgeProvenance({
    required this.judgeId,
    required this.k,
    this.temperature = 0,
    this.pinnedModel,
    this.rubrics = const {},
    this.evaluatedAt,
    this.spend,
  });

  /// Self-reported identity of the judge implementation, e.g.
  /// `claude-sonnet-4-6 (judge_v1)`.
  final String judgeId;

  /// Judge repetitions per artifact; the per-criterion majority is taken
  /// over these (spec §5.2: k=3).
  final int k;

  /// Sampling temperature of the judge. With k>1 at 0 the votes are near
  /// identical (ADR 0008): the majority then costs k calls and buys nothing.
  final double temperature;

  /// Model the *suite* pins for its rubric criteria, if any.
  final String? pinnedModel;

  /// rubric name -> content hash, so a silently edited rubric is detectable.
  final Map<String, String> rubrics;

  final DateTime? evaluatedAt;

  /// What scoring this run cost, or null where no judge reported it.
  final JudgeSpend? spend;

  JsonMap toJson() => {
    'judgeId': judgeId,
    'k': k,
    // Omitted at 0, so provenance without the field compares equal.
    if (temperature != 0) 'temperature': temperature,
    if (pinnedModel != null) 'pinnedModel': pinnedModel,
    if (rubrics.isNotEmpty) 'rubrics': rubrics,
    'evaluatedAt': ?evaluatedAt?.toIso8601String(),
    'spend': ?spend?.toJson(),
  };

  factory JudgeProvenance.fromJson(JsonMap json) => JudgeProvenance(
    judgeId: json['judgeId'] as String? ?? 'unknown',
    k: (json['k'] as num?)?.toInt() ?? 0,
    temperature: (json['temperature'] as num?)?.toDouble() ?? 0,
    pinnedModel: json['pinnedModel'] as String?,
    rubrics: {for (final entry in asJsonMap(json['rubrics']).entries) entry.key: '${entry.value}'},
    evaluatedAt: json['evaluatedAt'] == null ? null : DateTime.tryParse(json['evaluatedAt'] as String),
    spend: json['spend'] == null ? null : JudgeSpend.fromJson(asJsonMap(json['spend'])),
  );

  /// Collects the provenance for [suite]: the pinned model and the rubrics
  /// actually referenced by its `artifactRubric` criteria.
  factory JudgeProvenance.forSuite(TaskSuite suite, {required String judgeId, required int k, double temperature = 0, DateTime? evaluatedAt}) {
    final rubrics = <String, String>{};
    final pins = <String>{};
    for (final criterion in suite.tasks.expand((t) => t.successCriteria).where((c) => c.type == CriterionTypes.artifactRubric)) {
      if (pinnedModelOf(criterion) case final pin?) pins.add(pin);
      final spec = criterion.config['rubricSpec'];
      if (spec != null) {
        final rubric = RubricSpec.fromJson(asJsonMap(spec));
        rubrics[rubric.name] = jsonFingerprint(rubric.toJson());
      }
    }
    return JudgeProvenance(
      judgeId: judgeId,
      k: k,
      temperature: temperature,
      // Every distinct pin, not the first one found: a suite whose rubrics
      // pin different judges recorded only one of them.
      pinnedModel: pins.isEmpty ? null : (pins.toList()..sort()).join(', '),
      rubrics: rubrics,
      evaluatedAt: evaluatedAt ?? DateTime.now(),
    );
  }

  /// Whether a judge identifying as [judgeId] is the model [pinned] names. The
  /// id is `<model> (<prompt version>)`; `gpt-4o-mini` must not match a pinned
  /// `gpt-4o`.
  static bool judgeMatchesPin(String judgeId, String pinned) => judgeId == pinned || judgeId.startsWith('$pinned ');

  /// Judge model a criterion pins, or `null` when it accepts any judge.
  /// `pinned` is the placeholder of the spec's example suite and means "not
  /// pinned to a concrete model yet".
  static String? pinnedModelOf(SuccessCriterion criterion) {
    final value = criterion.config['judgeModel'] as String?;
    if (value == null || value.trim().isEmpty || value == 'pinned') {
      return null;
    }
    return value.trim();
  }
}

/// The configured judge is not the one the suite pins. An operator error,
/// raised instead of scoring with an unintended model (§5.1).
final class JudgePinMismatch implements Exception {
  const JudgePinMismatch({required this.expected, required this.actual});

  final String expected;
  final String actual;

  @override
  String toString() =>
      'Judge mismatch: the suite pins "$expected", but the configured judge '
      'reports "$actual".\n'
      'Use the pinned model, or change judgeModel in the suite — which '
      'changes the suite hash and is therefore recorded in the run manifest.';
}

/// Model calls, tokens and wall clock spent judging one run.
final class JudgeSpend {
  const JudgeSpend({this.calls = 0, this.tokensPrompt = 0, this.tokensCompletion = 0, this.latencyMs = 0});

  final int calls;
  final int tokensPrompt;
  final int tokensCompletion;
  final int latencyMs;

  bool get isEmpty => calls == 0 && tokensPrompt == 0 && tokensCompletion == 0;

  JudgeSpend plus(JudgeSpend other) => JudgeSpend(
    calls: calls + other.calls,
    tokensPrompt: tokensPrompt + other.tokensPrompt,
    tokensCompletion: tokensCompletion + other.tokensCompletion,
    latencyMs: latencyMs + other.latencyMs,
  );

  /// Sums what every rubric criterion recorded in one episode's verdict.
  factory JudgeSpend.fromVerdict(Verdict verdict) {
    var spend = const JudgeSpend();
    for (final rubric in verdict.detailsOfType(CriterionTypes.artifactRubric)) {
      spend = spend.plus(
        JudgeSpend(
          calls: (rubric['judgeCalls'] as num?)?.toInt() ?? 0,
          tokensPrompt: (rubric['judgeTokensPrompt'] as num?)?.toInt() ?? 0,
          tokensCompletion: (rubric['judgeTokensCompletion'] as num?)?.toInt() ?? 0,
          latencyMs: (rubric['judgeLatencyMs'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    return spend;
  }

  JsonMap toJson() => {'calls': calls, 'tokensPrompt': tokensPrompt, 'tokensCompletion': tokensCompletion, 'latencyMs': latencyMs};

  factory JudgeSpend.fromJson(JsonMap json) => JudgeSpend(
    calls: (json['calls'] as num?)?.toInt() ?? 0,
    tokensPrompt: (json['tokensPrompt'] as num?)?.toInt() ?? 0,
    tokensCompletion: (json['tokensCompletion'] as num?)?.toInt() ?? 0,
    latencyMs: (json['latencyMs'] as num?)?.toInt() ?? 0,
  );
}
