import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../common/json.dart';
import '../evaluation/artifact_rubric.dart';
import '../evaluation/assertions.dart';
import '../evaluation/judge_provenance.dart';
import '../ports/environment.dart';
import 'task.dart';

final class SuiteLoadResult {
  const SuiteLoadResult({this.suite, this.errors = const [], this.warnings = const []});

  final TaskSuite? suite;
  final List<String> errors;
  final List<String> warnings;

  bool get isValid => errors.isEmpty && suite != null;
}

/// Every key a task block may carry. A key outside this set is a warning rather
/// than ignored, so a misspelled option cannot silently do nothing.
const _taskKeys = {
  'id',
  'title',
  'instruction',
  'budget',
  'fixture',
  'tags',
  'groundTruth',
  'successCriteria',
  'partialCredit',
  'optimalSteps',
  'repetitions',
  'abortIsAnAnswer',
  'turns',
  'steering',
  'cancelAtTurn',
  'variants',
  'policies',
  'refusalRequires',
  'expectsClarification',
  'requiredFacts',
  'requiredTools',
  'userSimulator',
  'metadata',
};

const _groundTruthKeys = {'finalState', 'milestones', 'artifact', 'artifactRubric', 'mustNotChange'};

const _budgetKeys = {'maxSteps', 'maxWallClockSeconds', 'maxTokens', 'maxTurns', 'maxIdenticalRepeats', 'targetSeconds'};

/// Loads and validates declarative task suites (spec §5.1, P5: tasks are
/// data, not code). Fixture files are inlined into each task's [FixtureRef]
/// so downstream consumers (engines, remote environments) need no file
/// system access.
final class SuiteLoader {
  /// [assertionKinds]: kinds registered beyond the built-in ones (a
  /// provider's), which are then validated rather than only warned about.
  static SuiteLoadResult loadFile(String path, {bool inlineFixtures = true, Set<String> assertionKinds = const {}}) {
    final file = File(path);
    if (!file.existsSync()) {
      return SuiteLoadResult(errors: ['Suite file not found: $path']);
    }
    final content = file.readAsStringSync();
    return loadString(content, sourcePath: path, basePath: file.parent.path, inlineFixtures: inlineFixtures, assertionKinds: assertionKinds);
  }

  static SuiteLoadResult loadString(
    String yamlContent, {
    String? sourcePath,
    String? basePath,
    bool inlineFixtures = true,
    Set<String> assertionKinds = const {},
  }) {
    final errors = <String>[];
    final warnings = <String>[];

    JsonMap root;
    try {
      final decoded = loadYaml(yamlContent);
      root = asJsonMap(jsonDecode(jsonEncode(decoded)));
    } catch (e) {
      return SuiteLoadResult(errors: ['YAML parse error: $e']);
    }

    final schema = root['schema'] as String?;
    if (schema != TaskSuite.supportedSchema) {
      errors.add(
        'Unsupported or missing schema "$schema" '
        '(expected "${TaskSuite.supportedSchema}")',
      );
    }
    final suiteName = root['suite'] as String?;
    if (suiteName == null || suiteName.isEmpty) {
      errors.add('Missing "suite" name');
    }

    final defaults = asJsonMap(root['defaults']);
    final defaultPolicies = [for (final p in defaults['policies'] as List? ?? const []) asJsonMap(p)];
    // Criteria every task carries: one faithfulness rubric for a whole suite,
    // say. A default `artifactRubric` must name a `rubric:` file: the
    // inline form lives in a task's groundTruth, and a default has no task.
    final defaultCriteria = [for (final c in defaults['criteria'] as List? ?? const []) asJsonMap(c)];
    final defaultRepetitions = (defaults['repetitions'] as num?)?.toInt() ?? 1;
    if (defaultRepetitions < 1) {
      errors.add('defaults.repetitions must be >= 1');
    }

    Budget? defaultBudget;
    final defaultBudgetJson = defaults['budget'];
    if (defaultBudgetJson != null) {
      _warnUnknownBudgetKeys(asJsonMap(defaultBudgetJson), 'defaults.budget', warnings);
      defaultBudget = _parseBudget(asJsonMap(defaultBudgetJson), context: 'defaults.budget', errors: errors);
    }
    final defaultFixture = defaults['fixture'] as String?;

    final tasksJson = root['tasks'];
    if (tasksJson is! List || tasksJson.isEmpty) {
      errors.add('Suite must define a non-empty "tasks" list');
      return SuiteLoadResult(errors: errors, warnings: warnings);
    }

    final reader = _TaskReader(
      errors: errors,
      warnings: warnings,
      basePath: basePath,
      inlineFixtures: inlineFixtures,
      assertionKinds: assertionKinds,
      defaultBudget: defaultBudget,
      defaultFixture: defaultFixture,
      defaultCriteria: defaultCriteria,
      defaultPolicies: defaultPolicies,
    );
    final seenIds = <String>{};
    final tasks = <TaskSpec>[];
    for (final (i, raw) in tasksJson.indexed) {
      final t = asJsonMap(raw);
      final id = t['id'] as String?;
      final ctx = 'tasks[$i]${id == null ? '' : ' ($id)'}';
      if (id == null || id.isEmpty) {
        errors.add('$ctx: missing "id"');
        continue;
      }
      if (!seenIds.add(id)) {
        errors.add('$ctx: duplicate task id');
      }
      if (reader.read(t, id, ctx) case final task?) tasks.add(task);
    }

    if (errors.isNotEmpty) {
      return SuiteLoadResult(errors: errors, warnings: warnings);
    }
    return SuiteLoadResult(
      suite: TaskSuite(
        name: suiteName!,
        schema: schema!,
        defaultRepetitions: defaultRepetitions,
        tasks: tasks,
        sourcePath: sourcePath,
        sourceHash: stringFingerprint(yamlContent),
      ),
      warnings: warnings,
    );
  }

