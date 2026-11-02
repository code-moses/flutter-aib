import 'dart:io';

import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

/// P6 — judge provenance (§5.1 `judgeModel: pinned`, §5.3).
///
/// SPA-Bench names the agent/judge model overlap as a threat to validity.
/// The framework's job is not to forbid it but to make it impossible to
/// overlook, and to make "which judge produced these numbers?" answerable
/// from the run directory alone.

const _rubric = {
  'rubric': 'dashboard_v1',
  'criteria': [
    {'id': 'complete', 'question': 'Is it complete?', 'weight': 1},
  ],
};

TaskSpec _genuiTask({String? judgeModel}) => TaskSpec(
  id: 'dash',
  title: 'dash',
  instruction: 'build a dashboard',
  budget: const Budget(maxSteps: 5, maxWallClockSeconds: 30),
  fixture: const FixtureRef(id: 'f', data: {}),
  successCriteria: [
    SuccessCriterion(type: CriterionTypes.artifactRubric, config: {'rubricSpec': _rubric, 'artifactKey': 'genui.render', 'judgeModel': ?judgeModel}),
  ],
);

TaskSuite _suite({String? judgeModel}) => TaskSuite(
  name: 'genui',
  schema: TaskSuite.supportedSchema,
  defaultRepetitions: 1,
  tasks: [_genuiTask(judgeModel: judgeModel)],
);

/// Deterministic judge standing in for the LLM one.
final class _FakeJudge implements ArtifactJudge {
  _FakeJudge(this.judgeId);

  @override
  final String judgeId;
  int calls = 0;

  @override
  Future<JudgeAnswer> judge(JudgeRequest request) async {
    calls++;
    return JudgeAnswer(answers: {for (final c in request.rubric.criteria) c.id: true});
  }
}

EpisodeTrace _traceWithSurface() {
  var seq = 0;
  TraceEvent event(String type, JsonMap data) => TraceEvent(seq: seq++, tUs: seq, type: type, data: data);
  return EpisodeTrace(
    meta: EpisodeMeta(
      runId: 'r',
      episodeId: 'e',
      taskId: 'dash',
      agentId: 'genui',
      environmentId: 'mock',
      repetition: 1,
      startedAt: DateTime.utc(2026),
    ),
    events: [
      event(TraceEventTypes.agentEnvelope, {
        'seq': 0,
        'key': 'genui.render',
        'kind': 'act',
        'payload': {
          'surface': {
            'items': ['one'],
          },
        },
      }),
      event(TraceEventTypes.envResult, {'seq': 0, 'status': 'ok'}),
      event(TraceEventTypes.episodeEnd, {'reason': 'done', 'wallClockMs': 5}),
    ],
  );
}

