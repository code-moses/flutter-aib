/// Regressions: each test failed before its fix.
library;

import 'dart:io';

import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:test/test.dart';

/// Acknowledges every act the same way, like `semantics.scroll`, while the
/// state moves — or, with [stuck], stays where it is.
final class _Scroller implements BenchmarkEnvironment, StateFingerprintProvider {
  _Scroller({this.stuck = false});

  final bool stuck;
  var offset = 0;

  @override
  Future<EnvironmentDescriptor> describe() async => const EnvironmentDescriptor(
    environmentId: 'scroller',
    envelopes: [EnvelopeSpec(key: 'list.scroll', kind: .act)],
  );

  @override
  Future<void> reset(FixtureRef fixture) async => offset = 0;

  @override
  Future<EnvelopeResult> handle(Envelope envelope) async {
    if (!stuck) offset++;
    return EnvelopeResult.ok({'action': 'scrollDown'});
  }

  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) async =>
      FinalStateSnapshot(results: [for (final q in queries) StateQueryResult(query: q.query, count: 0)]);

  @override
  Future<String> stateFingerprint() async => 'offset=$offset';
}

/// The same, without a fingerprint.
final class _BlindScroller implements BenchmarkEnvironment {
  final _inner = _Scroller();

  @override
  Future<EnvironmentDescriptor> describe() => _inner.describe();
  @override
  Future<void> reset(FixtureRef fixture) => _inner.reset(fixture);
  @override
  Future<EnvelopeResult> handle(Envelope envelope) => _inner.handle(envelope);
  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) => _inner.captureFinalState(queries);
}

TaskSpec _task({
  List<SuccessCriterion> criteria = const [SuccessCriterion(type: CriterionTypes.manualReview)],
  List<FollowUp> turns = const [],
  List<PartialCreditRule> partialCredit = const [],
  GroundTruth groundTruth = const GroundTruth(),
}) => TaskSpec(
  id: 't',
  title: 't',
  instruction: 'do it',
  budget: const Budget(maxSteps: 30, maxWallClockSeconds: 60),
  fixture: const FixtureRef(id: 'f', data: {}),
  successCriteria: criteria,
  turns: turns,
  partialCredit: partialCredit,
  groundTruth: groundTruth,
);

EpisodeMeta _meta([String id = 'e']) =>
    EpisodeMeta(runId: 'r', episodeId: id, taskId: 't', agentId: 'a', environmentId: 'env', repetition: 1, startedAt: DateTime.utc(2026));

Future<(EpisodeRunResult, ScriptedAgent)> _scroll(BenchmarkEnvironment environment, int times) async {
  final agent = ScriptedAgent(
    defaultScript: [for (var i = 0; i < times; i++) const Envelope(key: 'list.scroll', kind: .act)],
  );
  final result = await BenchmarkEngine().runEpisode(task: _task(), agent: agent, environment: environment, meta: _meta());
  return (result, agent);
}

EpisodeRecord _record(String taskId, bool success, {List<String> tags = const []}) => EpisodeRecord(
  runId: 'r',
  episodeId: '$taskId-${tags.join()}-$success',
  taskId: taskId,
  agentId: 'a',
  repetition: 1,
  verdict: success ? Verdict.success() : Verdict.failure('x'),
  metrics: {'success': success ? 1 : 0, 'weighted_score': success ? 1 : 0},
  tags: tags,
);

