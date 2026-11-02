import 'dart:convert';

import 'package:aib_core/transport.dart';

import 'answer.dart';

/// The context every question in a request is asked about. Sealed, because the
/// wire format allows exactly these three.
sealed class JevState {
  const JevState();

  /// Plain text — the common case.
  const factory JevState.text(String text) = JevText;

  /// A JSON object or array, serialised into the prompt by the server.
  /// Structured state is not executable: it is rendered as text.
  const factory JevState.json(Object value) = JevJson;

  /// A conversation, rendered with the model's chat template. The shape to
  /// use when the decision is about a dialogue ("did the user agree?").
  const factory JevState.chat(List<JevMessage> messages) = JevChat;

  /// `{state: …}` or `{messages: […]}` — exactly one, which is what the
  /// contract requires.
  JsonMap toJson();
}

final class JevText extends JevState {
  const JevText(this.text);

  final String text;

  @override
  JsonMap toJson() => {'state': text};
}

final class JevJson extends JevState {
  const JevJson(this.value);

  /// A `Map` or `List` of JSON values.
  final Object value;

  @override
  JsonMap toJson() => {'state': value};
}

final class JevChat extends JevState {
  const JevChat(this.messages);

  final List<JevMessage> messages;

  @override
  JsonMap toJson() => {
    'messages': [for (final message in messages) message.toJson()],
  };
}

enum JevRole { system, developer, user, assistant }

/// One turn of a [JevChat].
final class JevMessage {
  const JevMessage({required this.role, this.text = '', this.parts = const []});

  const JevMessage.system(String text) : this(role: .system, text: text);
  const JevMessage.user(String text) : this(role: .user, text: text);
  const JevMessage.assistant(String text) : this(role: .assistant, text: text);

  final JevRole role;

  /// Plain text content. Ignored when [parts] is non-empty.
  final String text;

  /// Content parts, for the multimodal backends. A text-only backend rejects
  /// these rather than dropping them: a decision without the image is not the
  /// one asked for.
  final List<JevPart> parts;

  JsonMap toJson() => {
    'role': role.name,
    'content': parts.isEmpty ? text : [for (final part in parts) part.toJson()],
  };
}

/// A piece of message content.
sealed class JevPart {
  const JevPart();

  const factory JevPart.text(String text) = JevTextPart;

  /// An image by URL, or as a `data:` URI for bytes.
  const factory JevPart.image(String url) = JevImagePart;

  JsonMap toJson();
}

final class JevTextPart extends JevPart {
  const JevTextPart(this.text);

  final String text;

  @override
  JsonMap toJson() => {'type': 'text', 'text': text};
}

final class JevImagePart extends JevPart {
  const JevImagePart(this.url);

  /// `https://…` or `data:image/png;base64,…`.
  final String url;

  /// Bytes as a data URI, for an image that is not already hosted.
  factory JevImagePart.bytes(List<int> bytes, {String mediaType = 'image/png'}) => JevImagePart('data:$mediaType;base64,${base64Encode(bytes)}');

  @override
  JsonMap toJson() => {
    'type': 'image_url',
    'image_url': {'url': url},
  };
}

/// Instructions or a criterion description: text, or structured JSON the
/// server serialises deterministically.
sealed class JevPrompt {
  const JevPrompt();

  const factory JevPrompt.text(String text) = _JevPromptText;
  const factory JevPrompt.json(Object value) = _JevPromptJson;

  Object? toJson();
}

final class _JevPromptText extends JevPrompt {
  const _JevPromptText(this.text);
  final String text;
  @override
  Object? toJson() => text;
}

final class _JevPromptJson extends JevPrompt {
  const _JevPromptJson(this.value);
  final Object value;
  @override
  Object? toJson() => value;
}

/// One typed question. The three shapes of the v1 contract; the type
/// parameter is the answer it produces, so a caller that holds the question
/// also holds the answer's type.
sealed class JevQuestion<A extends JevAnswer> {
  const JevQuestion({required this.instructions, this.structured});

  /// What to decide, as text.
  final String instructions;

  /// Structured instructions, when text is not enough. Wins over
  /// [instructions] if both are given.
  final JevPrompt? structured;

