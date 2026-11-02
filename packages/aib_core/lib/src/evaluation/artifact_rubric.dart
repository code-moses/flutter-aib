import '../common/json.dart';
import '../ports/envelope.dart';
import '../ports/environment.dart';
import '../task/task.dart';
import '../trace/trace.dart';
import 'episode_evidence.dart';
import 'evaluator.dart';
import 'judge_provenance.dart';

/// Versioned rubric for LLM-as-judge evaluation (spec §5.2 oracle 3):
/// closed yes/no questions with weights — narrow rubrics keep the judge
/// reliable (risk table §12).
///
/// ```yaml
/// rubric: dashboard_v1
/// criteria:
///   - id: all_open_tasks
///     question: Does the surface list all 7 open tasks?
///     weight: 2
///   - id: grouped_by_due
///     question: Are the tasks grouped by due date?
/// ```
final class RubricSpec {
  const RubricSpec({required this.name, required this.criteria, this.scope});

  final String name;
  final List<RubricCriterion> criteria;

  /// What the rubric judges and what it does not, said once for all its
  /// criteria (`scope:` in the YAML). Shown to the judge and to the person
  /// labelling, so both answer the same question.
  final String? scope;

  factory RubricSpec.fromJson(JsonMap json) => RubricSpec(
    name: json['rubric'] as String? ?? 'unnamed',
    criteria: [for (final raw in json['criteria'] as List? ?? const []) RubricCriterion.fromJson(asJsonMap(raw))],
    scope: switch (json['scope']) {
      final String text when text.trim().isNotEmpty => text.trim(),
      _ => null,
    },
  );

  JsonMap toJson() => {
    'rubric': name,
    if (scope != null) 'scope': scope,
    'criteria': [for (final c in criteria) c.toJson()],
  };
}

final class RubricCriterion {
  const RubricCriterion({required this.id, required this.question, this.weight = 1.0});

  final String id;
  final String question;
  final double weight;

  factory RubricCriterion.fromJson(JsonMap json) =>
      RubricCriterion(id: json['id'] as String, question: json['question'] as String, weight: (json['weight'] as num?)?.toDouble() ?? 1.0);

  JsonMap toJson() => {'id': id, 'question': question, 'weight': weight};
}

/// One judge consultation: artifact + task + rubric -> yes/no per criterion.
final class JudgeRequest {
  const JudgeRequest({required this.taskInstruction, required this.artifact, required this.rubric, this.evidence = const {}});

  final String taskInstruction;
  final JsonMap artifact;
  final RubricSpec rubric;

  /// What the episode actually did, for a rubric that asks whether the
  /// artifact's claims are true. Empty unless the criterion asks for it: a
  /// judge shown the record would otherwise mark a surface against the app's
  /// data, not the rubric.
  final JsonMap evidence;
}

final class JudgeAnswer {
  const JudgeAnswer({required this.answers, this.rationale, this.tokensPrompt = 0, this.tokensCompletion = 0, this.latencyMs = 0});

  /// criterion id -> passed.
  final Map<String, bool> answers;
  final String? rationale;

  /// What this consultation cost. Zero from a judge that does not report it.
  final int tokensPrompt;
  final int tokensCompletion;
  final int latencyMs;
}

/// Judge port (P7): the LLM-backed implementation lives in aib_agents —
/// the core stays free of LLM dependencies. Deterministic judges are used
/// for framework validation (§10).
abstract interface class ArtifactJudge {
  /// Identifier for the report (e.g. `anthropic/claude-sonnet-4-6`); the
  /// judge model is pinned per run (spec §5.1 `judgeModel: pinned`).
  String get judgeId;

  Future<JudgeAnswer> judge(JudgeRequest request);
}

/// Oracle 3 (spec §5.2): LLM-as-judge with versioned rubric, pinned judge
/// model, temperature 0 and k repetitions with per-criterion majority vote.
///
/// The artifact is extracted from the trace (last act-envelope with the
/// configured key, default `genui.render`) — so rubric evaluation is a pure
/// trace pass like every other oracle (P6).
final class ArtifactRubricEvaluator implements CriterionEvaluator {
  ArtifactRubricEvaluator({this.judge, this.repetitions = 3});

  final ArtifactJudge? judge;

  /// k judge calls, majority per criterion (spec §5.2: k=3).
  final int repetitions;

  @override
  String get type => CriterionTypes.artifactRubric;