void main() {
  group('the repeat guard checks the state, not only the answer', () {
    test('a repeated act that moves the state is not a loop', () async {
      final environment = _Scroller();
      final (result, agent) = await _scroll(environment, 5);
      expect(result.outcome.reason, TerminationReason.done);
      expect(environment.offset, 5);
      expect(agent.receivedResults.where((r) => r.error?.code == 'no_progress'), isEmpty);
    });

    test('a repeated act that moves nothing still is', () async {
      final (result, agent) = await _scroll(_Scroller(stuck: true), 6);
      expect(result.outcome.reason, TerminationReason.noProgress);
      expect(agent.receivedResults.last.error?.code, 'no_progress');
    });

    test('without a fingerprint an act is never suppressed', () async {
      final (result, agent) = await _scroll(_BlindScroller(), 6);
      expect(result.outcome.reason, TerminationReason.done);
      expect(agent.receivedResults.where((r) => r.error?.code == 'no_progress'), isEmpty);
    });

    test('a fingerprint that fails is recorded, not fatal', () async {
      final result = await BenchmarkEngine().runEpisode(
        task: _task(),
        agent: ScriptedAgent(
          defaultScript: const [Envelope(key: 'list.scroll', kind: .act)],
        ),
        environment: _FailingFingerprint(),
        meta: _meta(),
      );
      expect(result.outcome.reason, TerminationReason.done);
      expect(result.trace.byType(TraceEventTypes.stateFingerprint).first.data, containsPair('error', 'fingerprint unavailable'));
      // Unreadable fingerprints do not break the exchange view.
      expect(result.trace.exchanges(), isNotEmpty);
    });
  });

  group('criteria of one type keep separate details', () {
    test('two rubrics are both recorded and both read back', () async {
      SuccessCriterion rubric(String name) => SuccessCriterion(
        type: CriterionTypes.traceAssertion,
        config: {
          'rubricSpec': {'rubric': name},
          'assertions': [
            {'kind': 'everKey', 'key': 'x'},
          ],
        },
      );
      final verdict = await EpisodeEvaluator().judge(
        EvaluationContext(
          task: _task(criteria: [rubric('task'), rubric('faithfulness_v1')]),
          trace: EpisodeTrace(
            meta: _meta(),
            events: const [
              TraceEvent(seq: 0, tUs: 0, type: TraceEventTypes.episodeEnd, data: {'reason': 'done'}),
            ],
          ),
        ),
      );
      expect(verdict.details.keys, containsAll(['traceAssertion:task', 'traceAssertion:faithfulness_v1']));
      expect(verdict.detailsOfType(CriterionTypes.traceAssertion), hasLength(2));
    });
  });

  group('the loader', () {
    SuiteLoadResult load(String defaults, String task) => SuiteLoader.loadString('''
schema: aib-task/1.0
suite: s
defaults:
$defaults
tasks:
  - id: a
    instruction: x
    fixture: f.json
$task
''', inlineFixtures: false);

    test('defaults.budget can switch the repeat guard off', () {
      final result = load(
        '  budget: {maxSteps: 5, maxWallClockSeconds: 5, maxIdenticalRepeats: null}',
        '    successCriteria: [{type: manualReview}]',
      );
      expect(result.errors, isEmpty);
      expect(result.suite!.tasks.single.budget.maxIdenticalRepeats, isNull);
    });

    test('a budget key nothing reads is warned about', () {
      final result = load('  budget: {maxSteps: 5, maxWallClockSeconds: 5, maxIdenticalRepeat: 3}', '    successCriteria: [{type: manualReview}]');
      expect(result.warnings.join(), contains('maxIdenticalRepeat'));
    });

    test('finalStateMatch needs a finalState, and an expectation needs expect', () {
      final budget = '  budget: {maxSteps: 5, maxWallClockSeconds: 5}';
      expect(load(budget, '    successCriteria: [{type: finalStateMatch}]').errors.join(), contains('requires groundTruth.finalState'));
      expect(
        load(budget, '''
    groundTruth:
      finalState: [{query: db.todos}]
    successCriteria: [{type: finalStateMatch}]''').errors.join(),
        contains('would match any state'),
      );
    });

    test('an artifactRubric names its artifact key or state query, not both', () {
      List<String> errorsFor(String criterion) => load('  budget: {maxSteps: 5, maxWallClockSeconds: 5}', '''
    groundTruth:
      artifactRubric:
        criteria: [{id: a, question: "?"}]
    successCriteria: [$criterion]''').errors;
      expect(errorsFor('{type: artifactRubric}').join(), contains('needs exactly one of "artifactKey"'));
      expect(errorsFor('{type: artifactRubric, artifactKey: genui.render, artifactState: x}').join(), contains('needs exactly one'));
      expect(errorsFor('{type: artifactRubric, artifactState: "surfaces.charts[-1]"}').join(), isNot(contains('needs exactly one')));
    });

    test('fields expected on rows that do not exist do not pass', () {
      const expectation = FinalStateExpectation(query: 'drafts', expectFields: {'Subject': 'Wartung'});
      expect(expectation.mismatch(const StateQueryResult(query: 'drafts', count: 0)), contains('got none'));
    });

    test('a judge pin is matched exactly, not as a substring', () {
      expect(JudgeProvenance.judgeMatchesPin('gpt-4o (judge_v3)', 'gpt-4o'), isTrue);
      expect(JudgeProvenance.judgeMatchesPin('gpt-4o-mini (judge_v3)', 'gpt-4o'), isFalse);
    });
  });

  group('variants', () {
    test('keep the retrieval gold set', () {
      const base = TaskSpec(
        id: 't',
        title: 't',
        instruction: 'x',
        budget: Budget(maxSteps: 1, maxWallClockSeconds: 1),
        fixture: FixtureRef(id: 'f'),
        requiredTools: ['form.open'],
      );
      expect(base.asVariant(const InstructionVariant(id: 'v', instruction: 'y')).requiredTools, ['form.open']);
    });
  });

  group('turns_answered', () {
    test('counts follow-ups a later done closed', () async {
      final result = await BenchmarkEngine().runEpisode(
        task: _task(
          turns: const [
            FollowUp(id: 'f1', instruction: 'and then'),
            FollowUp(id: 'f2', instruction: 'and more'),
          ],
        ),
        agent: _TurnAgent(answer: 1),
        environment: MockEnvironment(),
        meta: _meta(),
      );
      final metrics = MetricsRegistry.builtin().computeAll(
        MetricContext(
          trace: result.trace,
          task: _task(
            turns: const [
              FollowUp(id: 'f1', instruction: 'and then'),
              FollowUp(id: 'f2', instruction: 'and more'),
            ],
          ),
        ),
      );
      // Two follow-ups were issued, one was answered before the budget
      // (the agent's script) ran out.
      expect(metrics['turns_answered'], 1);
    });
  });

  group('resuming', () {
    RunManifest manifest({String model = 'qwen3:8b', String content = 'c1', Map<String, String>? taskContent, String? instructions}) => RunManifest(
      runId: 'r',
      createdAt: DateTime.utc(2026),
      suiteName: 's',
      suiteHash: 'h',
      agents: {
        'hybrid': {
          'agentId': 'hybrid',
          'description': 'prose',
          'metadata': {'model': model},
        },
      },
      environmentId: 'env',
      environmentInstructionsHash: instructions,
      repetitions: 1,
      seed: 1,
      taskOrder: const [],
      platform: const {},
      extra: {RunManifest.suiteContentHashKey: content, RunManifest.suiteTaskContentKey: ?taskContent},
    );

    test('changed instance instructions are refused, and survive a round trip', () {
      expect(manifest(instructions: 'b').incompatibilitiesWith(manifest(instructions: 'a')), [contains('environment instructions')]);
      expect(RunManifest.fromJson(manifest(instructions: 'a').toJson()).environmentInstructionsHash, 'a');
      expect(manifest().toJson()['environment'], isNot(contains('instructionsHash')));
    });

    test('a changed agent under the same id is refused', () {
      expect(manifest(model: 'llama3.1:8b').incompatibilitiesWith(manifest()), [contains('agent "hybrid"')]);
    });

    test('a changed fixture or rubric is refused', () {
      expect(manifest(content: 'c2').incompatibilitiesWith(manifest()), [contains('suite content')]);
    });

    test('resuming a selection of the suite is not a changed suite', () {
      // A filtered re-run (`AIB_TASKS`, `--only`) carries fewer tasks, so the
      // aggregate content hash moves while nothing about the experiment did.
      final whole = manifest(content: 'c-all', taskContent: const {'t1': 'a', 't2': 'b'});
      final selection = manifest(content: 'c-one', taskContent: const {'t2': 'b'});
      expect(selection.incompatibilitiesWith(whole), isEmpty);
    });

    test('an edited task is refused, by name', () {
      final before = manifest(content: 'c-all', taskContent: const {'t1': 'a', 't2': 'b'});
      final after = manifest(content: 'c-all2', taskContent: const {'t1': 'a', 't2': 'b2'});
      expect(after.incompatibilitiesWith(before), [contains('task "t2"')]);
    });

    test('the suite content hash covers inlined fixtures', () {
      TaskSuite suite(Map<String, Object?> data) => TaskSuite(
        name: 's',
        schema: TaskSuite.supportedSchema,
        defaultRepetitions: 1,
        tasks: [
          TaskSpec(
            id: 't',
            title: 't',
            instruction: 'x',
            budget: const Budget(maxSteps: 1, maxWallClockSeconds: 1),
            fixture: FixtureRef(id: 'f', data: data),
          ),
        ],
      );
      expect(suite({'a': 1}).contentHash, isNot(suite({'a': 2}).contentHash));
    });
  });

  group('smaller bugs', () {
    test('the same answer counts distinct questions', () async {
      final agent = ScriptedAgent(
        defaultScript: [
          for (final q in ['a', 'a', 'b', 'c']) Envelope(key: 'state.list', kind: .observe, payload: {'path': 'db.none', 'q': q}),
        ],
      );
      await BenchmarkEngine().runEpisode(task: _task(), agent: agent, environment: MockEnvironment(), meta: _meta());
      final notice = agent.receivedResults.last.error?.message ?? '';
      expect(notice, contains('3 different parameter sets'));
    });

    test('capping keeps the longest prefix that fits', () {
      final payload = {
        'rows': [for (var i = 0; i < 100; i++) 'row-$i'],
      };
      final capped = capPayload(payload, maxBytes: 900);
      final kept = (capped.payload['rows'] as List).length;
      expect(jsonSizeBytes(capped.payload), lessThanOrEqualTo(900));
      // One more row would not fit.
      expect(jsonSizeBytes({...capped.payload, 'rows': payload['rows']!.take(kept + 1).toList(), 'returnedCount': kept + 1}), greaterThan(900));
    });

    test('a price row is not a prefix of a different model', () {
      const table = PriceTable(
        models: {
          'gpt-4o': ModelPrice(promptPerMTok: 2.5, completionPerMTok: 10),
          'claude-sonnet-4-6': ModelPrice(promptPerMTok: 3, completionPerMTok: 15),
        },
      );
      expect(table['gpt-4o-mini'], isNull);
      expect(table['claude-sonnet-4-6-20260214'], isNotNull);
      expect(table['gpt-4o-2024-11-20'], isNotNull);
    });

    test('CSV cells are quoted where they must be', () {
      expect(csvCell('plain'), 'plain');
      expect(csvCell('a,b'), '"a,b"');
      expect(csvCell('say "hi"'), '"say ""hi"""');
    });

    test('conditions and sentences read umlauts', () {
      expect(ConditionExpr.evaluate("Größe == 'XL'", {'Größe': 'XL'}), isTrue);
      expect(firstSentence('Öffnet ein Formular. Übernimmt die Werte.'), 'Öffnet ein Formular.');
    });

    test('an unreadable trace file is skipped and reported', () {
      final dir = Directory.systemTemp.createTempSync('aib_review');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = RunStore(dir)..writeTrace(EpisodeTrace(meta: _meta('good'), events: const []));
      File('${dir.path}/traces/broken.jsonl').writeAsStringSync('{"type":');
      final unreadable = <String>[];
      final traces = store.readTraces(onUnreadable: (path, _) => unreadable.add(path));
      expect(traces, hasLength(1));
      expect(unreadable.single, endsWith('broken.jsonl'));
    });

    test('the evidence digest counts what it omitted', () {
      final events = <TraceEvent>[];
      for (var i = 0; i < 30; i++) {
        events
          ..add(TraceEvent(seq: events.length, tUs: i, type: TraceEventTypes.agentEnvelope, data: {'seq': i, 'key': 'k$i', 'kind': 'observe'}))
          ..add(TraceEvent(seq: events.length + 1, tUs: i, type: TraceEventTypes.envResult, data: {'seq': i, 'status': 'ok'}));
      }
      final actions = episodeEvidence(EpisodeTrace(meta: _meta(), events: events), maxActions: 10)['actions']! as List;
      final kept = actions.where((a) => !'${(a as Map)['did']}'.startsWith('…'));
      final marker = actions.firstWhere((a) => '${(a as Map)['did']}'.startsWith('…'));
      expect(kept.length + int.parse('${(marker as Map)['did']}'.split(' ')[1]), 30);
    });
  });

  group('partial credit never lowers a score', () {
    test('the criteria score stands when it is higher', () async {
      final verdict = await EpisodeEvaluator().judge(
        EvaluationContext(
          task: _task(
            criteria: const [
              SuccessCriterion(
                type: CriterionTypes.traceAssertion,
                weight: 4,
                config: {
                  'assertions': [
                    {'kind': 'everKey', 'key': 'x'},
                  ],
                },
              ),
              SuccessCriterion(
                type: CriterionTypes.traceAssertion,
                config: {
                  'assertions': [
                    {'kind': 'everKey', 'key': 'missing'},
                  ],
                },
              ),
            ],
            partialCredit: const [PartialCreditRule(condition: 'true', credit: 0.3, label: 'low')],
          ),
          trace: EpisodeTrace(
            meta: _meta(),
            events: const [
              TraceEvent(seq: 0, tUs: 0, type: TraceEventTypes.agentEnvelope, data: {'seq': 0, 'key': 'x', 'kind': 'observe'}),
              TraceEvent(seq: 1, tUs: 1, type: TraceEventTypes.episodeEnd, data: {'reason': 'done'}),
            ],
          ),
        ),
      );
      expect(verdict.score, closeTo(0.8, 1e-9));
      expect(verdict.label, isNot('low'));
    });
  });

  group('statistics', () {
    test('a suite-level interval accounts for clustered tasks', () {
      // Two tasks, one always solved, one never: 50% with n=20 episodes, but
      // only two independent questions.
      final records = [for (var i = 0; i < 10; i++) _record('easy', true), for (var i = 0; i < 10; i++) _record('hard', false)];
      final star = Aggregator().aggregate(records).firstWhere((r) => r.taskId == '*' && r.metric == 'success_rate');
      final wilson = Stats.wilson(10, 20);
      expect(star.ciHigh! - star.ciLow!, greaterThan(wilson.high - wilson.low));
    });

    test('pass^k does not pool a task with its variant', () {
      final records = [
        for (var i = 0; i < 3; i++) _record('t', true),
        for (var i = 0; i < 3; i++) _record('t', false, tags: ['variant:v']),
      ];
      final rows = Aggregator().aggregate(records);
      final base = rows.firstWhere((r) => r.taskId == 't' && r.metric == 'pass_3');
      expect(base.mean, 1);
      expect(rows.where((r) => r.taskId == 't#variant:v' && r.metric == 'pass_1'), isNotEmpty);
    });

    test("Cohen's κ carries an interval", () {
      EpisodeRecord r(String id, bool success) => EpisodeRecord(
        runId: 'r',
        episodeId: id,
        taskId: 't',
        agentId: 'a',
        repetition: 1,
        verdict: success ? Verdict.success() : Verdict.failure('x'),
        metrics: const {},
      );
      final calibration = JudgeCalibration.compare(
        [for (var i = 0; i < 20; i++) r('e$i', i.isEven)],
        {for (var i = 0; i < 20; i++) 'e$i': (i.isEven || i % 7 == 0) ? HumanLabel.success : HumanLabel.failure},
      );
      expect(calibration.kappaCi.low, lessThan(calibration.kappa));
      expect(calibration.kappaCi.high, greaterThanOrEqualTo(calibration.kappa));
    });
  });

  group('comparing two arms of a sweep', () {
    EpisodeRecord record(String agentId, String taskId, double score) => EpisodeRecord(
      runId: 'r',
      episodeId: '$taskId-$agentId',
      taskId: taskId,
      agentId: agentId,
      repetition: 1,
      verdict: const Verdict(type: .success, score: 1, label: 'ok'),
      metrics: {'weighted_score': score},
    );

    test('runs whose single agent has a different id still compare', () {
      // `hybrid` vs `prepared` is the arm being varied; pairing by agent id
      // produced an empty table, which reads like "no difference".
      final rows = RunComparator(
        metrics: const ['weighted_score'],
      ).compare([record('hybrid', 't1', 0.4), record('hybrid', 't2', 0.6)], [record('prepared', 't1', 0.8), record('prepared', 't2', 1.0)]);
      final suite = rows.singleWhere((r) => r.taskId == '*');
      expect(suite.agentId, RunComparator.pairedAgentId);
      expect(suite.meanA, closeTo(0.5, 1e-9));
      expect(suite.meanB, closeTo(0.9, 1e-9));
    });

    test('two agents in one run are still paired by id', () {
      final rows = RunComparator(
        metrics: const ['weighted_score'],
      ).compare([record('hybrid', 't1', 0.4), record('intent', 't1', 0.2)], [record('hybrid', 't1', 0.8), record('intent', 't1', 0.6)]);
      expect(rows.map((r) => r.agentId).toSet(), containsAll(<String>{'hybrid', 'intent'}));
    });
  });

  group('prompt robustness', () {
    test('compares a run\'s base episodes with its variant episodes', () {
      final records = [
        for (var i = 0; i < 3; i++) _record('t', true),
        for (var i = 0; i < 3; i++) _record('t', false, tags: ['variant:v']),
      ];
      final row = RunComparator.promptRobustness(records, 'a', variant: 'v', iterations: 200)!;
      expect(row.meanA, 1);
      expect(row.meanB, 0);
      expect(row.diff, -1);
    });
  });
}

final class _FailingFingerprint extends _Scroller {
  @override
  Future<String> stateFingerprint() async => throw StateError('no state');
}

/// Answers the task, then the first [answer] follow-ups, then stops acting on
/// the follow-ups it gets by aborting.
final class _TurnAgent implements BenchmarkAgent {
  _TurnAgent({required this.answer});

  final int answer;
  var _dones = 0;

  @override
  AgentManifest get manifest => const AgentManifest(agentId: 'turns');

  @override
  Future<void> startEpisode(TaskSpec task, EnvironmentDescriptor env) async {
    _dones = 0;
  }

  @override
  Future<Envelope> next(EnvelopeResult? lastResult, BudgetStatus budget) async {
    if (_dones <= answer) {
      _dones++;
      return Envelope.done(summary: 'done $_dones');
    }
    return Envelope.abort(reason: 'no more');
  }

  @override
  Future<void> endEpisode(EpisodeOutcome outcome) async {}
}