  static Budget? _parseBudget(JsonMap json, {required String context, required List<String> errors}) {
    final maxSteps = (json['maxSteps'] as num?)?.toInt();
    final maxWallClock = (json['maxWallClockSeconds'] as num?)?.toInt();
    if (maxSteps == null || maxWallClock == null) {
      errors.add('$context: maxSteps and maxWallClockSeconds are required');
      return null;
    }
    return Budget(
      maxSteps: maxSteps,
      maxWallClockSeconds: maxWallClock,
      maxTokens: (json['maxTokens'] as num?)?.toInt(),
      maxTurns: (json['maxTurns'] as num?)?.toInt(),
      // Present-but-null switches the guard off; absent keeps the default.
      maxIdenticalRepeats: json.containsKey('maxIdenticalRepeats')
          ? (json['maxIdenticalRepeats'] as num?)?.toInt()
          : const Budget(maxSteps: 1, maxWallClockSeconds: 1).maxIdenticalRepeats,
      targetSeconds: (json['targetSeconds'] as num?)?.toInt(),
    );
  }

  static void _warnUnknownBudgetKeys(JsonMap budget, String context, List<String> warnings) {
    for (final key in budget.keys) {
      if (!_budgetKeys.contains(key)) {
        warnings.add('$context: unknown budget key "$key" — nothing reads it');
      }
    }
  }

  /// A kind the core evaluates is checked here; any other kind is accepted
  /// with a warning, like an unknown criterion type, because providers
  /// (`intents`, …) register theirs only at evaluation time.
  static void _checkAssertionKind(JsonMap assertion, String context, Set<String> registered, List<String> errors, List<String> warnings) {
    final kind = assertion['kind'];
    if (kind is! String || kind.isEmpty) {
      errors.add('$context entry needs a "kind"');
    } else if (!builtinAssertionKinds.contains(kind) && !registered.contains(kind)) {
      warnings.add(
        '$context kind "$kind" is not built in '
        '(accepted — must be registered at evaluation time)',
      );
    }
  }