  @override
  Future<CriterionOutcome> evaluate(EvaluationContext context, SuccessCriterion criterion) async {
    final rubricJson = criterion.config['rubricSpec'];
    if (rubricJson == null) {
      return const CriterionOutcome(
        score: 0,
        detail:
            'artifactRubric without rubricSpec '
            '(is the rubric file referenced by the suite present?)',
      );
    }
    final rubric = RubricSpec.fromJson(asJsonMap(rubricJson));
    if (rubric.criteria.isEmpty) {
      return CriterionOutcome(score: 0, detail: 'rubric "${rubric.name}" has no criteria');
    }

    // A faithfulness rubric compares the claim with the record; every other
    // rubric judges the artifact alone, and seeing the record would change
    // what it marks.
    final evidence = criterion.config['evidence'] == true ? episodeEvidence(context.trace) : const <String, Object?>{};
    final artifactKeys = artifactKeysOf(criterion.config);
    final artifactState = artifactStateOf(criterion.config);
    final artifact = artifactState != null
        ? stateArtifact(context.finalState, artifactState)
        : extractArtifact(context.trace, artifactKeys: artifactKeys);
    if (artifact == null) {
      // Name the keys — otherwise this reads as "the agent said nothing" when
      // the real cause is a termination key the criterion does not look at.
      // And say when the only candidate was written by the agent's loop: that
      // is the model saying nothing, not the episode lacking the key.
      final byHarness = artifactState == null && lastIsHarnessAuthored(context.trace, artifactKeys: artifactKeys);
      //
      // A criterion that judges a *claim* opts out here instead of scoring 0:
      // an episode that ran out of budget made no claim, and marking silence
      // as unfaithful punishes it twice for one failure. A criterion that
      // judges the *answer* keeps scoring 0 — the task asked for one.
      return criterion.config['skipWhenNoArtifact'] == true
          ? CriterionOutcome.notApplicable(
              detail: byHarness
                  ? 'nothing to judge: the ${artifactKeys.join(" or ")} was written by the agent\'s loop, not by its model'
                  : 'nothing to judge: the episode produced no '
                        '${artifactState ?? artifactKeys.join(" or ")}',
            )
          : CriterionOutcome(
              score: 0,
              detail: artifactState != null
                  ? 'final state has no rows for "$artifactState"'
                  : byHarness
                  ? 'the ${artifactKeys.join(" or ")} was written by the agent\'s loop, not by its model'
                  : 'no artifact found in trace for ${artifactKeys.join(" or ")}',
            );
    }

    final activeJudge = judge;
    if (activeJudge == null) {
      return const CriterionOutcome(
        score: 0,
        detail:
            'artifactRubric requires a judge — '
            'evaluate with a judge configured (aib evaluate --judge …)',
      );
    }

    // §5.1 `judgeModel: pinned` — enforced, not just documented.
    final pinned = JudgeProvenance.pinnedModelOf(criterion);
    if (pinned != null && !JudgeProvenance.judgeMatchesPin(activeJudge.judgeId, pinned)) {
      throw JudgePinMismatch(expected: pinned, actual: activeJudge.judgeId);
    }

    // A judge asked about `{}` tends to answer yes. Silence satisfies no
    // rubric.
    if (!hasContent(artifact)) {
      return const CriterionOutcome(score: 0, detail: 'empty artifact: nothing was said to judge');
    }

    // k repetitions, per-criterion majority (ties count as failed).
    final votes = <String, int>{};
    final rationales = <String>[];
    final answers = <JsonMap>[];
    var judgePrompt = 0;
    var judgeCompletion = 0;
    var judgeLatency = 0;
    for (var i = 0; i < repetitions; i++) {
      final answer = await activeJudge.judge(
        JudgeRequest(taskInstruction: context.task.instruction, artifact: artifact, rubric: rubric, evidence: evidence),
      );
      for (final criterion in rubric.criteria) {
        if (answer.answers[criterion.id] ?? false) {
          votes.update(criterion.id, (v) => v + 1, ifAbsent: () => 1);
        }
      }
      rationales.add(answer.rationale ?? '');
      answers.add({for (final c in rubric.criteria) c.id: answer.answers[c.id] ?? false});
      judgePrompt += answer.tokensPrompt;
      judgeCompletion += answer.tokensCompletion;
      judgeLatency += answer.latencyMs;
    }

    var achieved = 0.0;
    var total = 0.0;
    final perCriterion = <String>[];
    for (final rubricCriterion in rubric.criteria) {
      final passed = (votes[rubricCriterion.id] ?? 0) * 2 > repetitions;
      achieved += passed ? rubricCriterion.weight : 0;
      total += rubricCriterion.weight;
      perCriterion.add(
        '${rubricCriterion.id}: '
        '${votes[rubricCriterion.id] ?? 0}/$repetitions'
        '${passed ? ' ✓' : ' ✗'}',
      );
    }
    return CriterionOutcome(
      score: total == 0 ? 0 : achieved / total,
      detail:
          'rubric ${rubric.name}, judge ${activeJudge.judgeId}, '
          'k=$repetitions: ${perCriterion.join(', ')}',
      // Structured evidence for the calibration pass (P5): how load-bearing
      // the majority vote was is only visible in the raw vote counts.
      data: {
        'rubric': rubric.name,
        'judgeId': activeJudge.judgeId,
        'k': repetitions,
        'votes': {for (final c in rubric.criteria) c.id: votes[c.id] ?? 0},
        // Each consultation's answers and reason, in order, so a person
        // reviewing a disagreement can see why the judge said no.
        'answers': answers,
        if (rationales.any((r) => r.isNotEmpty)) 'rationales': rationales,
        // What this verdict cost to reach.
        if (judgePrompt + judgeCompletion > 0) ...{
          'judgeCalls': repetitions,
          'judgeTokensPrompt': judgePrompt,
          'judgeTokensCompletion': judgeCompletion,
          'judgeLatencyMs': judgeLatency,
        },
      },
    );
  }

