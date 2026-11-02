import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

/// The record shows what the user said after the instruction, and an abort the
/// agent's loop wrote itself is not judged as the agent's claim.

final class _RecordingJudge implements ArtifactJudge {
  _RecordingJudge(this.answers, {this.rationale});

  final Map<String, bool> answers;
  final String? rationale;
  final List<JudgeRequest> requests = [];

  @override
  String get judgeId => 'recording-judge';

  @override
  Future<JudgeAnswer> judge(JudgeRequest request) async {
    requests.add(request);
    return JudgeAnswer(answers: answers, rationale: rationale);
  }
}

const _rubric = {
  'rubric': 'faithfulness_test',
  'scope': 'Judge only whether the statement is true of the record.',
  'criteria': [
    {'id': 'actions_happened', 'question': 'Did the reported actions happen?'},
  ],
};

const _criterion = SuccessCriterion(
  type: CriterionTypes.artifactRubric,
  config: {
    'rubricSpec': _rubric,
    'artifactKey': ['meta.done', 'meta.abort'],
    'evidence': true,
    'skipWhenNoArtifact': true,
  },
);

TaskSpec _task() => TaskSpec(
  id: 't',
  title: 't',
  instruction: 'Lege eine Aktivität an.',
  budget: const Budget(maxSteps: 5, maxWallClockSeconds: 10),
  fixture: const FixtureRef(id: 'f', data: {}),
  successCriteria: const [_criterion],
);

/// Builds a trace from a compact script: `('act', key)`, `('done', text)`,
/// `('abort', text, decision)`, `('turn', text, after)`, `('steer', text, delivered)`.
EpisodeTrace _trace(List<List<Object?>> script) {
  var seq = 0;
  var exchange = 0;
  final events = <TraceEvent>[];
  void add(String type, JsonMap data) => events.add(TraceEvent(seq: seq++, tUs: seq, type: type, data: data));
  add(TraceEventTypes.episodeStart, const {});
  for (final step in script) {
    switch (step) {
      case ['act', final String key]:
        add(TraceEventTypes.agentEnvelope, {
          'seq': exchange,
          'key': key,
          'kind': 'act',
          'payload': const {'x': 1},
        });
        add(TraceEventTypes.envResult, {
          'seq': exchange++,
          'status': 'ok',
          'payload': const {'ok': true},
        });
      case ['done', final String text]:
        add(TraceEventTypes.agentEnvelope, {
          'seq': exchange++,
          'key': 'meta.done',
          'kind': 'act',
          'payload': {'summary': text},
        });
      case ['abort', final String text, final JsonMap decision]:
        add(TraceEventTypes.agentEnvelope, {
          'seq': exchange++,
          'key': 'meta.abort',
          'kind': 'act',
          'payload': {'reason': text},
          'decision': decision,
        });
      case ['turn', final String text, final String after]:
        add(TraceEventTypes.userTurn, {'seq': exchange - 1, 'id': 'korrektur', 'instruction': text, 'after': after});
      case ['steer', final String text, final bool delivered]:
        add(TraceEventTypes.userSteer, {'seq': exchange, 'id': 's', 'afterActions': 1, 'message': text, 'delivered': delivered});
    }
  }
  add(TraceEventTypes.episodeEnd, const {'reason': 'done'});
  return EpisodeTrace(
    meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'a', environmentId: 'env', repetition: 1, startedAt: DateTime.utc(2026)),
    events: events,
  );
}

List<JsonMap> _entries(EpisodeTrace trace, {int maxActions = 24}) => [
  for (final entry in episodeEvidence(trace, maxActions: maxActions)['actions']! as List) asJsonMap(entry),
];