  /// The instructions as sent: the text, or [structured]'s JSON value.
  Object? get instructionsValue => structured?.toJson() ?? instructions;

  JsonMap toJson();

  /// Parses this question's answer out of the server's reply.
  A parse(JsonMap json);
}

/// Pick one of 2–50 named candidates.
///
/// Not final: [JevEnumChoice] is a choice whose candidates are an enum's
/// values, and it has to stay a `JevChoice` so every exhaustive switch over
/// the three question shapes still covers it.
base class JevChoice extends JevQuestion<JevChoiceAnswer> {
  const JevChoice({required super.instructions, required this.criteria, super.structured});

  /// Candidates from an enum: `id` is each value's `name`, the description
  /// comes from [describe] (null = the name says it all).
  ///
  /// ```dart
  /// final route = JevChoice.ofEnum(ModelRoute.values,
  ///     instructions: 'Which model should handle it?',
  ///     describe: (r) => switch (r) { ModelRoute.local => '…', ModelRoute.cloud => '…' });
  /// final answer = await client.decide(JevRequest.ask(task, 'route', route));
  /// ModelRoute picked = route.decode(answer.answer('route'));
  /// ```
  static JevEnumChoice<E> ofEnum<E extends Enum>(List<E> values, {required String instructions, String? Function(E value)? describe}) =>
      JevEnumChoice<E>(values, instructions: instructions, describe: describe);

  /// Candidate id → description (null = the id says it all). Insertion order
  /// is part of the question: it assigns the model's labels and breaks exact
  /// ties.
  final Map<String, String?> criteria;

  /// The candidate ids, in the order they were offered.
  List<String> get options => criteria.keys.toList();

  @override
  JsonMap toJson() => {'type': 'choice', 'instructions': instructionsValue, 'criteria': criteria};

  @override
  JevChoiceAnswer parse(JsonMap json) => JevChoiceAnswer.fromJson(json);
}

/// A [JevChoice] over the values of an enum, which can turn its answer back
/// into one of them — so a route comes back as a `ModelRoute`, not a string
/// somebody has to compare.
final class JevEnumChoice<E extends Enum> extends JevChoice {
  JevEnumChoice(this.values, {required super.instructions, String? Function(E value)? describe, super.structured})
    : super(criteria: {for (final value in values) value.name: describe?.call(value)});

  final List<E> values;

  /// The enum value the model chose. Throws [JevAnswerMismatch] when the
  /// answer names no value of [E] — a backend that answered another question.
  E decode(JevChoiceAnswer answer) => valueOf(answer.choice);

  /// Probability per enum value, in declaration order.
  Map<E, double> probabilities(JevChoiceAnswer answer) => {for (final value in values) value: answer.probabilityOf(value.name)};

  E valueOf(String id) {
    for (final value in values) {
      if (value.name == id) return value;
    }
    throw JevAnswerMismatch(id, expected: '$E', actual: 'choice "$id"');
  }
}

/// Place the state on an ordered rubric of 2–50 levels, lowest first.
final class JevScore extends JevQuestion<JevScoreAnswer> {
  const JevScore({required super.instructions, required this.levels, super.structured});

  final List<String> levels;

  @override
  JsonMap toJson() => {'type': 'score', 'instructions': instructionsValue, 'criteria': levels};

  @override
  JevScoreAnswer parse(JsonMap json) => JevScoreAnswer.fromJson(json, levels: levels);
}

/// How true one statement is, on [0.01, 0.99].
final class JevNoul extends JevQuestion<JevNoulAnswer> {
  const JevNoul({required super.instructions, this.ifTrue, this.ifFalse, super.structured});

  /// Optional rubric for the two ends.
  final String? ifTrue;
  final String? ifFalse;

  @override
  JsonMap toJson() => {
    'type': 'noul',
    'instructions': instructionsValue,
    if (ifTrue != null || ifFalse != null) 'criteria': {'true': ?ifTrue, 'false': ?ifFalse},
  };

  @override
  JevNoulAnswer parse(JsonMap json) => JevNoulAnswer.fromJson(json);
}

/// Response diagnostics. Prompt and scoring behaviour belong to the template
/// version and cannot be changed per request.
final class JevOptions {
  const JevOptions({this.rawLogits = false, this.extra = const {}});

