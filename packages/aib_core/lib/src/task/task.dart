import '../common/json.dart';
import '../ports/environment.dart';

/// Episode budget (spec §5.1 `defaults.budget`).
final class Budget {
  const Budget({
    required this.maxSteps,
    required this.maxWallClockSeconds,
    this.maxTokens,
    this.maxTurns,
    this.maxIdenticalRepeats = 2,
    this.targetSeconds,
  });

  final int maxSteps;
  final int maxWallClockSeconds;
  final int? maxTokens;

  /// How many envelopes the agent may emit, acting or observing.
  ///
  /// A second dimension beside [maxTokens]: the token budget is charged per
  /// request, so a large prompt prefix dominates it. An episode that ends on
  /// [maxTurns] ran out of attempts, one that ends on [maxTokens] ran out of
  /// room. Null leaves it uncapped.
  final int? maxTurns;

  /// How often the same envelope may come back with the same answer before the
  /// engine calls the episode stuck.
  ///
  /// Counted per (key, payload) signature, not consecutively: interleaving two
  /// stuck calls is still stuck. Null switches the guard off, for a task that
  /// deliberately polls for an external change.
  final int? maxIdenticalRepeats;

  /// How long a solved episode may take and still count as solved for a product
  /// with a user waiting. Soft: nothing stops the episode or tells the agent;
  /// it is scored afterwards (`success_within_target`). [maxWallClockSeconds]
  /// is the hard cap. Null leaves the task unscored on it.
  final int? targetSeconds;

  Budget mergedWith(JsonMap? override) {
    if (override == null) return this;
    return Budget(
      maxSteps: (override['maxSteps'] as num?)?.toInt() ?? maxSteps,
      maxWallClockSeconds: (override['maxWallClockSeconds'] as num?)?.toInt() ?? maxWallClockSeconds,
      maxTokens: (override['maxTokens'] as num?)?.toInt() ?? maxTokens,
      maxTurns: (override['maxTurns'] as num?)?.toInt() ?? maxTurns,
      maxIdenticalRepeats: override.containsKey('maxIdenticalRepeats') ? (override['maxIdenticalRepeats'] as num?)?.toInt() : maxIdenticalRepeats,
      targetSeconds: override.containsKey('targetSeconds') ? (override['targetSeconds'] as num?)?.toInt() : targetSeconds,
    );
  }

  JsonMap toJson() => {
    'maxSteps': maxSteps,
    'maxWallClockSeconds': maxWallClockSeconds,
    if (maxTokens != null) 'maxTokens': maxTokens,
    if (maxTurns != null) 'maxTurns': maxTurns,
    if (maxIdenticalRepeats != null) 'maxIdenticalRepeats': maxIdenticalRepeats,
    if (targetSeconds != null) 'targetSeconds': targetSeconds,
  };

  factory Budget.fromJson(JsonMap json) => Budget(
    maxSteps: (json['maxSteps'] as num).toInt(),
    maxWallClockSeconds: (json['maxWallClockSeconds'] as num).toInt(),
    maxTokens: (json['maxTokens'] as num?)?.toInt(),
    maxTurns: (json['maxTurns'] as num?)?.toInt(),
    maxIdenticalRepeats: json.containsKey('maxIdenticalRepeats') ? (json['maxIdenticalRepeats'] as num?)?.toInt() : 2,
    targetSeconds: (json['targetSeconds'] as num?)?.toInt(),
  );
}

/// One `groundTruth.finalState` entry: a state query plus expectations.
///
/// The same shape describes a milestone expectation ([MilestoneSpec]) — the
/// only difference is *when* it is checked, not *how*. [mismatch] is the
/// single definition of "expectation satisfied" used by both oracles.
final class FinalStateExpectation {
  const FinalStateExpectation({required this.query, this.expectCount, this.expectMinCount, this.expectFields = const {}});

  final String query;
  final int? expectCount;

  /// Lower bound. Use instead of [expectCount] where more than the expected
  /// number is not a failure — counting an agent's behaviour, not a state.
  final int? expectMinCount;

