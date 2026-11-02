import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

/// Deterministic judge for framework validation (§10): scripted answers per
/// call, so the k-majority logic is testable with known expectations.
final class _ScriptedJudge implements ArtifactJudge {
  _ScriptedJudge(this.answersPerCall);

  final List<Map<String, bool>> answersPerCall;
  final List<JudgeRequest> requests = [];
  int _call = 0;

  @override
  String get judgeId => 'scripted-judge';

  @override
  Future<JudgeAnswer> judge(JudgeRequest request) async {
    requests.add(request);
    return JudgeAnswer(answers: answersPerCall[_call++ % answersPerCall.length]);
  }
}

const _rubricJson = {
  'rubric': 'dashboard_v1',
  'criteria': [
    {'id': 'complete', 'question': 'Lists all open tasks?', 'weight': 2},
    {'id': 'grouped', 'question': 'Grouped by due date?'},
  ],
};

EpisodeTrace _traceWithArtifact({JsonMap? surface}) {
  var seq = 0;
  TraceEvent event(String type, JsonMap data) => TraceEvent(seq: seq++, tUs: seq, type: type, data: data);
  return EpisodeTrace(
    meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'genui', environmentId: 'env', repetition: 1, startedAt: DateTime.utc(2026)),
    events: [
      event(TraceEventTypes.episodeStart, {}),
      if (surface != null) ...[
        event(TraceEventTypes.agentEnvelope, {
          'seq': 0,
          'key': 'genui.render',
          'kind': 'act',
          'payload': {'surface': surface},
        }),
        event(TraceEventTypes.envResult, {'seq': 0, 'status': 'ok', 'payload': {}}),
      ],
      event(TraceEventTypes.episodeEnd, {'reason': 'done', 'wallClockMs': 5}),
    ],
  );
}

TaskSpec _task() => TaskSpec(
  id: 't',
  title: 't',
  instruction: 'Create a dashboard.',
  budget: const Budget(maxSteps: 5, maxWallClockSeconds: 10),
  fixture: const FixtureRef(id: 'f', data: {}),
  successCriteria: const [
    SuccessCriterion(type: CriterionTypes.artifactRubric, config: {'rubricSpec': _rubricJson, 'artifactKey': 'genui.render'}),
  ],
);