  static const none = JevOptions();

  /// Ask for the selected tokens' logits. The server only returns them when
  /// it was started with advanced metrics enabled.
  final bool rawLogits;

  /// Anything a newer server accepts that this client does not model yet.
  /// Merged into `options`, so a backend feature is reachable without a
  /// release here.
  final JsonMap extra;

  bool get isEmpty => !rawLogits && extra.isEmpty;

  JsonMap toJson() => {if (rawLogits) 'raw_logits': true, ...extra};
}

/// A handle on one question in a [JevQuestionSet]: its id, carrying the type of
/// the answer it will produce, so `response.get(route)` is a [JevChoiceAnswer]
/// at compile time.
base class JevRef<A extends JevAnswer> {
  const JevRef(this.id);

  final String id;
}

/// A handle on a [JevEnumChoice]: reads its answer as the enum value.
final class JevEnumRef<E extends Enum> extends JevRef<JevChoiceAnswer> {
  const JevEnumRef(super.id, this.question);

  final JevEnumChoice<E> question;

  /// The chosen value.
  E valueIn(JevResponse response) => question.decode(response.get(this));

  /// Probability per value.
  Map<E, double> probabilitiesIn(JevResponse response) => question.probabilities(response.get(this));
}

/// Questions being collected for one request, each handing back a typed
/// [JevRef].
///
/// ```dart
/// final questions = JevQuestionSet();
/// final route = questions.add('route', JevChoice(…));
/// final done = questions.add('done', JevNoul(instructions: '…'));
/// final answers = await client.decide(
///   JevRequest.of(state: JevState.text(task), questions: questions),
/// );
/// answers.get(route).probabilityOf('local');  // a choice, statically
/// answers.get(done).noul;                     // a double, statically
/// ```
final class JevQuestionSet {
  final Map<String, JevQuestion> _questions = {};

  /// Adds [question] under [id] and returns its handle. Reusing an id is a
  /// mistake the server cannot report: the second question would silently
  /// replace the first.
  JevRef<A> add<A extends JevAnswer>(String id, JevQuestion<A> question) {
    if (_questions.containsKey(id)) {
      throw ArgumentError.value(id, 'id', 'asked twice in one request');
    }
    _questions[id] = question;
    return JevRef<A>(id);
  }

  /// Adds an enum-typed choice; its handle reads the answer back as `E`.
  JevEnumRef<E> addEnum<E extends Enum>(String id, JevEnumChoice<E> question) {
    add(id, question);
    return JevEnumRef<E>(id, question);
  }

  /// Ids in insertion order, which is the order the server reads them in.
  Map<String, JevQuestion> get questions => Map.unmodifiable(_questions);

  bool get isEmpty => _questions.isEmpty;
  int get length => _questions.length;
}

/// One call: a shared context and the questions asked about it. The server
/// evaluates the shared prefix once and only the per-question suffixes again.
final class JevRequest {
  const JevRequest({required this.state, required this.questions, this.options = JevOptions.none, this.extra = const {}});

  /// Text state and one question, the common shape.
  factory JevRequest.ask(String state, String id, JevQuestion question) => JevRequest(state: JevState.text(state), questions: {id: question});

  /// From a [JevQuestionSet], so the answers can be read back by handle.
  factory JevRequest.of({
    required JevState state,
    required JevQuestionSet questions,
    JevOptions options = JevOptions.none,
    JsonMap extra = const {},
  }) => JevRequest(state: state, questions: questions.questions, options: options, extra: extra);

  final JevState state;

  /// Question id → question. The ids come back as the keys of the answers.
  final Map<String, JevQuestion> questions;

  final JevOptions options;

  /// Top-level fields a newer API understands. Unknown ones are ignored by
  /// the server rather than rejected, so this cannot break a request.
  final JsonMap extra;