  /// Turns a task's own `groundTruth.artifactRubric` into the same shape
  /// [_loadRubric] produces, so the evaluator cannot tell the two apart.
  ///
  /// The rubric is named after its task: there is exactly one per task, and
  /// the name is what a verdict's detail line reports it by.
  static JsonMap? _inlineRubric(JsonMap rubric, String taskId, String ctx, List<String> errors) {
    final raw = rubric['criteria'] as List? ?? const [];
    if (raw.isEmpty) {
      errors.add('$ctx: groundTruth.artifactRubric has no criteria');
      return null;
    }
    final criteria = <JsonMap>[];
    final ids = <String>{};
    for (final (index, entry) in raw.indexed) {
      final where = '$ctx: groundTruth.artifactRubric criterion ${index + 1}';
      if (entry is! Map) {
        errors.add('$where must be a map with "id" and "question"');
        continue;
      }
      final json = asJsonMap(entry);
      final id = json['id'] as String?;
      final question = json['question'] as String?;
      if (id == null || id.isEmpty) {
        errors.add('$where has no "id"');
        continue;
      }
      if (question == null || question.trim().isEmpty) {
        errors.add('$where ("$id") has no "question"');
        continue;
      }
      if (!ids.add(id)) {
        errors.add('$where: duplicate criterion id "$id"');
        continue;
      }
      criteria.add({'id': id, 'question': question, if (json['weight'] != null) 'weight': json['weight']});
    }
    if (criteria.isEmpty) return null;
    return {'rubric': taskId, 'criteria': criteria};
  }

  static JsonMap? _loadRubric(String rubricPath, String? basePath, String ctx, List<String> errors) {
    final resolved = basePath == null || p.isAbsolute(rubricPath) ? rubricPath : p.join(basePath, rubricPath);
    final file = File(resolved);
    if (!file.existsSync()) {
      errors.add('$ctx: rubric file not found: $resolved');
      return null;
    }
    try {
      return asJsonMap(jsonDecode(jsonEncode(loadYaml(file.readAsStringSync()))));
    } catch (e) {
      errors.add('$ctx: rubric $resolved is not valid YAML: $e');
      return null;
    }
  }

  static JsonMap? _loadFixture(String fixturePath, String? basePath, List<String> errors) {
    final resolved = basePath == null || p.isAbsolute(fixturePath) ? fixturePath : p.join(basePath, fixturePath);
    final file = File(resolved);
    if (!file.existsSync()) {
      errors.add('Fixture file not found: $resolved');
      return null;
    }
    try {
      return asJsonMap(jsonDecode(file.readAsStringSync()));
    } catch (e) {
      errors.add('Fixture $resolved is not valid JSON: $e');
      return null;
    }
  }
}

/// Reads one task block at a time, collecting into [errors] and [warnings].
final class _TaskReader {
  _TaskReader({
    required this.errors,
    required this.warnings,
    required this.basePath,
    required this.inlineFixtures,
    required this.assertionKinds,
    required this.defaultBudget,
    required this.defaultFixture,
    required this.defaultCriteria,
    required this.defaultPolicies,
  });

  final List<String> errors;
  final List<String> warnings;
  final String? basePath;
  final bool inlineFixtures;
  final Set<String> assertionKinds;
  final Budget? defaultBudget;
  final String? defaultFixture;
  final List<JsonMap> defaultCriteria;
  final List<JsonMap> defaultPolicies;
  final _fixtures = <String, JsonMap?>{};

  /// The task, or null once any error was collected, in this task or an earlier one.
  TaskSpec? read(JsonMap t, String id, String ctx) {
    final instruction = t['instruction'] as String?;
    if (instruction == null || instruction.trim().isEmpty) {
      errors.add('$ctx: missing "instruction"');
    }
    final budget = _budget(t, ctx);
    final fixturePath = t['fixture'] as String? ?? defaultFixture;
    final fixtureData = _fixture(fixturePath, ctx);
    final criteria = _criteria(t, id, ctx);
    _warnUnknownKeys(t, ctx);
    final groundTruth = GroundTruth.fromJson(asJsonMap(t['groundTruth']));
    final policies = [...defaultPolicies, for (final p in t['policies'] as List? ?? const []) asJsonMap(p)];
    for (final policy in policies) {
      SuiteLoader._checkAssertionKind(policy, '$ctx: policy', assertionKinds, errors, warnings);
    }
    _checkFinalState(groundTruth, criteria, ctx);
    final milestoneIds = _checkMilestones(groundTruth, criteria, ctx);
    final turns = _turns(t, ctx);
    final steering = _steering(t, ctx);
    final cancelAtTurn = (t['cancelAtTurn'] as num?)?.toInt();
    if (cancelAtTurn != null && cancelAtTurn < 1) {
      errors.add('$ctx: cancelAtTurn must be at least 1');
    }
    final variants = _variants(t, ctx);
    final refusalRequires = _refusalRequires(t, milestoneIds, ctx);
    final partialCredit = _partialCredit(t, ctx);
    final optimalSteps = (t['optimalSteps'] as num?)?.toInt();
    if (optimalSteps != null && optimalSteps < 1) {
      errors.add('$ctx: optimalSteps must be >= 1');
    }
    final simulator = t['userSimulator'] == null ? null : UserSimulatorSpec.fromJson(asJsonMap(t['userSimulator']));
    if (simulator != null && simulator.goal.trim().isEmpty) {
      errors.add('$ctx: userSimulator needs a "goal"');
    }

    if (errors.isNotEmpty) return null;

    return TaskSpec(
      id: id,
      title: t['title'] as String? ?? id,
      instruction: instruction!.trim(),
      budget: budget!,
      fixture: FixtureRef(id: p.basenameWithoutExtension(fixturePath!), path: fixturePath, data: fixtureData),
      tags: (t['tags'] as List? ?? const []).cast<String>(),
      groundTruth: groundTruth,
      successCriteria: criteria,
      partialCredit: partialCredit,
      optimalSteps: optimalSteps,
      repetitions: (t['repetitions'] as num?)?.toInt(),
      abortIsAnAnswer: t['abortIsAnAnswer'] as bool? ?? false,
      turns: turns,
      steering: steering,
      cancelAtTurn: cancelAtTurn,
      variants: variants,
      policies: policies,
      refusalRequires: refusalRequires,
      expectsClarification: t['expectsClarification'] as bool?,
      requiredFacts: [for (final f in t['requiredFacts'] as List? ?? const []) '$f'],
      requiredTools: [for (final tool in t['requiredTools'] as List? ?? const []) '$tool'],
      userSimulator: simulator,
      metadata: asJsonMap(t['metadata']),
    );
  }

