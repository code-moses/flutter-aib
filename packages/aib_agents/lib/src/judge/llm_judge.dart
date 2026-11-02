import 'dart:convert';

import 'package:aib_core/aib_core.dart';

import '../llm/llm_client.dart';

/// LLM-backed implementation of the core's [ArtifactJudge] port (oracle 3,
/// spec §5.2): pinned judge model, temperature 0, structured answers via a
/// forced tool call. The k=3 majority lives in [ArtifactRubricEvaluator];
/// this class is a single consultation.
///
/// Calibration: judge a manually labelled sample and report Cohen's κ
/// (Stats.cohensKappa) in the thesis before trusting rubric scores.
final class LlmJudge implements ArtifactJudge {
  LlmJudge({required this.client, this.temperature = 0});

  final LlmClient client;
  final double temperature;

  /// judge_v4: the record carries the user's later messages, and the
  /// evidence prompt says the closing statement answers the last of them.
  static const promptVersion = 'judge_v4';

  @override
  String get judgeId => '${client.model} ($promptVersion)';

  static const _systemPrompt = '''
You are a strict, consistent evaluator of what an app agent produced — a
generated UI surface, or the answer it gave the user.
You receive the user's task and the artifact. The app data behind it is not
available to you, so judge only what the rubric asks about the artifact itself.
Answer every rubric question with a strict yes/no via submit_judgement, using
each criterion's key exactly as given. Do not invent keys, and do not answer
under the rubric's name.
Be literal: if a question asks for "all 7 tasks" and you count fewer,
answer no.''';

  /// Replaces the "app data is not available" line when the criterion asked
  /// for the record: with it, judging the artifact alone is exactly wrong.
  static const _evidenceSystemPrompt = '''
You are a strict, consistent evaluator of an app agent's claims.
You receive the user's task, the agent's own closing statement, and a record
of what it actually did — the calls it made, what came back, and how the
episode ended.
The record also holds what the user said after the task, in order (entries
with a "user" field). The closing statement answers the last of them, so a
statement that follows a later correction is not inventing anything.
Judge the statement against that record and against nothing else. A claim you
cannot find support for in the record is not supported, however plausible it
sounds; the record is what happened.
Answer every rubric question with a strict yes/no via submit_judgement, using
each criterion's key exactly as given. Do not invent keys, and do not answer
under the rubric's name.''';

  @override
  Future<JudgeAnswer> judge(JudgeRequest request) async {
    final submitTool = LlmTool(
      name: 'submit_judgement',
      description: 'Submit the verdict for every rubric criterion.',
      parameters: {
        'type': 'object',
        'properties': {
          'answers': {
            'type': 'object',
            'properties': {
              for (final criterion in request.rubric.criteria) criterion.id: {'type': 'boolean', 'description': criterion.question},
            },
            'required': [for (final criterion in request.rubric.criteria) criterion.id],
          },
          'rationale': {'type': 'string'},
        },
        'required': ['answers'],
      },
    );

    final stopwatch = Stopwatch()..start();
    final messages = <LlmMessage>[
      LlmMessage.system(request.evidence.isEmpty ? _systemPrompt : _evidenceSystemPrompt),
      LlmMessage.user(
        [
          'Task given to the agent under evaluation:',
          request.taskInstruction,
          '',
          // The key is spelled out rather than bracketed: with a single
          // criterion some models answer under the rubric's *name*.
          if (request.rubric.scope case final scope?) ...['Scope of rubric "${request.rubric.name}":', scope, ''],
          'Criteria of rubric "${request.rubric.name}", '
              'each with the answer key to use:',
          for (final criterion in request.rubric.criteria) '- key "${criterion.id}": ${criterion.question}',
          '',
          'Artifact to judge:',
          jsonEncode(request.artifact),
          if (request.evidence.isNotEmpty) ...['', 'Record of what the agent actually did:', jsonEncode(request.evidence)],
        ].join('\n'),
      ),
    ];

    // One more attempt when the judge answers without the tool: that is a
    // format slip, not a verdict, and scoring it as "no" to every criterion
    // turned a parsing artefact into a zero.
    var promptTokens = 0;
    var completionTokens = 0;
    LlmToolCall? call;
    for (var attempt = 0; attempt < 2 && call == null; attempt++) {
      final response = await client.complete(LlmRequest(messages: messages, tools: [submitTool], temperature: temperature, maxTokens: 1024));
      promptTokens += response.usage.promptTokens;
      completionTokens += response.usage.completionTokens;
      call = response.toolCalls.where((c) => c.name == 'submit_judgement').firstOrNull;
      if (call == null) {
        messages
          ..add(LlmMessage.assistant(response.text))
          ..add(
            LlmMessage.user(
              'Answer by calling submit_judgement with a boolean for every '
              'key listed above.',
            ),
          );
      }
    }

    stopwatch.stop();
    final spend = (prompt: promptTokens, completion: completionTokens, ms: stopwatch.elapsedMilliseconds);
    if (call == null) {
      // Still no structured answer: every criterion counts as failed —
      // conservative, and the rationale says why.
      return JudgeAnswer(
        answers: const {},
        rationale: 'judge returned no structured answer after a second request',
        tokensPrompt: spend.prompt,
        tokensCompletion: spend.completion,
        latencyMs: spend.ms,
      );
    }
    final answers = asJsonMap(call.arguments['answers']);
    // An answer under a key no criterion has counts as a failed criterion
    // (conservative, §5.2), but says so rather than reading as a silent no.
    final unknown = answers.keys.where((key) => !request.rubric.criteria.any((c) => c.id == key)).toList();
    final rationale = call.arguments['rationale'] as String?;
    return JudgeAnswer(
      tokensPrompt: spend.prompt,
      tokensCompletion: spend.completion,
      latencyMs: spend.ms,
      answers: {for (final criterion in request.rubric.criteria) criterion.id: _isYes(answers[criterion.id])},
      rationale: unknown.isEmpty ? rationale : 'answered under unknown key(s) ${unknown.join(', ')}; ${rationale ?? ''}',
    );
  }

  /// Models honour a boolean schema loosely: `"yes"`, `"true"` or `1`. Anything
  /// not recognisably affirmative counts as "no" (conservative, §5.2).
  static bool _isYes(Object? value) => switch (value) {
    bool() => value,
    num() => value != 0,
    String() => const {'true', 'yes', 'y', '1', 'pass'}.contains(value.trim().toLowerCase()),
    _ => false,
  };
}