  final JsonMap expectFields;

  /// `null` when [result] satisfies this expectation, otherwise a human
  /// readable reason. All returned rows must carry the expected field values.
  String? mismatch(StateQueryResult? result) {
    if (result == null) return 'not answered by environment';
    if (result.error != null) return result.error;
    if (expectCount != null && result.count != expectCount) {
      return 'expected count $expectCount, got ${result.count}';
    }
    if (expectMinCount != null && result.count < expectMinCount!) {
      return 'expected count >= $expectMinCount, got ${result.count}';
    }
    // Fields without a count mean "the rows that exist carry these values",
    // and zero rows carry nothing: without this an expectation on a record
    // that was never created passes vacuously.
    if (expectFields.isNotEmpty && expectCount == null && expectMinCount == null && result.count == 0) {
      return 'expected rows with ${expectFields.keys.join(', ')}, got none';
    }
    for (final item in result.items) {
      for (final entry in expectFields.entries) {
        final actual = resolveField(item, entry.key);
        if (!jsonEquals(actual, entry.value)) {
          return 'field ${entry.key}: expected ${entry.value}, got $actual';
        }
      }
    }
    return null;
  }

  /// Reads `a.b.c` out of a row, not just `'a.b.c'` as a key: state queries
  /// answer with nested rows, and a flat lookup reports `null`, which reads
  /// like the app not having set the value.
  ///
  /// A literal key wins over a path, so a row with a dot in a key keeps
  /// working.
  static Object? resolveField(JsonMap item, String path) {
    if (item.containsKey(path)) return item[path];
    Object? current = item;
    for (final segment in path.split('.')) {
      if (current is Map && current.containsKey(segment)) {
        current = current[segment];
      } else {
        return null;
      }
    }
    return current;
  }

  JsonMap toJson() => {
    'query': query,
    'expect': {
      if (expectCount != null) 'count': expectCount,
      if (expectMinCount != null) 'minCount': expectMinCount,
      if (expectFields.isNotEmpty) 'fields': expectFields,
    },
  };

  factory FinalStateExpectation.fromJson(JsonMap json) {
    final expect = asJsonMap(json['expect']);
    return FinalStateExpectation(
      query: json['query'] as String,
      expectCount: (expect['count'] as num?)?.toInt(),
      expectMinCount: (expect['minCount'] as num?)?.toInt(),
      expectFields: asJsonMap(expect['fields']),
    );
  }
}

/// One `groundTruth.milestones` entry: an *essential state* the episode must
/// pass through (spec §5.2, oracle `stateSequence`).
final class MilestoneSpec {
  const MilestoneSpec({required this.id, required this.expectation});

  final String id;
  final FinalStateExpectation expectation;

  String get query => expectation.query;

  JsonMap toJson() => {'id': id, ...expectation.toJson()};

  factory MilestoneSpec.fromJson(JsonMap json, {int index = 0}) =>
      MilestoneSpec(id: json['id'] as String? ?? 'm${index + 1}', expectation: FinalStateExpectation.fromJson(json));
}

final class GroundTruth {
  const GroundTruth({this.finalState = const [], this.milestones = const [], this.artifact, this.mustNotChange = const []});

  final List<FinalStateExpectation> finalState;

  /// Essential states probed *during* the episode (see [MilestoneSpec]).
  /// Declaring them makes the engine probe them after every exchange; the
  /// `stateSequence` criterion scores the resulting timeline. Recording is
  /// execution, scoring is evaluation (P6) — milestones may therefore be
  /// declared without any criterion consuming them yet.
  final List<MilestoneSpec> milestones;

  final JsonMap? artifact; // genui artifacts

  /// State queries whose answer must be the same at the end as after reset:
  /// what the task must not touch (-> `collateral_change_count`).
  final List<String> mustNotChange;

  /// Captured at the end: the finalState queries plus [mustNotChange].
  List<StateQuery> get stateQueries => [
    for (final query in {...finalState.map((e) => e.query), ...mustNotChange}) StateQuery(query),
  ];