  Budget? _budget(JsonMap t, String ctx) {
    final budgetOverride = t['budget'] == null ? null : asJsonMap(t['budget']);
    if (budgetOverride != null) {
      SuiteLoader._warnUnknownBudgetKeys(budgetOverride, '$ctx.budget', warnings);
    }
    Budget? budget;
    if (defaultBudget case final defaults?) {
      budget = defaults.mergedWith(budgetOverride);
    } else if (budgetOverride != null) {
      budget = SuiteLoader._parseBudget(budgetOverride, context: '$ctx.budget', errors: errors);
    } else {
      errors.add('$ctx: no budget (neither defaults.budget nor task budget)');
    }
    if (budget == null) return null;
    if (budget.maxSteps < 1 || budget.maxWallClockSeconds < 1) {
      errors.add('$ctx: budget values must be positive');
    }
    if (budget.targetSeconds case final target? when target < 1 || target > budget.maxWallClockSeconds) {
      errors.add('$ctx: budget.targetSeconds must be positive and at most maxWallClockSeconds');
    }
    return budget;
  }

  JsonMap? _fixture(String? fixturePath, String ctx) {
    if (fixturePath == null) {
      errors.add('$ctx: no fixture (neither defaults.fixture nor task fixture)');
      return null;
    }
    if (!inlineFixtures) return null;
    return _fixtures.containsKey(fixturePath)
        ? _fixtures[fixturePath]
        : _fixtures[fixturePath] = SuiteLoader._loadFixture(fixturePath, basePath, errors);
  }

  List<SuccessCriterion> _criteria(JsonMap t, String id, String ctx) {
    final ownCriteria = t['successCriteria'] as List? ?? const [];
    if (ownCriteria.isEmpty) {
      errors.add('$ctx: at least one successCriteria entry is required');
    }
    final inlineRubric = t['groundTruth'] is Map ? asJsonMap(t['groundTruth'])['artifactRubric'] : null;
    final criteria = <SuccessCriterion>[];
    // At most one criterion may take the task's inline rubric.
    var inlineRubricClaimed = false;
    // The task's own first, so a report reads them in declared order.
    for (final c in [...ownCriteria, ...defaultCriteria]) {
      var criterion = SuccessCriterion.fromJson(asJsonMap(c));
      if (!CriterionTypes.all.contains(criterion.type)) {
        warnings.add(
          '$ctx: unknown criterion type "${criterion.type}" '
          '(accepted — must be registered at evaluation time)',
        );
      }
      if (criterion.weight <= 0) {
        errors.add('$ctx: criterion weight must be > 0');
      }
      if (criterion.type == CriterionTypes.artifactRubric) {
        if (JudgeProvenance.pinnedModelOf(criterion) == null) {
          warnings.add(
            '$ctx: artifactRubric without a pinned judgeModel — '
            'rubric scores are then only reproducible by convention (§5.1)',
          );
        }
        _checkArtifactSource(criterion, ctx);
        if (criterion.config['rubric'] == null && inlineRubric != null) {
          if (inlineRubricClaimed) {
            errors.add(
              '$ctx: two artifactRubric criteria rely on the same '
              'groundTruth.artifactRubric — give one of them its own '
              '"rubric: <file>"',
            );
          }
          inlineRubricClaimed = true;
        }
        criterion = _withRubric(criterion, inlineRubric, id, ctx);
      }
      criteria.add(criterion);
    }

    // A rubric written into a task that no criterion takes is a declaration
    // nothing reads. It happens when the only artifactRubric criterion names
    // its own file.
    if (!inlineRubricClaimed && inlineRubric != null) {
      errors.add(
        '$ctx: groundTruth.artifactRubric is not used by any criterion — '
        'remove it, or drop the "rubric:" file from the criterion that '
        'should read it',
      );
    }
    return criteria;
  }

