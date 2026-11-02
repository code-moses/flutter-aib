import '../common/condition.dart';
import '../common/json.dart';
import '../ports/agent.dart';
import '../ports/environment.dart';
import '../task/task.dart';
import '../trace/trace.dart';
import '../metrics/metrics.dart';
import 'artifact_rubric.dart';
import 'assertions.dart';
import 'verdict.dart';

/// Everything a criterion evaluator may look at. The final state is read
/// from the trace (`final.state` event) so evaluation works offline on
/// persisted traces (P6).
final class EvaluationContext {
  EvaluationContext({required this.task, required this.trace});

  final TaskSpec task;
  final EpisodeTrace trace;

  late final FinalStateSnapshot? finalState = _readFinalState();
  late final EpisodeOutcome? outcome = _readOutcome();

  /// Essential-state timeline (empty unless the task declares milestones).
  late final List<StateProbe> probes = trace.probes();

  FinalStateSnapshot? _readFinalState() {
    final event = trace.firstOfType(TraceEventTypes.finalState);
    return event == null ? null : FinalStateSnapshot.fromJson(event.data);
  }

  EpisodeOutcome? _readOutcome() {
    final event = trace.firstOfType(TraceEventTypes.episodeEnd);
    if (event == null) return null;
    return EpisodeOutcome(reason: TerminationReason.values.byName(event.data['reason'] as String), message: event.data['message'] as String?);
  }
}

final class CriterionOutcome {
  const CriterionOutcome({required this.score, required this.detail, this.data = const {}, this.applies = true});

  /// Nothing for this criterion to judge, so it is left out of the weighted
  /// score rather than scored 0. Still recorded in the details.
  const CriterionOutcome.notApplicable({required this.detail}) : score = 0, data = const {}, applies = false;

  /// ∈ [0, 1]; 1 = fully passed.
  final double score;
  final String detail;

  final bool applies;

  /// Machine-readable evidence behind the score, merged into
  /// `Verdict.details[type]`. [detail] is for humans; downstream analyses
  /// (judge calibration, P5) must not have to parse it.
  final JsonMap data;

  bool get passed => score >= 1;
}

/// One evaluator per criterion type, plugged in via registry (P7).
abstract interface class CriterionEvaluator {
  String get type;

  /// Async because oracle 3 (artifactRubric) consults an LLM judge; the
  /// deterministic oracles complete synchronously.
  Future<CriterionOutcome> evaluate(EvaluationContext context, SuccessCriterion criterion);
}

/// Oracle 1 (spec §5.2): deterministic comparison of the FinalStateSnapshot
/// against ground truth. Fully automatic, objective.
final class FinalStateMatchEvaluator implements CriterionEvaluator {
  @override
  String get type => CriterionTypes.finalStateMatch;

  @override
  Future<CriterionOutcome> evaluate(EvaluationContext context, SuccessCriterion criterion) async {
    final snapshot = context.finalState;
    if (snapshot == null) {
      return const CriterionOutcome(score: 0, detail: 'no final state snapshot in trace');
    }
    final expectations = context.task.groundTruth.finalState;
    if (expectations.isEmpty) {
      return const CriterionOutcome(score: 0, detail: 'task defines no groundTruth.finalState');
    }
    var passedCount = 0;
    final failures = <String>[];
    for (final expectation in expectations) {
      final mismatch = expectation.mismatch(snapshot.resultFor(expectation.query));
      if (mismatch == null) {
        passedCount++;
      } else {
        failures.add('query "${expectation.query}": $mismatch');
      }
    }
    return CriterionOutcome(
      score: passedCount / expectations.length,
      detail: failures.isEmpty ? 'all ${expectations.length} expectation(s) met' : failures.join('; '),
    );
  }
}

/// Oracle 1b (spec §5.2): deterministic comparison against *essential states*
/// the episode had to pass through, the milestone timeline recorded by the
/// engine (`state.probe` events). Stays faithful when several action paths are
/// valid (LlamaTouch, UIST 2024), and scores tasks whose final state equals the
/// initial state: search, filter, navigation, read-only lookups.
///
/// Config:
///   `ordered` (default true) — milestones must be reached in declaration order;
///   gaps between them are allowed, extra actions do not hurt.
///
/// Ordering is decided on the *earliest* probe satisfying each milestone. App
/// state is usually cumulative, so asking only whether a later probe satisfies
/// the next milestone would accept any order. Two milestones satisfied by the
/// same action both count.
///
/// Scoring is `reached / declared`.
final class StateSequenceEvaluator implements CriterionEvaluator {
  @override
  String get type => CriterionTypes.stateSequence;