  List<StateQuery> get mustNotChangeQueries => [for (final query in mustNotChange) StateQuery(query)];

  /// Deduplicated milestone queries — the probe list of the engine.
  List<StateQuery> get milestoneQueries {
    final seen = <String>{};
    return [
      for (final milestone in milestones)
        if (seen.add(milestone.query)) StateQuery(milestone.query),
    ];
  }

  JsonMap toJson() => {
    if (finalState.isNotEmpty) 'finalState': finalState.map((e) => e.toJson()).toList(),
    if (milestones.isNotEmpty) 'milestones': milestones.map((m) => m.toJson()).toList(),
    if (artifact != null) 'artifact': artifact,
    if (mustNotChange.isNotEmpty) 'mustNotChange': mustNotChange,
  };

  factory GroundTruth.fromJson(JsonMap json) {
    final milestones = json['milestones'] as List? ?? const [];
    return GroundTruth(
      finalState: (json['finalState'] as List? ?? const []).map((e) => FinalStateExpectation.fromJson(asJsonMap(e))).toList(),
      milestones: [for (var i = 0; i < milestones.length; i++) MilestoneSpec.fromJson(asJsonMap(milestones[i]), index: i)],
      artifact: json['artifact'] == null ? null : asJsonMap(json['artifact']),
      mustNotChange: [for (final entry in json['mustNotChange'] as List? ?? const []) entry is Map ? '${entry['query']}' : '$entry'],
    );
  }
}

/// Known criterion types (oracle hierarchy, spec §5.2). The registry accepts
/// additional types (P7); these are the built-in vocabulary for validation.
abstract final class CriterionTypes {
  static const finalStateMatch = 'finalStateMatch';
  static const stateSequence = 'stateSequence';
  static const traceAssertion = 'traceAssertion';
  static const artifactRubric = 'artifactRubric';
  static const manualReview = 'manualReview';

  static const all = {finalStateMatch, stateSequence, traceAssertion, artifactRubric, manualReview};
}

final class SuccessCriterion {
  const SuccessCriterion({required this.type, this.weight = 1.0, this.config = const {}});

  final String type;
  final double weight;
  final JsonMap config; // criterion-specific options (rubric, assertions, …)

  JsonMap toJson() => {'type': type, 'weight': weight, ...config};

  factory SuccessCriterion.fromJson(JsonMap json) => SuccessCriterion(
    type: json['type'] as String,
    weight: (json['weight'] as num?)?.toDouble() ?? 1.0,
    config: JsonMap.from(json)
      ..remove('type')
      ..remove('weight'),
  );
}

final class PartialCreditRule {
  const PartialCreditRule({required this.condition, required this.credit, required this.label});

  /// [ConditionExpr] over `{count, fields.*, results.*}` of the final state.
  final String condition;
  final double credit;
  final String label;

  JsonMap toJson() => {'condition': condition, 'credit': credit, 'label': label};

  factory PartialCreditRule.fromJson(JsonMap json) =>
      PartialCreditRule(condition: json['condition'] as String, credit: (json['credit'] as num).toDouble(), label: json['label'] as String? ?? '');
}

/// What the user says after the agent reports it is done. The episode continues
/// rather than resets: the app keeps what the previous turn left behind.
final class FollowUp {
  const FollowUp({required this.id, required this.instruction});

  final String id;
  final String instruction;

  JsonMap toJson() => {'id': id, 'instruction': instruction};

  factory FollowUp.fromJson(JsonMap json) => FollowUp(id: json['id'] as String? ?? 'turn', instruction: json['instruction'] as String? ?? '');
}

/// Something the user says *while* the agent works — a correction, a detail
/// they forgot — rather than after it said done (`turns:`). Delivered once the
/// agent has taken [afterActions] app actions, to an agent that can hear it
/// ([SteerableAgent]); the ground truth is the goal as steered.
final class SteeringMessage {
  const SteeringMessage({required this.id, required this.afterActions, required this.message});

  final String id;
  final int afterActions;
  final String message;

  JsonMap toJson() => {'id': id, 'afterActions': afterActions, 'message': message};