  /// Which envelope carries the artifact is the environment's vocabulary, so the
  /// suite names it; the core assumes none.
  void _checkArtifactSource(SuccessCriterion criterion, String ctx) {
    final hasKey = ArtifactRubricEvaluator.artifactKeysOf(criterion.config).isNotEmpty;
    final hasState = ArtifactRubricEvaluator.artifactStateOf(criterion.config) != null;
    if (hasKey == hasState) {
      errors.add(
        '$ctx: artifactRubric needs exactly one of "artifactKey" (the '
        'envelope key, or list of keys, whose payload is judged) and '
        '"artifactState" (a final-state query whose rows are judged)',
      );
    }
  }

  /// [criterion] with its rubric as data, written into the task or inlined from
  /// its file like a fixture, because the evaluator never reads the checkout: a
  /// run can be re-evaluated from the trace alone.
  ///
  /// An `artifactRubric` with no rubric at all is an error, not a criterion that
  /// scores 0 forever.
  SuccessCriterion _withRubric(SuccessCriterion criterion, Object? inlineRubric, String id, String ctx) {
    final rubricPath = criterion.config['rubric'] as String?;
    if (rubricPath == null && inlineRubric == null) {
      errors.add(
        '$ctx: artifactRubric without a rubric — give the criterion a '
        '"rubric: <file>" or the task a groundTruth.artifactRubric',
      );
    }
    // A rubric file is read only when fixtures are; an inline one needs nothing
    // but the task, so it is always resolved.
    final rubricSpec = switch ((rubricPath, inlineRubric)) {
      (final String path, _) => inlineFixtures ? SuiteLoader._loadRubric(path, basePath, ctx, errors) : null,
      (null, null) => null,
      (null, final rubric?) => SuiteLoader._inlineRubric(asJsonMap(rubric), id, ctx, errors),
    };
    if (rubricSpec == null) return criterion;
    return SuccessCriterion(type: criterion.type, weight: criterion.weight, config: {...criterion.config, 'rubricSpec': rubricSpec});
  }

  void _warnUnknownKeys(JsonMap t, String ctx) {
    for (final key in t.keys) {
      if (!_taskKeys.contains(key)) {
        warnings.add('$ctx: unknown key "$key" — nothing reads it');
      }
    }
    for (final key in asJsonMap(t['groundTruth']).keys) {
      if (!_groundTruthKeys.contains(key)) {
        warnings.add('$ctx: unknown groundTruth key "$key" — nothing reads it');
      }
    }
  }

  void _checkFinalState(GroundTruth groundTruth, List<SuccessCriterion> criteria, String ctx) {
    final expectations = groundTruth.finalState;
    for (final expectation in expectations) {
      if (expectation.expectCount == null && expectation.expectMinCount == null && expectation.expectFields.isEmpty) {
        errors.add(
          '$ctx: groundTruth.finalState "${expectation.query}" has no '
          'expect.count, expect.minCount or expect.fields — it would match '
          'any state',
        );
      }
    }
    if (criteria.any((c) => c.type == CriterionTypes.finalStateMatch) && expectations.isEmpty) {
      errors.add('$ctx: finalStateMatch criterion requires groundTruth.finalState');
    }
  }