void main() {
  const surface = {'type': 'surface', 'sections': <Object?>[]};

  Future<Verdict> judgeWith(ArtifactJudge? judge, {JsonMap? artifactSurface = surface}) {
    final evaluator = EpisodeEvaluator(
      evaluators: {
        ...EpisodeEvaluator.defaultEvaluators(),
        CriterionTypes.artifactRubric: ArtifactRubricEvaluator(judge: judge, repetitions: 3),
      },
    );
    return evaluator.judge(
      EvaluationContext(
        task: _task(),
        trace: _traceWithArtifact(surface: artifactSurface),
      ),
    );
  }

  test('unanimous judge -> success; artifact and rubric reach the judge', () async {
    final judge = _ScriptedJudge([
      {'complete': true, 'grouped': true},
    ]);
    final verdict = await judgeWith(judge);
    expect(verdict.type, VerdictType.success);
    expect(judge.requests, hasLength(3), reason: 'k=3 repetitions');
    expect(judge.requests.first.artifact, surface);
    expect(judge.requests.first.rubric.name, 'dashboard_v1');
    expect(judge.requests.first.taskInstruction, 'Create a dashboard.');
  });

  test('majority vote decides per criterion (2/3 wins, 1/3 loses)', () async {
    final judge = _ScriptedJudge([
      {'complete': true, 'grouped': true},
      {'complete': true, 'grouped': false},
      {'complete': false, 'grouped': false},
    ]);
    final verdict = await judgeWith(judge);
    // complete (weight 2) passes 2/3, grouped fails 1/3 -> 2/3 of weight.
    expect(verdict.type, VerdictType.partial);
    expect(verdict.score, closeTo(2 / 3, 1e-9));
  });

  test('no artifact in trace -> failure with reason', () async {
    final verdict = await judgeWith(
      _ScriptedJudge([
        {'complete': true, 'grouped': true},
      ]),
      artifactSurface: null,
    );
    expect(verdict.type, VerdictType.failure);
    expect(verdict.reason, contains('no artifact'));
  });

  test('an empty artifact is not put to the judge', () async {
    for (final empty in [
      <String, Object?>{},
      {'summary': '  ', 'items': <Object?>[]},
    ]) {
      final judge = _ScriptedJudge([
        {'complete': true, 'grouped': true},
      ]);
      final verdict = await judgeWith(judge, artifactSurface: empty);
      expect(verdict.type, VerdictType.failure, reason: '$empty');
      expect(judge.requests, isEmpty);
    }
  });

  test('missing judge -> failure telling the user to configure one', () async {
    final verdict = await judgeWith(null);
    expect(verdict.type, VerdictType.failure);
    expect(verdict.reason, contains('requires a judge'));
  });

  test('extractArtifact picks the LAST rendered surface', () {
    final trace = EpisodeTrace(
      meta: _traceWithArtifact().meta,
      events: [
        for (final (i, title) in ['first', 'second'].indexed) ...[
          TraceEvent(
            seq: i * 2,
            tUs: i,
            type: TraceEventTypes.agentEnvelope,
            data: {
              'seq': i,
              'key': 'genui.render',
              'kind': 'act',
              'payload': {
                'surface': {'title': title},
              },
            },
          ),
          TraceEvent(seq: i * 2 + 1, tUs: i, type: TraceEventTypes.envResult, data: {'seq': i, 'status': 'ok', 'payload': {}}),
        ],
      ],
    );
    expect(ArtifactRubricEvaluator.extractArtifact(trace, artifactKeys: const ['genui.render']), {'title': 'second'});
  });

  test('extractArtifact reads any of several keys', () {
    EpisodeTrace traceEndingIn(String key) => EpisodeTrace(
      meta: _traceWithArtifact().meta,
      events: [
        TraceEvent(
          seq: 0,
          tUs: 0,
          type: TraceEventTypes.agentEnvelope,
          data: {
            'seq': 0,
            'key': key,
            'kind': 'act',
            'payload': {'reason': 'Das ist nicht möglich'},
          },
        ),
      ],
    );

    const keys = ['meta.done', 'meta.abort'];
    expect(ArtifactRubricEvaluator.extractArtifact(traceEndingIn('meta.abort'), artifactKeys: keys), {'reason': 'Das ist nicht möglich'});
    expect(ArtifactRubricEvaluator.extractArtifact(traceEndingIn('meta.done'), artifactKeys: keys), {'reason': 'Das ist nicht möglich'});
    // Only the keys named.
    expect(ArtifactRubricEvaluator.extractArtifact(traceEndingIn('meta.abort'), artifactKeys: const ['meta.done']), isNull);
  });

  test('artifactKey is one key or a list of them', () {
    // No default: which envelope carries an artifact is the suite's to say.
    expect(ArtifactRubricEvaluator.artifactKeysOf(const {}), isEmpty);
    expect(ArtifactRubricEvaluator.artifactKeysOf(const {'artifactKey': 'meta.done'}), ['meta.done']);
    expect(
      ArtifactRubricEvaluator.artifactKeysOf(const {
        'artifactKey': ['meta.done', 'meta.abort'],
      }),
      ['meta.done', 'meta.abort'],
    );
  });

  test('the missing-artifact reason names the keys it looked for', () async {
    final verdict = await judgeWith(
      _ScriptedJudge([
        {'complete': true, 'grouped': true},
      ]),
      artifactSurface: null,
    );
    expect(verdict.reason, contains('genui.render'));
  });

  group('artifactState', () {
    const query = 'surfaces.charts[-1]';
    final task = TaskSpec(
      id: 't',
      title: 't',
      instruction: 'Show a chart.',
      budget: const Budget(maxSteps: 5, maxWallClockSeconds: 10),
      fixture: const FixtureRef(id: 'f', data: {}),
      groundTruth: const GroundTruth(mustNotChange: ['drafts']),
      successCriteria: const [
        SuccessCriterion(type: CriterionTypes.artifactRubric, config: {'rubricSpec': _rubricJson, 'artifactState': query}),
      ],
    );

    EpisodeTrace traceWithState(List<JsonMap> rows) {
      var seq = 0;
      TraceEvent event(String type, JsonMap data) => TraceEvent(seq: seq++, tUs: seq, type: type, data: data);
      return EpisodeTrace(
        meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'a', environmentId: 'env', repetition: 1, startedAt: DateTime.utc(2026)),
        events: [
          event(TraceEventTypes.episodeStart, {}),
          event(TraceEventTypes.episodeEnd, {'reason': 'done', 'wallClockMs': 5}),
          event(
            TraceEventTypes.finalState,
            FinalStateSnapshot(
              results: [StateQueryResult(query: query, count: rows.length, items: rows)],
            ).toJson(),
          ),
        ],
      );
    }

    Future<Verdict> judge(ArtifactJudge judge, List<JsonMap> rows) => EpisodeEvaluator(
      evaluators: {
        ...EpisodeEvaluator.defaultEvaluators(),
        CriterionTypes.artifactRubric: ArtifactRubricEvaluator(judge: judge, repetitions: 1),
      },
    ).judge(EvaluationContext(task: task, trace: traceWithState(rows)));

    test('the engine captures the query alongside the ground truth', () {
      expect(task.finalStateQueries.map((q) => q.query), ['drafts', query]);
    });

    test('judges the rows the query selected, without any envelope', () async {
      final scripted = _ScriptedJudge([
        {'complete': true, 'grouped': true},
      ]);
      final verdict = await judge(scripted, const [
        {
          'createSurface': {'surfaceId': 's'},
        },
      ]);
      expect(verdict.score, 1);
      expect(scripted.requests.single.artifact, {
        'query': query,
        'items': [
          {
            'createSurface': {'surfaceId': 's'},
          },
        ],
      });
    });

    test('nothing selected scores 0 and names the query', () async {
      final verdict = await judge(_ScriptedJudge([{}]), const []);
      expect(verdict.score, 0);
      expect(verdict.reason, contains(query));
    });
  });
}