  @override
  Future<CriterionOutcome> evaluate(EvaluationContext context, SuccessCriterion criterion) async {
    final milestones = context.task.groundTruth.milestones;
    if (milestones.isEmpty) {
      return const CriterionOutcome(score: 0, detail: 'task defines no groundTruth.milestones');
    }
    final probes = context.probes;
    if (probes.isEmpty) {
      return const CriterionOutcome(
        score: 0,
        detail:
            'no state.probe events in trace — the run predates the '
            'milestone declaration; re-run the episode',
      );
    }
    final ordered = criterion.config['ordered'] as bool? ?? true;

    var lastAccepted = -1; // probe index of the previously counted milestone
    var reached = 0;
    final details = <String>[];
    for (final milestone in milestones) {
      final (hitIndex, lastMismatch) = _earliestHit(probes, milestone);
      if (hitIndex == null) {
        details.add(
          '${milestone.id}: never reached'
          '${lastMismatch == null ? '' : ' ($lastMismatch)'}',
        );
        continue;
      }
      final at = probes[hitIndex].seq;
      if (ordered && hitIndex < lastAccepted) {
        details.add(
          '${milestone.id}: reached after exchange $at, but out of '
          'order — an earlier milestone was only reached later',
        );
        continue;
      }
      reached++;
      lastAccepted = hitIndex;
      details.add(
        at < 0
            ? '${milestone.id}: already satisfied in the initial state — '
                  'the milestone does not discriminate'
            : '${milestone.id}: reached after exchange $at',
      );
    }

    return CriterionOutcome(
      score: reached / milestones.length,
      detail:
          '$reached/${milestones.length} milestone(s) reached'
          '${ordered ? ' (ordered)' : ''}: ${details.join('; ')}',
    );
  }

  /// Index of the earliest probe satisfying [milestone], plus the last
  /// mismatch reason for the failure message.
  static (int?, String?) _earliestHit(List<StateProbe> probes, MilestoneSpec milestone) {
    String? lastMismatch;
    for (var i = 0; i < probes.length; i++) {
      final probe = probes[i];
      if (probe.error != null) {
        lastMismatch = 'probe failed: ${probe.error}';
        continue;
      }
      final mismatch = milestone.expectation.mismatch(probe.resultFor(milestone.query));
      if (mismatch == null) return (i, null);
      lastMismatch = mismatch;
    }
    return (null, lastMismatch);
  }
}

/// Oracle 2 (spec §5.2): predicates over the event trace — the same
/// assertion kinds as `policies:` ([assertionHolds]): the built-in ones plus
/// whatever a provider registered through [assertions].
final class TraceAssertionEvaluator implements CriterionEvaluator {
  TraceAssertionEvaluator({this.assertions = const {}});

  final Map<String, AssertionPredicate> assertions;

  @override
  String get type => CriterionTypes.traceAssertion;

  @override
  Future<CriterionOutcome> evaluate(EvaluationContext context, SuccessCriterion criterion) async {
    final raw = criterion.config['assertions'] as List? ?? const [];
    if (raw.isEmpty) {
      return const CriterionOutcome(score: 0, detail: 'traceAssertion without assertions');
    }
    final metricContext = MetricContext(trace: context.trace, task: context.task, assertions: assertions);
    final failures = <String>[];
    for (final entry in raw) {
      final assertion = asJsonMap(entry);
      if (!isKnownAssertionKind(metricContext, assertion['kind'])) {
        failures.add('unknown assertion kind "${assertion['kind']}"');
      } else if (!assertionHolds(metricContext, assertion)) {
        failures.add('assertion violated: $assertion');
      }
    }
    return CriterionOutcome(score: failures.isEmpty ? 1 : 0, detail: failures.isEmpty ? 'all ${raw.length} assertion(s) hold' : failures.join('; '));
  }
}

/// Oracle 4 (spec §5.2): explicit fallback — always requires a human,
/// reported as pending.
final class ManualReviewEvaluator implements CriterionEvaluator {
  @override
  String get type => CriterionTypes.manualReview;

  @override
  Future<CriterionOutcome> evaluate(EvaluationContext context, SuccessCriterion criterion) async =>
      const CriterionOutcome(score: 0, detail: 'manual review pending');
}

/// Combines criterion outcomes into one [Verdict] per episode (§5.2):
/// weighted score over all criteria; partial-credit rules can label
/// characteristic near-misses. Verdict semantics per termination reason are
/// documented in ADR 0003.
final class EpisodeEvaluator {
  EpisodeEvaluator({Map<String, CriterionEvaluator>? evaluators}) : evaluators = evaluators ?? defaultEvaluators();

  final Map<String, CriterionEvaluator> evaluators;