  /// Essential states (§5.2 `stateSequence`): recording them is execution, scoring
  /// them is evaluation (P6), so milestones without a criterion are legal, but a
  /// criterion without milestones can never pass.
  Set<String> _checkMilestones(GroundTruth groundTruth, List<SuccessCriterion> criteria, String ctx) {
    final milestoneIds = <String>{};
    for (final milestone in groundTruth.milestones) {
      if (milestone.query.trim().isEmpty) {
        errors.add('$ctx: groundTruth.milestones entry without "query"');
      }
      if (!milestoneIds.add(milestone.id)) {
        errors.add('$ctx: duplicate milestone id "${milestone.id}"');
      }
      if (milestone.expectation.expectCount == null && milestone.expectation.expectMinCount == null && milestone.expectation.expectFields.isEmpty) {
        errors.add(
          '$ctx: milestone "${milestone.id}" has no expect.count '
          'and no expect.fields — it would match any state',
        );
      }
    }
    if (criteria.any((c) => c.type == CriterionTypes.stateSequence) && groundTruth.milestones.isEmpty) {
      errors.add(
        '$ctx: stateSequence criterion requires '
        'groundTruth.milestones',
      );
    }
    return milestoneIds;
  }

  List<FollowUp> _turns(JsonMap t, String ctx) {
    final turns = <FollowUp>[];
    final turnIds = <String>{};
    for (final raw in t['turns'] as List? ?? const []) {
      final turn = FollowUp.fromJson(asJsonMap(raw));
      if (turn.instruction.trim().isEmpty) {
        errors.add('$ctx: every turn needs an "instruction"');
      }
      if (!turnIds.add(turn.id)) {
        errors.add('$ctx: duplicate turn id "${turn.id}"');
      }
      turns.add(turn);
    }
    return turns;
  }

  List<SteeringMessage> _steering(JsonMap t, String ctx) {
    final steering = <SteeringMessage>[];
    for (final raw in t['steering'] as List? ?? const []) {
      final steer = SteeringMessage.fromJson(asJsonMap(raw));
      if (steer.message.trim().isEmpty) errors.add('$ctx: every steering entry needs a "message"');
      if (steer.afterActions < 0) errors.add('$ctx: steering.afterActions must be at least 0');
      if (steering.any((s) => s.id == steer.id)) errors.add('$ctx: duplicate steering id "${steer.id}"');
      steering.add(steer);
    }
    return steering;
  }

  List<InstructionVariant> _variants(JsonMap t, String ctx) {
    final variants = <InstructionVariant>[];
    final variantIds = <String>{};
    for (final raw in t['variants'] as List? ?? const []) {
      final variant = asJsonMap(raw);
      final variantId = variant['id'];
      final text = variant['instruction'];
      if (variantId is! String || text is! String || text.trim().isEmpty) {
        errors.add('$ctx: every variant needs an "id" and an "instruction"');
        continue;
      }
      if (!variantIds.add(variantId)) {
        errors.add('$ctx: duplicate variant id "$variantId"');
      }
      variants.add(InstructionVariant(id: variantId, instruction: text.trim()));
    }
    return variants;
  }

  List<JsonMap> _refusalRequires(JsonMap t, Set<String> milestoneIds, String ctx) {
    final refusalRequires = <JsonMap>[
      for (final item in switch (t['refusalRequires']) {
        null => const [],
        final List list => list,
        final other => [other],
      })
        item is Map ? asJsonMap(item) : {'milestone': '$item'},
    ];
    for (final requirement in refusalRequires) {
      final milestone = requirement['milestone'];
      if (milestone != null && !milestoneIds.contains(milestone)) {
        errors.add('$ctx: refusalRequires names "$milestone", which is no milestone');
      } else if (milestone == null) {
        SuiteLoader._checkAssertionKind(requirement, '$ctx: refusalRequires', assertionKinds, errors, warnings);
      }
    }
    return refusalRequires;
  }

  List<PartialCreditRule> _partialCredit(JsonMap t, String ctx) {
    final partialCredit = <PartialCreditRule>[];
    for (final r in t['partialCredit'] as List? ?? const []) {
      final rule = PartialCreditRule.fromJson(asJsonMap(r));
      if (rule.credit <= 0 || rule.credit >= 1) {
        errors.add('$ctx: partialCredit.credit must be in (0, 1)');
      }
      partialCredit.add(rule);
    }
    return partialCredit;
  }
}