  /// Whether any leaf of [node] carries something other than blank text.
  static bool hasContent(Object? node) => switch (node) {
    Map() => node.values.any(hasContent),
    List() => node.any(hasContent),
    String() => node.trim().isNotEmpty,
    null => false,
    _ => true,
  };

  /// Last envelope carrying any of [artifactKeys] that did not fail; its
  /// `surface` payload field (or the whole payload) is the artifact under
  /// judgement.
  ///
  /// A `genui.render` payload is `{messages: [...]}` (ADR 0012), so the judge
  /// reads the A2UI batch the app renders.
  ///
  /// A missing status is not a failed one: `meta.*` envelopes are answered by
  /// the engine and carry no result, and `meta.done` is the artifact whenever
  /// what is judged is what the agent *said*.
  ///
  /// Several keys because a refusal task ends in `meta.abort` and a normal one
  /// in `meta.done`.
  ///
  /// An envelope the agent's loop wrote itself
  /// ([AgentDecision.isHarnessAuthored]) is never an artifact. When it is the
  /// last candidate, there is no artifact.
  static JsonMap? extractArtifact(EpisodeTrace trace, {required List<String> artifactKeys}) {
    JsonMap? artifact;
    for (final exchange in trace.exchanges()) {
      if (artifactKeys.contains(exchange.key) && (exchange.status ?? 'ok') == 'ok') {
        if (isHarnessAuthored(exchange)) {
          artifact = null;
          continue;
        }
        final payload = asJsonMap(exchange.envelope.data['payload']);
        artifact = payload['surface'] is Map ? asJsonMap(payload['surface']) : payload;
      }
    }
    return artifact;
  }

  /// Whether the last envelope carrying any of [artifactKeys] was written by
  /// the agent's loop rather than its model.
  static bool lastIsHarnessAuthored(EpisodeTrace trace, {required List<String> artifactKeys}) {
    final last = trace.exchanges().where((e) => artifactKeys.contains(e.key) && (e.status ?? 'ok') == 'ok').lastOrNull;
    return last != null && isHarnessAuthored(last);
  }

  static bool isHarnessAuthored(Exchange exchange) => switch (exchange.envelope.data['decision']) {
    final Map decision => AgentDecision.fromJson(asJsonMap(decision)).isHarnessAuthored,
    _ => false,
  };

  /// The rows a final-state query selected, as `{query, items}`; null when it
  /// selected none or failed. For an artifact the environment shows whoever
  /// produced it — a chart an intent rendered itself has no envelope.
  static JsonMap? stateArtifact(FinalStateSnapshot? finalState, String query) {
    final result = finalState?.resultFor(query);
    if (result == null || result.error != null || result.count == 0) return null;
    return {'query': query, 'items': result.items};
  }

  /// `artifactState` as written in the suite; null when absent or blank.
  static String? artifactStateOf(JsonMap config) => switch (config['artifactState']) {
    final String query when query.trim().isNotEmpty => query.trim(),
    _ => null,
  };

  /// `artifactKey` as written in the suite: one key or a list of them. Empty
  /// when absent — the loader refuses that, since which envelope carries an
  /// artifact is the environment's vocabulary, not the core's.
  static List<String> artifactKeysOf(JsonMap config) => switch (config['artifactKey']) {
    final String single when single.isNotEmpty => [single],
    final List keys when keys.isNotEmpty => [for (final key in keys) '$key'],
    _ => const [],
  };
}