  factory SteeringMessage.fromJson(JsonMap json) => SteeringMessage(
    id: json['id'] as String? ?? 'steer',
    afterActions: (json['afterActions'] as num?)?.toInt() ?? 1,
    message: json['message'] as String? ?? '',
  );
}

/// One rewording of a task's instruction: the same goal, said differently.
///
/// Same ground truth, same oracle — only the words move, so the difference
/// in outcome is the agent's sensitivity to them (`prompt_robustness`).
final class InstructionVariant {
  const InstructionVariant({required this.id, required this.instruction});

  /// Short and stable; becomes the `variant:<id>` tag and the episode suffix.
  final String id;
  final String instruction;

  JsonMap toJson() => {'id': id, 'instruction': instruction};

  factory InstructionVariant.fromJson(JsonMap json) => InstructionVariant(id: json['id'] as String, instruction: json['instruction'] as String);
}

/// A model standing in for the user: who they are, what they want, and what
/// they cannot know.
final class UserSimulatorSpec {
  const UserSimulatorSpec({
    required this.goal,
    this.persona = '',
    this.knows = const {},
    this.mustNotReveal = const [],
    this.mustNotAsk = const [],
    this.maxFollowUps = 2,
  });

  final String goal;
  final String persona;

  /// Answers given verbatim, keyed by a phrase of the question or a question
  /// type: a record id is nothing a model can know.
  final JsonMap knows;

  /// Ground truth the user does not have; saying it breaks the simulation.
  final List<String> mustNotReveal;

  /// What the goal rules out; asking for it contradicts the goal.
  final List<String> mustNotAsk;

  /// Messages the user may add after `meta.done`.
  final int maxFollowUps;

  JsonMap toJson() => {
    'goal': goal,
    if (persona.isNotEmpty) 'persona': persona,
    if (knows.isNotEmpty) 'knows': knows,
    if (mustNotReveal.isNotEmpty) 'mustNotReveal': mustNotReveal,
    if (mustNotAsk.isNotEmpty) 'mustNotAsk': mustNotAsk,
    'maxFollowUps': maxFollowUps,
  };

  factory UserSimulatorSpec.fromJson(JsonMap json) => UserSimulatorSpec(
    goal: json['goal'] as String? ?? '',
    persona: json['persona'] as String? ?? '',
    knows: asJsonMap(json['knows']),
    mustNotReveal: [for (final s in json['mustNotReveal'] as List? ?? const []) '$s'],
    mustNotAsk: [for (final s in json['mustNotAsk'] as List? ?? const []) '$s'],
    maxFollowUps: (json['maxFollowUps'] as num?)?.toInt() ?? 2,
  );
}

/// Fully resolved task (defaults from the suite already merged in by the
/// loader, so a TaskSpec is self-contained — it can travel over the wire).
final class TaskSpec {
  const TaskSpec({
    required this.id,
    required this.title,
    required this.instruction,
    required this.budget,
    required this.fixture,
    this.tags = const [],
    this.groundTruth = const GroundTruth(),
    this.successCriteria = const [],
    this.partialCredit = const [],
    this.optimalSteps,
    this.repetitions,
    this.abortIsAnAnswer = false,
    this.turns = const [],
    this.steering = const [],
    this.cancelAtTurn,
    this.variants = const [],
    this.policies = const [],
    this.refusalRequires = const [],
    this.expectsClarification,
    this.requiredFacts = const [],
    this.requiredTools = const [],
    this.userSimulator,
    this.metadata = const {},
  });

  final String id;
  final String title;
  final String instruction;

  /// Values the answer turns on, as they appear in an observation. Separates
  /// "the agent never had the fact" from "it had it and did not use it".
  final List<String> requiredFacts;

  /// Catalogue names a correct solution has to call: the retrieval oracle.
  ///
  /// `prefetch_recall` is measured against the trajectory the agent took, which
  /// preparation changes, so retrieval is also scored against this declared
  /// gold set (Recall@k, nDCG@k, Completeness@k). Derivable from the reference
  /// trajectories.
  final List<String> requiredTools;