void main() {
  _d5();
  group('pin enforcement', () {
    Future<Verdict> judgeWith(String judgeId, {String? pin}) =>
        EpisodeEvaluator(evaluators: EpisodeEvaluator.defaultEvaluators(judge: _FakeJudge(judgeId))).judge(
          EvaluationContext(
            task: _genuiTask(judgeModel: pin),
            trace: _traceWithSurface(),
          ),
        );

    test('the pinned judge is accepted', () async {
      final verdict = await judgeWith('claude-sonnet-4-6 (judge_v1)', pin: 'claude-sonnet-4-6');
      expect(verdict.type, VerdictType.success);
    });

    test('a different judge is refused loudly instead of scoring', () async {
      expect(
        () => judgeWith('gpt-4o (judge_v1)', pin: 'claude-sonnet-4-6'),
        throwsA(
          isA<JudgePinMismatch>().having((e) => e.expected, 'expected', 'claude-sonnet-4-6').having((e) => e.actual, 'actual', contains('gpt-4o')),
        ),
        reason:
            'a pin mismatch is an operator error; silently reporting '
            'numbers from an unintended model is what pinning prevents',
      );
    });

    test('an unpinned criterion accepts any judge', () async {
      expect((await judgeWith('whatever')).type, VerdictType.success);
    });

    test('the spec placeholder "pinned" does not pin a concrete model', () async {
      expect((await judgeWith('whatever', pin: 'pinned')).type, VerdictType.success);
    });
  });

  group('JudgeProvenance.forSuite', () {
    test('collects pin, k and rubric hashes', () {
      final provenance = JudgeProvenance.forSuite(_suite(judgeModel: 'claude-sonnet-4-6'), judgeId: 'claude-sonnet-4-6 (judge_v1)', k: 3);
      expect(provenance.pinnedModel, 'claude-sonnet-4-6');
      expect(provenance.k, 3);
      expect(provenance.rubrics.keys, ['dashboard_v1']);
      expect(provenance.rubrics['dashboard_v1'], isNotEmpty);
    });

    test('an edited rubric changes the hash', () {
      final before = JudgeProvenance.forSuite(_suite(), judgeId: 'j', k: 3).rubrics['dashboard_v1'];

      final edited = TaskSuite(
        name: 'genui',
        schema: TaskSuite.supportedSchema,
        defaultRepetitions: 1,
        tasks: [
          TaskSpec(
            id: 'dash',
            title: 'dash',
            instruction: 'build a dashboard',
            budget: const Budget(maxSteps: 5, maxWallClockSeconds: 30),
            fixture: const FixtureRef(id: 'f', data: {}),
            successCriteria: [
              SuccessCriterion(
                type: CriterionTypes.artifactRubric,
                config: {
                  'rubricSpec': {
                    'rubric': 'dashboard_v1',
                    'criteria': [
                      {'id': 'complete', 'question': 'Is it REALLY complete?', 'weight': 1},
                    ],
                  },
                },
              ),
            ],
          ),
        ],
      );
      expect(
        JudgeProvenance.forSuite(edited, judgeId: 'j', k: 3).rubrics['dashboard_v1'],
        isNot(before),
        reason: 'editing a rubric in place must be detectable',
      );
    });
  });

  group('verdicts.json envelope', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('aib_judge'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('round-trips the judge next to the verdicts', () {
      final store = RunStore(dir);
      final provenance = JudgeProvenance(
        judgeId: 'claude-sonnet-4-6 (judge_v1)',
        k: 3,
        pinnedModel: 'claude-sonnet-4-6',
        rubrics: const {'dashboard_v1': 'abc123'},
        evaluatedAt: DateTime.utc(2026, 8, 6),
      );
      store.writeVerdicts({'e1': Verdict.success()}, judge: provenance);

      expect(store.readVerdicts().keys, ['e1']);
      final read = store.readJudgeProvenance()!;
      expect(read.judgeId, provenance.judgeId);
      expect(read.k, 3);
      expect(read.pinnedModel, 'claude-sonnet-4-6');
      expect(read.rubrics, {'dashboard_v1': 'abc123'});
      expect(read.evaluatedAt, DateTime.utc(2026, 8, 6));
    });

    test('runs without a judge stay judge-free', () {
      final store = RunStore(dir);
      store.writeVerdicts({'e1': Verdict.success()});
      expect(store.readJudgeProvenance(), isNull);
      expect(store.readVerdicts(), hasLength(1));
    });
  });

  group('report surfaces the overlap', () {
    RunReportData data({required String judgeId, required String agentModel}) => RunReportData(
      manifest: RunManifest(
        runId: 'r',
        createdAt: DateTime.utc(2026),
        suiteName: 'genui',
        suiteHash: 'h',
        agents: {
          'genui-agent': {
            'agentId': 'genui-agent',
            'metadata': {'model': agentModel},
          },
        },
        environmentId: 'mock',
        repetitions: 1,
        seed: 42,
        taskOrder: const ['dash'],
        platform: const {},
      ),
      records: const [],
      aggregates: const [],
      judge: JudgeProvenance(judgeId: judgeId, k: 3),
    );

    test('names the agents whose model is also the judge', () {
      final overlapping = data(judgeId: 'claude-sonnet-4-6 (judge_v1)', agentModel: 'claude-sonnet-4-6');
      expect(overlapping.judgeAgentOverlap, ['genui-agent']);
      expect(MarkdownReporter().render(overlapping), contains('also the backbone of genui-agent'));
      expect(HtmlReporter().render(overlapping), contains('⚠️'));
    });

    test('stays quiet when judge and agent differ', () {
      final independent = data(judgeId: 'gpt-4o (judge_v1)', agentModel: 'claude-sonnet-4-6');
      expect(independent.judgeAgentOverlap, isEmpty);
      final report = MarkdownReporter().render(independent);
      expect(report, contains('## Judge'));
      expect(report, isNot(contains('also the backbone')));
    });
  });

  test('the suite loader nudges towards pinning', () {
    const yaml = '''
suite: genui
schema: aib-task/1.0
defaults:
  repetitions: 1
  budget: { maxSteps: 5, maxWallClockSeconds: 30 }
  fixture: seed.json
tasks:
  - id: dash
    instruction: build a dashboard
    groundTruth:
      artifactRubric:
        criteria:
          - id: is_a_dashboard
            question: Is the artifact a dashboard?
    successCriteria:
      - type: artifactRubric
        artifactKey: meta.done
        weight: 1.0
''';
    final unpinned = SuiteLoader.loadString(yaml, inlineFixtures: false);
    expect(unpinned.errors, isEmpty);
    expect(unpinned.warnings.join(), contains('without a pinned judgeModel'));

    final pinned = SuiteLoader.loadString(
      yaml.replaceFirst('        weight: 1.0', '        weight: 1.0\n        judgeModel: claude-sonnet-4-6'),
      inlineFixtures: false,
    );
    expect(pinned.warnings, isEmpty);
  });
}