void main() {
  group('the record carries what the user said', () {
    test('a follow-up appears where it was said, with what the agent had said before it', () {
      final entries = _entries(
        _trace([
          ['act', 'form.open'],
          ['done', 'Betreff "Wartung Heizung" gesetzt.'],
          ['turn', 'Nein, der Betreff soll "Wartung Lüftung" heißen.', 'Betreff "Wartung Heizung" gesetzt.'],
          ['act', 'form.set'],
          ['done', 'Betreff auf "Wartung Lüftung" geändert.'],
        ]),
      );
      expect([for (final e in entries) e['did'] ?? 'user'], ['form.open', 'user', 'form.set']);
      expect(entries[1]['user'], contains('Wartung Lüftung'));
      expect(entries[1]['agentHadSaid'], contains('Wartung Heizung'));
    });

    test('a delivered steering message is in the record, an undelivered one is not', () {
      final entries = _entries(
        _trace([
          ['act', 'a'],
          ['steer', 'Nimm morgen statt heute.', true],
          ['steer', 'never heard', false],
          ['act', 'b'],
        ]),
      );
      final said = [for (final e in entries) ?e['user']];
      expect(said, ['Nimm morgen statt heute.']);
    });

    test('user messages survive when the middle of a long episode is cut', () {
      final entries = _entries(
        _trace([
          for (var i = 0; i < 20; i++) ['act', 'a$i'],
          ['done', 'first'],
          ['turn', 'und jetzt die andere', 'first'],
          for (var i = 20; i < 40; i++) ['act', 'a$i'],
        ]),
        maxActions: 9,
      );
      expect(entries.where((e) => e['user'] == 'und jetzt die andere'), hasLength(1));
      expect(entries.where((e) => '${e['did']}'.contains('omitted')), hasLength(1));
      expect(entries.where((e) => e.containsKey('did') && !'${e['did']}'.contains('omitted')), hasLength(8));
    });
  });

  group('an abort the agent loop wrote is not a claim', () {
    Future<CriterionOutcome> judge(EpisodeTrace trace, _RecordingJudge judge) =>
        ArtifactRubricEvaluator(judge: judge).evaluate(EvaluationContext(task: _task(), trace: trace), _criterion);

    test('marked with authoredBy: harness, it is not applicable and never reaches the judge', () async {
      final recording = _RecordingJudge({'actions_happened': false});
      final outcome = await judge(
        _trace([
          [
            'abort',
            'model returned an empty response (3 retries)',
            {
              'note': 'no_usable_response',
              'extra': {AgentDecision.authoredByKey: AgentDecision.harnessAuthor},
            },
          ],
        ]),
        recording,
      );
      expect(outcome.applies, isFalse);
      expect(outcome.detail, contains("agent's loop"));
      expect(recording.requests, isEmpty);
    });

    test('a trace recorded before the flag is recognised by the reference loop\'s note', () async {
      final recording = _RecordingJudge({'actions_happened': false});
      final outcome = await judge(
        _trace([
          [
            'abort',
            'model returned an empty response (3 retries)',
            {'note': 'no_usable_response routeintents'},
          ],
        ]),
        recording,
      );
      expect(outcome.applies, isFalse);
      expect(recording.requests, isEmpty);
    });

    test('an abort the model chose is still judged', () async {
      final recording = _RecordingJudge({'actions_happened': true});
      final outcome = await judge(
        _trace([
          [
            'abort',
            'Der Kontakt fehlt, ich frage nach.',
            {'note': 'routeintents'},
          ],
        ]),
        recording,
      );
      expect(outcome.applies, isTrue);
      expect(recording.requests, hasLength(3));
    });
  });

  test('the judge sees the rubric scope, and every answer and reason is kept', () async {
    final recording = _RecordingJudge({'actions_happened': false}, rationale: 'form.set failed');
    final outcome = await ArtifactRubricEvaluator(judge: recording).evaluate(
      EvaluationContext(
        task: _task(),
        trace: _trace([
          ['act', 'form.open'],
          ['done', 'Erledigt.'],
        ]),
      ),
      _criterion,
    );
    expect(recording.requests.first.rubric.scope, contains('true of the record'));
    expect(outcome.data['answers'], hasLength(3));
    expect((outcome.data['answers']! as List).first, {'actions_happened': false});
    expect(outcome.data['rationales'], ['form.set failed', 'form.set failed', 'form.set failed']);
  });
}