  final Budget budget;
  final FixtureRef fixture;
  final List<String> tags;
  final GroundTruth groundTruth;
  final List<SuccessCriterion> successCriteria;
  final List<PartialCreditRule> partialCredit;

  /// What the engine captures at the end: the ground truth's queries plus any
  /// criterion's `artifactState` query, so a rubric can judge what the app
  /// ended up showing rather than what the agent sent.
  List<StateQuery> get finalStateQueries => [
    for (final query in {
      ...groundTruth.stateQueries.map((q) => q.query),
      for (final criterion in successCriteria)
        if (criterion.config['artifactState'] case final String query when query.trim().isNotEmpty) query.trim(),
    })
      StateQuery(query),
  ];

  /// Minimal known number of act-envelopes (basis of `path_efficiency`).
  final int? optimalSteps;

  /// Per-task override of the suite default.
  final int? repetitions;

  /// Score an aborted episode on its criteria instead of ADR 0003's flat
  /// failure. For tasks where refusing is the correct answer.
  final bool abortIsAnAnswer;

  /// What the user says after each `meta.done`, in order. The episode ends when
  /// the last one is answered or a budget runs out.
  final List<FollowUp> turns;

  /// What the user says mid-episode, in order ([SteeringMessage]).
  final List<SteeringMessage> steering;

  /// The engine stops the agent after this many envelopes, as a user pressing
  /// stop would. The ground truth then says what a stop may leave behind.
  final int? cancelAtTurn;

  /// Rewordings of [instruction] run as their own episodes. Empty means the
  /// task is asked one way only.
  final List<InstructionVariant> variants;

  /// Rules the episode must keep whatever it achieves: traceAssertion
  /// entries, plus `{kind: confirmBefore, effects: [...]}`. They do not
  /// change the score; they gate `completion_under_policy`.
  final List<JsonMap> policies;

  /// What a refusal must have reached to count as a judgement rather than
  /// a failure to find the thing (-> `safe_refusal`): `{milestone: id}` or
  /// a policy-style assertion such as `{kind: everIntent, intent: …}`.
  final List<JsonMap> refusalRequires;

  /// Whether a good episode asks the user; null when the task does not say.
  final bool? expectsClarification;

  /// A simulated user who answers questions and follows up.
  final UserSimulatorSpec? userSimulator;

  final JsonMap metadata;

  JsonMap toJson() => {
    'id': id,
    'title': title,
    'instruction': instruction,
    'budget': budget.toJson(),
    'fixture': fixture.toJson(),
    'tags': tags,
    'groundTruth': groundTruth.toJson(),
    'successCriteria': successCriteria.map((c) => c.toJson()).toList(),
    'partialCredit': partialCredit.map((r) => r.toJson()).toList(),
    if (optimalSteps != null) 'optimalSteps': optimalSteps,
    if (repetitions != null) 'repetitions': repetitions,
    if (abortIsAnAnswer) 'abortIsAnAnswer': true,
    if (turns.isNotEmpty) 'turns': turns.map((t) => t.toJson()).toList(),
    if (steering.isNotEmpty) 'steering': steering.map((t) => t.toJson()).toList(),
    if (cancelAtTurn != null) 'cancelAtTurn': cancelAtTurn,
    if (variants.isNotEmpty) 'variants': variants.map((v) => v.toJson()).toList(),
    if (policies.isNotEmpty) 'policies': policies,
    if (refusalRequires.isNotEmpty) 'refusalRequires': refusalRequires,
    if (expectsClarification != null) 'expectsClarification': expectsClarification,
    if (requiredFacts.isNotEmpty) 'requiredFacts': requiredFacts,
    if (requiredTools.isNotEmpty) 'requiredTools': requiredTools,
    'userSimulator': ?userSimulator?.toJson(),
    'metadata': metadata,
  };