void _d5() {
  group('judge spend (D5)', () {
    test('sums what a rubric recorded in one episode', () {
      final spend = JudgeSpend.fromVerdict(
        const Verdict(
          type: .success,
          score: 1,
          details: {
            'artifactRubric': {'judgeCalls': 3, 'judgeTokensPrompt': 1200, 'judgeTokensCompletion': 90, 'judgeLatencyMs': 4100},
          },
        ),
      );
      expect(spend.calls, 3);
      expect(spend.tokensPrompt, 1200);
      expect(spend.isEmpty, isFalse);
    });

    test('sums every rubric of an episode, not the last one written', () {
      final spend = JudgeSpend.fromVerdict(
        const Verdict(
          type: .success,
          score: 1,
          details: {
            'artifactRubric:task': {'judgeCalls': 3, 'judgeTokensPrompt': 100},
            'artifactRubric:faithfulness_v1': {'judgeCalls': 3, 'judgeTokensPrompt': 50},
          },
        ),
      );
      expect(spend.calls, 6);
      expect(spend.tokensPrompt, 150);
    });

    test('a verdict with no rubric costs nothing', () {
      expect(
        JudgeSpend.fromVerdict(
          const Verdict(
            type: .success,
            score: 1,
            details: {
              'finalStateMatch': {'score': 1.0},
            },
          ),
        ).isEmpty,
        isTrue,
      );
    });

    test('spend adds up across episodes and survives the manifest', () {
      const a = JudgeSpend(calls: 3, tokensPrompt: 100, latencyMs: 10);
      const b = JudgeSpend(calls: 3, tokensPrompt: 50, tokensCompletion: 7);
      final total = a.plus(b);
      expect(total.calls, 6);
      expect(total.tokensPrompt, 150);
      expect(JudgeSpend.fromJson(total.toJson()).tokensCompletion, 7);
    });

    test('provenance carries it only when a judge reported it', () {
      const bare = JudgeProvenance(judgeId: 'j', k: 3);
      expect(bare.toJson().containsKey('spend'), isFalse);
      const withSpend = JudgeProvenance(judgeId: 'j', k: 3, spend: JudgeSpend(calls: 3, tokensPrompt: 10));
      expect(JudgeProvenance.fromJson(withSpend.toJson()).spend!.tokensPrompt, 10);
    });
  });
}
