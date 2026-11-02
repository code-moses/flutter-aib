import 'package:aib_agents/aib_agents.dart';
import 'package:aib_agents/testing.dart';
import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

const _rubric = RubricSpec(
  name: 'dashboard_v1',
  criteria: [
    RubricCriterion(id: 'complete', question: 'All open tasks listed?', weight: 2),
    RubricCriterion(id: 'grouped', question: 'Grouped by due date?'),
  ],
);

void main() {
  group('GenUiAgent', () {
    test('agent.maxCompletionTokens wins over the larger default', () {
      int limit(JsonMap agent) => AgentProfile.build('genui', {'agent': agent}, client: FakeLlmClient()).config.maxCompletionTokens;
      expect(limit({}), GenUiAgent.defaultMaxCompletionTokens);
      expect(limit({'maxCompletionTokens': 16000}), 16000);
      expect(limit({'maxCompletionTokens': 2048}), 2048);
      expect(GenUiAgent(client: FakeLlmClient()).config.maxCompletionTokens, GenUiAgent.defaultMaxCompletionTokens);
    });

    test('bootstraps with data.context and maps render_ui', () {
      final agent = GenUiAgent(client: FakeLlmClient());
      expect(agent.bootstrapEnvelope()!.key, 'data.context');
      expect(agent.manifest.version, 'genui_v2');

      const messages = [
        {
          'version': 'v0.9',
          'createSurface': {'surfaceId': 's', 'catalogId': 'c'},
        },
      ];
      final render = agent.mapToolCall(const LlmToolCall(id: '1', name: 'render_ui', arguments: {'messages': messages}));
      expect(render!.key, 'genui.render');
      expect(render.kind, EnvelopeKind.act);
      expect(render.payload['messages'], messages);

      expect(agent.mapToolCall(const LlmToolCall(id: '2', name: 'observe_data'))!.key, 'data.context');
      // The catalog is an observation, not prompt text: an episode that
      // renders nothing should not pay for it.
      expect(agent.mapToolCall(const LlmToolCall(id: '3', name: 'observe_ui_catalog'))!.key, 'genui.catalog');
    });
  });

  group('LlmJudge', () {
    JudgeRequest request() =>
        const JudgeRequest(taskInstruction: 'Create a dashboard.', artifact: {'type': 'surface', 'sections': <Object?>[]}, rubric: _rubric);

    test('asks with a forced submit_judgement tool and parses answers', () async {
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([
            (
              'submit_judgement',
              {
                'answers': {'complete': true, 'grouped': false},
                'rationale': 'only partially grouped',
              },
            ),
          ]),
        ],
      );
      final answer = await LlmJudge(client: llm).judge(request());
      expect(answer.answers, {'complete': true, 'grouped': false});
      expect(answer.rationale, contains('grouped'));

      final judgeRequest = llm.requests.single;
      expect(judgeRequest.temperature, 0);
      expect(judgeRequest.tools.map((t) => t.name), ['submit_judgement']);
      // Rubric ids become required schema properties (structured output).
      final schema = asJsonMap(asJsonMap(judgeRequest.tools.single.parameters['properties'])['answers']);
      expect(asJsonMap(schema['properties']).keys, ['complete', 'grouped']);
      // The artifact and the questions reach the judge, and every question
      // is spelled out with the key its answer belongs under.
      expect(judgeRequest.messages.last.content, contains('"surface"'));
      expect(judgeRequest.messages.last.content, contains('key "complete": All open tasks listed?'));
    });

    test('missing criteria in the answer default to failed (conservative)', () async {
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([
            (
              'submit_judgement',
              {
                'answers': {'complete': true},
              },
            ),
          ]),
        ],
      );
      final answer = await LlmJudge(client: llm).judge(request());
      expect(answer.answers, {'complete': true, 'grouped': false});
    });

    test('loose boolean answers ("yes"/"true"/1) are read as yes', () async {
      // gpt-oss answers a boolean schema with "yes"/"no"; reading only
      // `== true` would silently fail every criterion and produce a report
      // of zeros that looks like a judgement.
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([
            (
              'submit_judgement',
              {
                'answers': {'complete': 'yes', 'grouped': 'no'},
              },
            ),
          ]),
          FakeLlmClient.calls([
            (
              'submit_judgement',
              {
                'answers': {'complete': 1, 'grouped': 'TRUE'},
              },
            ),
          ]),
        ],
      );
      final judge = LlmJudge(client: llm);
      expect((await judge.judge(request())).answers, {'complete': true, 'grouped': false});
      expect((await judge.judge(request())).answers, {'complete': true, 'grouped': true});
    });

    test('an answer under an unknown key is reported, not read as a no', () async {
      // gpt-oss did exactly this against a single-criterion rubric: it voted
      // yes under the *rubric's name* instead of the criterion id. Read as a
      // missing answer, a correct answer scored 0 while the rationale said the
      // opposite — a parsing artefact that looks like a judgement. The vote
      // still fails (the question asked was not answered), but it says why.
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([
            (
              'submit_judgement',
              {
                'answers': {'dashboard_v1': true},
                'rationale': 'the surface lists everything',
              },
            ),
          ]),
        ],
      );
      final answer = await LlmJudge(client: llm).judge(request());

      expect(answer.answers, {'complete': false, 'grouped': false});
      expect(answer.rationale, contains('unknown key(s) dashboard_v1'));
      expect(answer.rationale, contains('the surface lists everything'));
    });

    test('an unstructured answer is asked for once more', () async {
      final llm = FakeLlmClient(
        responses: [
          const LlmResponse(text: 'looks fine!'),
          FakeLlmClient.calls([
            (
              'submit_judgement',
              {
                'answers': {'complete': true, 'grouped': false},
              },
            ),
          ]),
        ],
      );
      final answer = await LlmJudge(client: llm).judge(request());
      expect(llm.requests, hasLength(2));
      expect(answer.answers, {'complete': true, 'grouped': false});
      // Both calls are spend.
      expect(answer.tokensPrompt, 200);
    });

    test('still unstructured after the second request fails every criterion', () async {
      final llm = FakeLlmClient(
        responses: [
          const LlmResponse(text: 'looks fine!'),
          const LlmResponse(text: 'really, fine!'),
        ],
      );
      final answer = await LlmJudge(client: llm).judge(request());
      expect(answer.answers, isEmpty);
      expect(answer.rationale, contains('no structured answer'));
    });

    test('full pipeline: rubric evaluator + LlmJudge over a real trace shape', () async {
      // 3 judge calls (k=3), 2 vote complete=true, all vote grouped=true.
      final llm = FakeLlmClient(
        responses: [
          for (final complete in [true, true, false])
            FakeLlmClient.calls([
              (
                'submit_judgement',
                {
                  'answers': {'complete': complete, 'grouped': true},
                },
              ),
            ]),
        ],
      );
      final evaluator = ArtifactRubricEvaluator(judge: LlmJudge(client: llm), repetitions: 3);
      final task = TaskSpec(
        id: 't',
        title: 't',
        instruction: 'dashboard',
        budget: const Budget(maxSteps: 5, maxWallClockSeconds: 10),
        fixture: const FixtureRef(id: 'f', data: {}),
        successCriteria: [
          SuccessCriterion(type: CriterionTypes.artifactRubric, config: {'rubricSpec': _rubric.toJson(), 'artifactKey': 'genui.render'}),
        ],
      );
      final trace = EpisodeTrace(
        meta: EpisodeMeta(
          runId: 'r',
          episodeId: 'e',
          taskId: 't',
          agentId: 'genui',
          environmentId: 'env',
          repetition: 1,
          startedAt: DateTime.utc(2026),
        ),
        events: [
          TraceEvent(
            seq: 0,
            tUs: 0,
            type: TraceEventTypes.agentEnvelope,
            data: {
              'seq': 0,
              'key': 'genui.render',
              'kind': 'act',
              'payload': {
                'surface': {'type': 'surface', 'sections': <Object?>[]},
              },
            },
          ),
          TraceEvent(seq: 1, tUs: 1, type: TraceEventTypes.envResult, data: {'seq': 0, 'status': 'ok', 'payload': {}}),
          TraceEvent(seq: 2, tUs: 2, type: TraceEventTypes.episodeEnd, data: {'reason': 'done', 'wallClockMs': 3}),
        ],
      );
      final outcome = await evaluator.evaluate(EvaluationContext(task: task, trace: trace), task.successCriteria.single);
      expect(outcome.score, 1.0, reason: outcome.detail);
      expect(outcome.detail, contains('judge fake-llm (judge_v4)'));
    });
  });
}