  factory TaskSpec.fromJson(JsonMap json) => TaskSpec(
    id: json['id'] as String,
    title: json['title'] as String? ?? json['id'] as String,
    instruction: json['instruction'] as String,
    budget: Budget.fromJson(asJsonMap(json['budget'])),
    fixture: FixtureRef.fromJson(asJsonMap(json['fixture'])),
    tags: (json['tags'] as List? ?? const []).cast<String>(),
    groundTruth: GroundTruth.fromJson(asJsonMap(json['groundTruth'])),
    successCriteria: (json['successCriteria'] as List? ?? const []).map((e) => SuccessCriterion.fromJson(asJsonMap(e))).toList(),
    partialCredit: (json['partialCredit'] as List? ?? const []).map((e) => PartialCreditRule.fromJson(asJsonMap(e))).toList(),
    optimalSteps: (json['optimalSteps'] as num?)?.toInt(),
    repetitions: (json['repetitions'] as num?)?.toInt(),
    abortIsAnAnswer: json['abortIsAnAnswer'] as bool? ?? false,
    turns: [for (final t in json['turns'] as List? ?? const []) FollowUp.fromJson(asJsonMap(t))],
    steering: [for (final t in json['steering'] as List? ?? const []) SteeringMessage.fromJson(asJsonMap(t))],
    cancelAtTurn: (json['cancelAtTurn'] as num?)?.toInt(),
    variants: [for (final v in json['variants'] as List? ?? const []) InstructionVariant.fromJson(asJsonMap(v))],
    policies: [for (final p in json['policies'] as List? ?? const []) asJsonMap(p)],
    refusalRequires: [for (final r in json['refusalRequires'] as List? ?? const []) asJsonMap(r)],
    expectsClarification: json['expectsClarification'] as bool?,
    requiredFacts: [for (final f in json['requiredFacts'] as List? ?? const []) '$f'],
    requiredTools: [for (final t in json['requiredTools'] as List? ?? const []) '$t'],
    userSimulator: json['userSimulator'] == null ? null : UserSimulatorSpec.fromJson(asJsonMap(json['userSimulator'])),
    metadata: asJsonMap(json['metadata']),
  );
}

extension TaskVariants on TaskSpec {
  /// The task as asked by [variant]: same ground truth, different words, and
  /// a `variant:` tag so the slice can be compared with the base.
  TaskSpec asVariant(InstructionVariant variant) => TaskSpec(
    id: id,
    title: title,
    instruction: variant.instruction,
    budget: budget,
    fixture: fixture,
    tags: [...tags, 'variant:${variant.id}'],
    groundTruth: groundTruth,
    successCriteria: successCriteria,
    partialCredit: partialCredit,
    optimalSteps: optimalSteps,
    repetitions: repetitions,
    abortIsAnAnswer: abortIsAnAnswer,
    policies: policies,
    refusalRequires: refusalRequires,
    expectsClarification: expectsClarification,
    requiredFacts: requiredFacts,
    requiredTools: requiredTools,
    turns: turns,
    steering: steering,
    cancelAtTurn: cancelAtTurn,
    userSimulator: userSimulator,
    metadata: metadata,
  );
}

final class TaskSuite {
  const TaskSuite({
    required this.name,
    required this.schema,
    required this.defaultRepetitions,
    required this.tasks,
    this.sourcePath,
    this.sourceHash,
  });

  final String name;
  final String schema;
  final int defaultRepetitions;
  final List<TaskSpec> tasks;
  final String? sourcePath;
  final String? sourceHash;

  static const supportedSchema = 'aib-task/1.0';

  int repetitionsFor(TaskSpec task) => task.repetitions ?? defaultRepetitions;

  /// Hash over every resolved task, fixture data and rubrics included.
  /// [sourceHash] covers the YAML only.
  String get contentHash => jsonFingerprint([for (final task in tasks) task.toJson()]);

  /// [contentHash] per task, so a filtered re-run (`--only`, `AIB_TASKS`) can
  /// be told apart from a changed suite.
  Map<String, String> get taskContentHashes => {for (final task in tasks) task.id: jsonFingerprint(task.toJson())};

  TaskSpec? taskById(String id) {
    for (final task in tasks) {
      if (task.id == id) return task;
    }
    return null;
  }
}