  /// [judge] enables the artifactRubric oracle; without one those criteria
  /// fail with an instructive message (aib evaluate --judge …).
  /// [judgeRepetitions] is the k of the majority vote (spec §5.2: k=3).
  static Map<String, CriterionEvaluator> defaultEvaluators({
    ArtifactJudge? judge,
    int judgeRepetitions = 3,
    Map<String, AssertionPredicate> assertions = const {},
  }) => {
    for (final evaluator in [
      FinalStateMatchEvaluator(),
      StateSequenceEvaluator(),
      TraceAssertionEvaluator(assertions: assertions),
      ArtifactRubricEvaluator(judge: judge, repetitions: judgeRepetitions),
      ManualReviewEvaluator(),
    ])
      evaluator.type: evaluator,
  };

  Future<Verdict> judge(EvaluationContext context) async {
    final outcome = context.outcome;
    if (outcome == null) {
      return Verdict.frameworkError('trace has no episode.end event');
    }
    if (outcome.reason == .frameworkFault) {
      return Verdict.frameworkError(outcome.message ?? 'framework fault');
    }
    // ADR 0003: an abort is declared defeat and is not scored — unless the
    // task is one where refusing is the correct answer.
    if (outcome.reason == .abort && !context.task.abortIsAnAnswer) {
      return Verdict.failure('agent aborted: ${outcome.message ?? ''}');
    }

    final criteria = context.task.successCriteria;
    if (criteria.isEmpty) {
      return Verdict.failure('task defines no success criteria');
    }

    var weightedScore = 0.0;
    var totalWeight = 0.0;
    final details = <String, Object?>{};
    final typeCounts = <String, int>{};
    for (final criterion in criteria) {
      typeCounts.update(criterion.type, (n) => n + 1, ifAbsent: () => 1);
    }
    final seenOfType = <String, int>{};
    for (final criterion in criteria) {
      final evaluator = evaluators[criterion.type];
      final outcome = evaluator == null
          ? CriterionOutcome(score: 0, detail: 'no evaluator registered for "${criterion.type}"')
          : await evaluator.evaluate(context, criterion);
      if (outcome.applies) {
        weightedScore += outcome.score * criterion.weight;
        totalWeight += criterion.weight;
      }
      final ordinal = seenOfType.update(criterion.type, (n) => n + 1, ifAbsent: () => 1);
      details[detailsKey(criterion, typeCounts[criterion.type]!, ordinal)] = {
        if (outcome.applies) 'score': outcome.score,
        'weight': criterion.weight,
        if (!outcome.applies) 'applies': false,
        'detail': outcome.detail,
        ...outcome.data,
      };
    }
    final score = totalWeight == 0 ? 0.0 : weightedScore / totalWeight;

    if (score >= 1) {
      return Verdict(type: .success, score: 1, details: details);
    }

    // Near-miss labelling via declarative partial-credit rules (§5.1). A rule
    // names a known near-miss; it never lowers what the criteria already
    // awarded, so the verdict takes the higher of the two.
    final ruleContext = _partialCreditContext(context);
    for (final rule in context.task.partialCredit) {
      try {
        if (ConditionExpr.evaluate(rule.condition, ruleContext) && rule.credit >= score) {
          return Verdict(type: .partial, score: rule.credit, label: rule.label, details: details);
        }
      } on FormatException catch (e) {
        details['partialCredit:${rule.label}'] = 'condition error: $e';
      }
    }

    if (score > 0) {
      return Verdict(type: .partial, score: score, label: 'partial criteria score', details: details);
    }
    return Verdict(
      type: .failure,
      score: 0,
      reason: details.entries.map((e) => '${e.key}: ${(e.value as JsonMap)['detail']}').join('; '),
      details: details,
    );
  }

  /// Where a criterion's outcome lands in [Verdict.details].
  ///
  /// The type alone while a task has one criterion of that type; with several
  /// (a task rubric plus the suite-wide faithfulness rubric) each gets
  /// `type:<rubric>` or `type#<n>`. Read them back with
  /// [Verdict.detailsOfType].
  static String detailsKey(SuccessCriterion criterion, int ofType, int ordinal) {
    if (ofType <= 1) return criterion.type;
    final rubric = asJsonMap(criterion.config['rubricSpec'])['rubric'];
    return rubric is String ? '${criterion.type}:$rubric' : '${criterion.type}#$ordinal';
  }

  /// Context for partial-credit conditions: `count` and `fields.*` refer to
  /// the first ground-truth query's result (spec §5.1 example), `results`
  /// maps every query to `{count, fields}`.
  static JsonMap _partialCreditContext(EvaluationContext context) {
    final snapshot = context.finalState;
    if (snapshot == null) return const {};
    JsonMap resultContext(StateQueryResult r) => {'count': r.count, 'fields': r.items.isEmpty ? const <String, Object?>{} : r.items.first};
    final first = context.task.groundTruth.finalState.isEmpty ? null : snapshot.resultFor(context.task.groundTruth.finalState.first.query);
    return {
      if (first != null) ...resultContext(first),
      'results': {for (final r in snapshot.results) r.query: resultContext(r)},
    };
  }
}
