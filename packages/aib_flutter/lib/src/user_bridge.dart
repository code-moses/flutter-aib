import 'package:aib_core/ports.dart';

import 'flutter_environment.dart';
import 'json_schema.dart';

/// What the agent wants from the person in front of the app.
enum UserQuestionType {
  /// Yes/no. Used for policy confirmations before an irreversible effect.
  confirm,

  /// Pick one of a closed list the agent supplies in `options`.
  choice,

  /// Pick a record out of the app's own data. The app answers with its real
  /// picker; `metadata` carries what it needs to open it.
  pick,

  /// Free text.
  text,
}

final class UserQuestion {
  const UserQuestion({required this.id, required this.type, required this.prompt, this.options = const [], this.metadata = const {}});

  /// Unique within the episode; lets an asynchronous UI answer the right
  /// question when several were asked.
  final String id;
  final UserQuestionType type;
  final String prompt;

  /// Candidate values for [UserQuestionType.choice].
  final List<String> options;

  /// App-specific payload, passed through untouched (same reasoning as
  /// `AibIntent.metadata`).
  final JsonMap metadata;

  factory UserQuestion.fromPayload(String id, JsonMap payload) => UserQuestion(
    id: id,
    type: UserQuestionType.values.byName(payload['type'] as String? ?? 'text'),
    prompt: payload['prompt'] as String? ?? '',
    options: [for (final option in payload['options'] as List? ?? const []) '$option'],
    metadata: asJsonMap(payload['metadata']),
  );

  JsonMap toJson() => {'id': id, ...asked()};

  /// The question without its per-ask id, which would make identical refusals
  /// differ and hide a loop from anything that compares answers.
  JsonMap asked() => {'type': type.name, 'prompt': prompt, if (options.isNotEmpty) 'options': options, if (metadata.isNotEmpty) 'metadata': metadata};
}

final class UserAnswer {
  const UserAnswer(this.value) : cancelled = false, cancelReason = null, cancelCode = 'cancelled';

  /// The person declined, dismissed the dialog, or the turn was cancelled.
  /// The agent gets a `failed` result and can end the episode cleanly
  /// instead of hanging.
  ///
  /// [code] becomes the envelope error code, so the metric layer can tell a
  /// user who said no from a scripted fixture that had no answer to give —
  /// the second is a gap in the task, not a decision by anyone.
  const UserAnswer.cancelled({this.cancelReason, String code = 'cancelled'}) : value = null, cancelled = true, cancelCode = code;

  final Object? value;
  final bool cancelled;
  final String? cancelReason;
  final String cancelCode;
}

/// Presents [UserQuestion]s to a human — dialogs and pickers in production,
/// a script in the benchmark.
typedef UserAnswerer = Future<UserAnswer> Function(UserQuestion question);

/// User envelope vocabulary — adapter convention:
///
///   act `user.ask` {type, prompt, options?, metadata?} -> {answer}
///
/// Every clarification, confirmation and master-data pick crosses the same
/// channel as everything else, so the trace shows how often an agent asked.
/// Registered as [EnvelopeKind.act] because asking costs a step; it changes no
/// app state, so the metric layer keeps `user.*` out of
/// `redundant_action_ratio`.
final class UserBridge {
  UserBridge({required this.answerer});

  final UserAnswerer answerer;

  /// Questions asked so far this episode; numbers the question ids.
  int _asked = 0;

  /// Called by the harness between episodes.
  void reset() => _asked = 0;

  static const _payloadSchema = {
    'type': 'object',
    'properties': {
      'type': {
        'type': 'string',
        'enum': ['confirm', 'choice', 'pick', 'text'],
      },
      'prompt': {'type': 'string'},
      'options': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'metadata': {'type': 'object'},
    },
    'required': ['type', 'prompt'],
  };

  void install(FlutterEnvironment environment) {
    environment.registerHandler(
      const EnvelopeSpec(
        key: 'user.ask',
        kind: .act,
        description:
            'Asks the user a question and blocks until they answer. Use it '
            'instead of guessing when a value is ambiguous, and before any '
            'effect the user would want to approve. type: confirm | choice '
            '| pick | text.',
        payloadSchema: _payloadSchema,
        blocksOnUser: true,
      ),
      (envelope) async {
        final violations = validateAgainstSchema(envelope.payload, _payloadSchema);
        if (violations.isNotEmpty) {
          return EnvelopeResult.failed(
            EnvelopeError.badParams,
            'user.ask payload does not match its schema: '
            '${violations.join('; ')}',
            details: {'violations': violations},
            userWaitMs: 0,
          );
        }

        final question = UserQuestion.fromPayload('ask-${_asked++}', envelope.payload);
        final watch = Stopwatch()..start();
        final UserAnswer answer;
        try {
          answer = await answerer(question);
        } catch (e) {
          return EnvelopeResult.failed('ask_failed', 'Could not ask the user: $e', userWaitMs: watch.elapsedMilliseconds);
        }
        final waitedMs = watch.elapsedMilliseconds;

        if (answer.cancelled) {
          return EnvelopeResult.failed(
            answer.cancelCode,
            answer.cancelReason ?? 'The user did not answer.',
            details: {'question': question.asked()},
            userWaitMs: waitedMs,
          );
        }
        return EnvelopeResult(status: .ok, payload: {'question': question.asked(), 'answer': answer.value}, userWaitMs: waitedMs);
      },
    );
  }
}

/// The benchmark's stand-in for a person, answering from the task fixture.
/// An uncovered question gets `no_scripted_answer`, never a silent default.
final class ScriptedUserAnswerer {
  ScriptedUserAnswerer({Map<String, Object?> answers = const {}, this.confirmDefault = true}) : _answers = Map.of(answers);

  /// Keyed by, in order of preference: the exact prompt, then a substring of
  /// the prompt, then the question type name (`pick`, `text`, …) as a
  /// catch-all for that type.
  final Map<String, Object?> _answers;

  /// Answer to a confirmation the fixture has no `confirm` entry for.
  final bool confirmDefault;

  /// Every question that was asked, in order — the raw material for
  /// `clarification_count` assertions in a task.
  final List<UserQuestion> asked = [];

  /// Questions the fixture had no answer for.
  final List<UserQuestion> unanswered = [];

  Future<UserAnswer> call(UserQuestion question) async {
    asked.add(question);

    if (_lookup(question) case final answer?) {
      return UserAnswer(answer);
    }
    if (question.type == .confirm) {
      return UserAnswer(confirmDefault);
    }
    unanswered.add(question);
    // Worded for the agent; a hint for the task author would be acted on.
    return const UserAnswer.cancelled(
      code: 'no_scripted_answer',
      cancelReason:
          'Nobody is available to answer this question. Asking again, in any '
          'wording, will get the same reply. Decide it yourself from what you '
          'already know, or finish with meta.abort and say what was missing.',
    );
  }

  Object? _lookup(UserQuestion question) {
    if (_answers.containsKey(question.prompt)) return _answers[question.prompt];
    for (final entry in _answers.entries) {
      if (entry.key.isNotEmpty && question.prompt.contains(entry.key)) {
        return entry.value;
      }
    }
    return _answers[question.type.name];
  }
}