  /// The wire format read back — for replaying a recorded request, or for
  /// serving the System One contract from Dart. Throws [JevRequestInvalid]
  /// on a shape the contract does not allow.
  factory JevRequest.fromJson(JsonMap json) {
    final hasState = json.containsKey('state') && json['state'] != null;
    final hasMessages = json['messages'] != null;
    if (hasState == hasMessages) throw const JevRequestInvalid('provide exactly one of state or messages');
    final JevState state = switch (json['state']) {
      final String text => JevState.text(text),
      final Object value when hasState => JevState.json(value),
      _ => JevState.chat([
        for (final raw in json['messages'] as List)
          if (asJsonMap(raw) case final m)
            JevMessage(
              role: JevRole.values.firstWhere((r) => r.name == m['role'], orElse: () => throw JevRequestInvalid('unsupported role "${m['role']}"')),
              text: m['content'] is String ? m['content']! as String : '',
              parts: m['content'] is List
                  ? [
                      for (final part in m['content']! as List)
                        if (asJsonMap(part) case final p)
                          p['type'] == 'text' ? JevPart.text('${p['text']}') : JevPart.image('${asJsonMap(p['image_url'])['url']}'),
                    ]
                  : const [],
            ),
      ]),
    };
    final questions = <String, JevQuestion>{};
    for (final MapEntry(key: id, value: raw) in asJsonMap(json['questions']).entries) {
      final q = asJsonMap(raw);
      final instructions = q['instructions'];
      final text = instructions is String ? instructions : '';
      final structured = instructions is String || instructions == null ? null : JevPrompt.json(instructions);
      String? entry(Object? value) => value == null ? null : (value is String ? value : jsonEncode(value));
      questions[id] = switch (q['type']) {
        'choice' => JevChoice(
          instructions: text,
          structured: structured,
          criteria: {for (final c in asJsonMap(q['criteria']).entries) c.key: entry(c.value)},
        ),
        'score' => JevScore(instructions: text, structured: structured, levels: [for (final l in q['criteria'] as List? ?? const []) entry(l) ?? '']),
        'noul' => JevNoul(
          instructions: text,
          structured: structured,
          ifTrue: entry(asJsonMap(q['criteria'])['true']),
          ifFalse: entry(asJsonMap(q['criteria'])['false']),
        ),
        final other => throw JevRequestInvalid('question "$id" has unknown type "$other"'),
      };
    }
    final options = asJsonMap(json['options']);
    return JevRequest(
      state: state,
      questions: questions,
      options: JevOptions(rawLogits: options['raw_logits'] == true),
    );
  }

  /// Checks what the v1 contract requires and a server would reject with a
  /// 422: 1–256 questions with non-empty ids, 2–50 candidates per choice,
  /// 2–50 levels per score, a non-empty conversation. Backends that score
  /// locally call it first, so an invalid request fails the same way on
  /// every backend instead of producing a number.
  void validate() {
    if (questions.isEmpty || questions.length > maxQuestions) {
      throw JevRequestInvalid('a request asks 1–$maxQuestions questions, got ${questions.length}');
    }
    for (final MapEntry(key: id, value: question) in questions.entries) {
      if (id.isEmpty) throw const JevRequestInvalid('question ids must not be empty');
      final count = switch (question) {
        JevChoice(:final criteria) => criteria.length,
        JevScore(:final levels) => levels.length,
        JevNoul() => null,
      };
      if (count != null && (count < 2 || count > maxCandidates)) {
        throw JevRequestInvalid('question "$id" offers $count ${question is JevScore ? 'levels' : 'candidates'}; v1 allows 2–$maxCandidates');
      }
    }
    if (state case JevChat(:final messages) when messages.isEmpty) {
      throw const JevRequestInvalid('a chat state needs at least one message');
    }
  }

  /// Schema limits of the v1 contract.
  static const maxQuestions = 256;
  static const maxCandidates = 50;

  JsonMap toJson({String? model}) => {
    if (model != null && model.isNotEmpty) 'model': model,
    ...state.toJson(),
    'questions': {for (final entry in questions.entries) entry.key: entry.value.toJson()},
    if (!options.isEmpty) 'options': options.toJson(),
    ...extra,
  };
}

/// A request that breaks the v1 contract, caught before it is sent or scored.
final class JevRequestInvalid implements Exception {
  const JevRequestInvalid(this.message);

  final String message;

  @override
  String toString() => 'JevRequestInvalid: $message';
}
