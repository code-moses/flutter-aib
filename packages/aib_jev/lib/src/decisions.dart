/// Ready-made decisions over any [JevClient]:
///
/// | decision | question | use |
/// |---|---|---|
/// | [JevRouter] | `choice` over an enum | model routing |
/// | [JevCompletionCheck] | `noul` "the goal holds" | premature termination |
/// | [JevSelector] | `noul` per candidate | tool preselection, reranking |
/// | [JevGuard] | `noul` "this action is wanted and safe" | action guard |
///
/// Each carries English and German default texts and a [JevLanguagePolicy], and
/// returns the full [JevResponse] next to its verdict. Thresholds are
/// parameters, and a text missing for a language falls back to English via
/// [JevLocalized].
library;

import 'package:aib_core/transport.dart';

import 'answer.dart';
import 'client.dart';
import 'language.dart';
import 'request.dart';

/// Text of a state for language detection: the text, or the user turns.
String jevStateText(JevState state) => switch (state) {
  JevText(:final text) => text,
  JevJson(:final value) => '$value',
  JevChat(:final messages) => [
    for (final m in messages)
      if (m.role == .user) m.text,
  ].join('\n'),
};

// Routing

/// Picks one value of [R] for a state — a model tier, a queue, a handler.
///
/// With [preferred] and [threshold] it is the asymmetric rule the router in
/// `aib_agents` uses: stay with [preferred] (the cheap side) when
/// p(preferred) ≥ [threshold], otherwise take the likeliest other value.
/// Without them, the likeliest value wins.
final class JevRouter<R extends Enum> {
  JevRouter({
    required this.client,
    required this.values,
    required this.instructions,
    required this.criteria,
    this.language = const JevLanguagePolicy.fixed('en'),
    this.preferred,
    this.threshold = 0.5,
  });

  final JevClient client;
  final List<R> values;
  final JevLocalized<String> instructions;

  /// Per language, a description of every value.
  final JevLocalized<Map<R, String>> criteria;
  final JevLanguagePolicy language;
  final R? preferred;
  final double threshold;

  /// The question [route] asks about [state] — exposed so a caller can put
  /// it into a larger request next to other questions.
  JevEnumChoice<R> questionFor(String language) {
    final described = criteria.of(language);
    return JevChoice.ofEnum(values, instructions: instructions.of(language), describe: (value) => described[value]);
  }

  Future<JevRouting<R>> route(JevState state, {CancellationToken? cancellation}) async {
    final code = language.resolve(jevStateText(state));
    final question = questionFor(code);
    final response = await client.decide(
      JevRequest(state: state, questions: {'route': question}),
      cancellation: cancellation,
    );
    final answer = response.answer<JevChoiceAnswer>('route');
    final probabilities = question.probabilities(answer);
    final R chosen;
    if (preferred case final keep? when (probabilities[keep] ?? 0) >= threshold) {
      chosen = keep;
    } else if (preferred case final skip?) {
      final others = probabilities.entries.where((e) => e.key != skip).toList();
      chosen = others.reduce((a, b) => b.value > a.value ? b : a).key;
    } else {
      chosen = question.decode(answer);
    }
    return JevRouting(route: chosen, probabilities: probabilities, language: code, answer: answer, response: response);
  }
}

final class JevRouting<R extends Enum> {
  const JevRouting({required this.route, required this.probabilities, required this.language, required this.answer, required this.response});

  final R route;
  final Map<R, double> probabilities;

  /// The language the question was asked in.
  final String language;
  final JevChoiceAnswer answer;
  final JevResponse response;
}

// Completion check

/// "Is the goal achieved in this state?", asked before an agent may say it is
/// done.
final class JevCompletionCheck {
  JevCompletionCheck({required this.client, this.threshold = 0.5, this.texts = defaultTexts, this.language = const JevLanguagePolicy.matchState()});

  static const defaultTexts = JevLocalized({
    'en': JevNoulTexts(
      statement: 'The goal below has been fully achieved in the state: every part of it is done, nothing is still missing or pending.',
      goalLabel: 'Goal',
      ifTrue: 'Everything the goal asks for is visibly done.',
      ifFalse: 'Something the goal asks for is missing, wrong or not confirmed.',
    ),
    'de': JevNoulTexts(
      statement: 'Das folgende Ziel ist im Zustand vollständig erreicht: jeder Teil ist erledigt, nichts fehlt oder steht noch aus.',
      goalLabel: 'Ziel',
      ifTrue: 'Alles, was das Ziel verlangt, ist sichtbar erledigt.',
      ifFalse: 'Etwas, das das Ziel verlangt, fehlt, ist falsch oder nicht bestätigt.',
    ),
  });

  final JevClient client;

  /// Done when the noul reaches it. Choose it on your own data: the noul is
  /// a preference, not a calibrated probability.
  final double threshold;
  final JevLocalized<JevNoulTexts> texts;

  /// Matches the *goal's* language by default — the goal is what the user
  /// wrote, the state is often an app's structured output.
  final JevLanguagePolicy language;

  JevNoul questionFor(String goal, String language) => texts.of(language).question(goal);

  Future<JevCompletion> check({required String goal, required JevState state, CancellationToken? cancellation}) async {
    final code = language.resolve(goal);
    final response = await client.decide(
      JevRequest(state: state, questions: {'done': questionFor(goal, code)}),
      cancellation: cancellation,
    );
    final answer = response.answer<JevNoulAnswer>('done');
    return JevCompletion(
      done: answer.isTrue(threshold: threshold),
      answer: answer,
      language: code,
      response: response,
    );
  }
}

final class JevCompletion {
  const JevCompletion({required this.done, required this.answer, required this.language, required this.response});

  final bool done;
  final JevNoulAnswer answer;
  final String language;
  final JevResponse response;
}

/// The texts of a noul about a subject (a goal, an action).
final class JevNoulTexts {
  const JevNoulTexts({required this.statement, required this.goalLabel, this.ifTrue, this.ifFalse});

  final String statement;

  /// Introduces the subject in the statement ("Goal", "Ziel").
  final String goalLabel;
  final String? ifTrue;
  final String? ifFalse;

  JevNoul question(String subject) => JevNoul(instructions: '$statement\n$goalLabel: $subject', ifTrue: ifTrue, ifFalse: ifFalse);
}

// Selection and reranking

/// What a [JevSelector] asks, per candidate: the statement, the rubric's two
/// ends, and how the task is presented as the state.
///
/// The wording moves the scores more than anything else about a selection, so
/// it is a named, versioned choice: an arm names one by [id], and `jev_probe`
/// (aib_mcp) compares them on labelled tasks.
final class JevSelectionPrompt {
  const JevSelectionPrompt({required this.id, required this.statement, this.ifTrue, this.ifFalse, this.state = taskOnly});

  /// Per language, with `{task}`.
  static const taskOnly = JevLocalized({'en': '{task}'});

  final String id;

  /// Per language, with `{id}` and `{description}` placeholders.
  final JevLocalized<String> statement;
  final JevLocalized<String>? ifTrue;
  final JevLocalized<String>? ifFalse;

  /// The state the decision model reads, per language, with `{task}`.
  final JevLocalized<String> state;

  String statementFor(String language, {required String id, required String description}) =>
      statement.of(language).replaceAll('{id}', id).replaceAll('{description}', description);

  JevState stateFor(String language, String task) => JevState.text(state.of(language).replaceAll('{task}', task));

  /// The statement every selection asked until prompts had names.
  static const neededV1 = JevSelectionPrompt(
    id: 'needed_v1',
    statement: JevLocalized({
      'en': 'This candidate is needed to handle what the state asks for. Candidate: {id} — {description}',
      'de': 'Dieser Kandidat wird gebraucht, um zu erledigen, was der Zustand verlangt. Kandidat: {id} — {description}',
    }),
  );

  /// "An assistant would call it", with the rubric's two ends and the task
  /// framed as a user's request to an app assistant.
  static const callRubricStateV1 = JevSelectionPrompt(
    id: 'call_rubric_state_v1',
    statement: JevLocalized({
      'en': 'To carry out the request, an assistant would call the tool {id} at some point. Tool {id}: {description}',
      'de': 'Um die Anfrage zu erledigen, würde ein Assistent das Werkzeug {id} irgendwann aufrufen. Werkzeug {id}: {description}',
    }),
    ifTrue: JevLocalized({
      'en':
          'The tool does part of the request, shows the user what was asked for, or reads something the request needs first '
          '(an id, a list, a schema).',
      'de':
          'Das Werkzeug erledigt einen Teil der Anfrage, zeigt dem Nutzer das Verlangte oder liest etwas, das die Anfrage zuerst braucht '
          '(eine ID, eine Liste, ein Schema).',
    }),
    ifFalse: JevLocalized({
      'en': 'The tool is about something the request does not touch.',
      'de': 'Das Werkzeug betrifft etwas, das die Anfrage nicht berührt.',
    }),
    state: JevLocalized({
      'en': 'A user asks the assistant of a business app: "{task}"',
      'de': 'Ein Nutzer bittet den Assistenten einer Business-App: „{task}“',
    }),
  );

  /// [callRubricStateV1] in English for every task, German ones included. The
  /// better choice for a small local decider; on a hosted model the localised
  /// one is ahead.
  static const callRubricEnV1 = JevSelectionPrompt(
    id: 'call_rubric_en_v1',
    statement: JevLocalized({'en': 'To carry out the request, an assistant would call the tool {id} at some point. Tool {id}: {description}'}),
    ifTrue: JevLocalized({
      'en':
          'The tool does part of the request, shows the user what was asked for, or reads something the request needs first '
          '(an id, a list, a schema).',
    }),
    ifFalse: JevLocalized({'en': 'The tool is about something the request does not touch.'}),
    state: JevLocalized({'en': 'A user asks the assistant of a business app: "{task}"'}),
  );

  static const builtIn = {'needed_v1': neededV1, 'call_rubric_state_v1': callRubricStateV1, 'call_rubric_en_v1': callRubricEnV1};

  static JevSelectionPrompt byId(String id) => builtIn[id] ?? (throw ArgumentError('no selection prompt "$id" (${builtIn.keys.join(', ')})'));

  /// An inline prompt (`jev_probe` variants): `statement`, `ifTrue`,
  /// `ifFalse` and `state` each a string or a map of language to string.
  factory JevSelectionPrompt.fromJson(JsonMap json) {
    final id = json['id'];
    if (id is! String) throw const FormatException('a selection prompt needs an "id"');
    if (json['statement'] == null) return byId(id);
    JevLocalized<String>? texts(Object? raw) => switch (raw) {
      null => null,
      final String text => JevLocalized.only(text),
      final Map<Object?, Object?> map => JevLocalized({for (final e in map.entries) '${e.key}': '${e.value}'}),
      _ => throw FormatException('selection prompt "$id": expected a string or a map of language to string, got $raw'),
    };
    return JevSelectionPrompt(
      id: id,
      statement: texts(json['statement'])!,
      ifTrue: texts(json['ifTrue']),
      ifFalse: texts(json['ifFalse']),
      state: texts(json['state']) ?? taskOnly,
    );
  }
}

/// Scores every candidate against a state: tool preselection, relevance
/// filtering, reranking.
///
/// One `noul` per candidate ([JevAsk.judgeEach]), not one big `choice`: several
/// can be relevant, the catalogue can exceed the 50-candidate and 20-label
/// limits, and its order cannot bias the result.
final class JevSelector {
  JevSelector({
    required this.client,
    this.prompt = JevSelectionPrompt.neededV1,
    this.language = const JevLanguagePolicy.matchState(),
    this.perRequest = 50,
  });

  final JevClient client;
  final JevSelectionPrompt prompt;
  final JevLanguagePolicy language;
  final int perRequest;

  /// [select] over [task] presented the way [prompt] presents it; the
  /// language is resolved from the task's own words, not the wrapper's.
  Future<JevSelection> selectFor({
    required String task,
    required Map<String, String> candidates,
    double? threshold,
    int? topK,
    int minKeep = 0,
    CancellationToken? cancellation,
  }) {
    final code = language.resolve(task);
    return select(
      state: prompt.stateFor(code, task),
      candidates: candidates,
      threshold: threshold,
      topK: topK,
      minKeep: minKeep,
      languageCode: code,
      cancellation: cancellation,
    );
  }

  /// Candidates by relevance, highest first; with [threshold] only those
  /// that reach it — but never fewer than the [minKeep] best — and with
  /// [topK] at most that many.
  Future<JevSelection> select({
    required JevState state,
    required Map<String, String> candidates,
    double? threshold,
    int? topK,
    int minKeep = 0,
    String? languageCode,
    CancellationToken? cancellation,
  }) async {
    final code = languageCode ?? language.resolve(jevStateText(state));
    final statements = {
      for (final MapEntry(key: id, value: description) in candidates.entries) id: prompt.statementFor(code, id: id, description: description),
    };
    final (:answers, :responses) = await client.judgeEachWithResponses(
      state: state,
      candidates: statements,
      perRequest: perRequest,
      ifTrue: prompt.ifTrue?.of(code),
      ifFalse: prompt.ifFalse?.of(code),
      cancellation: cancellation,
    );
    final ranked = answers.entries.toList()..sort((a, b) => b.value.noul.compareTo(a.value.noul));
    final kept = [
      for (final (rank, e) in ranked.indexed)
        if (threshold == null || e.value.noul >= threshold || rank < minKeep) e.key,
    ];
    return JevSelection(
      selected: topK == null ? kept : kept.take(topK).toList(),
      scores: {for (final e in ranked) e.key: e.value.noul},
      language: code,
      spend: JevSpend.of(responses),
    );
  }
}

final class JevSelection {
  const JevSelection({required this.selected, required this.scores, required this.language, this.spend = const JevSpend()});

  /// Kept candidates, most relevant first.
  final List<String> selected;

  /// Every candidate's noul, most relevant first.
  final Map<String, double> scores;
  final String language;

  /// What the selection cost, over every request it took.
  final JevSpend spend;
}

/// What one decision cost, summed over the requests it took — the numbers a
/// caller records as a side call: a selection over a catalogue is several
/// requests, and reporting only the last one would under-bill it.
final class JevSpend {
  const JevSpend({this.model = '', this.inputTokens = 0, this.outputTokens = 0, this.latencyMs = 0, this.requests = 0});

  factory JevSpend.of(Iterable<JevResponse> responses) {
    var spend = const JevSpend();
    for (final response in responses) {
      spend = JevSpend(
        // The model that answered, as the backend reported it; the last
        // non-empty one wins, and in practice they are all the same.
        model: response.model.isEmpty ? spend.model : response.model,
        inputTokens: spend.inputTokens + response.usage.inputTokens,
        outputTokens: spend.outputTokens + response.usage.outputTokens,
        latencyMs: spend.latencyMs + response.latencyMs,
        requests: spend.requests + 1,
      );
    }
    return spend;
  }

  final String model;
  final int inputTokens;
  final int outputTokens;
  final int latencyMs;
  final int requests;

  JevSpend operator +(JevSpend other) => JevSpend(
    model: other.model.isEmpty ? model : other.model,
    inputTokens: inputTokens + other.inputTokens,
    outputTokens: outputTokens + other.outputTokens,
    latencyMs: latencyMs + other.latencyMs,
    requests: requests + other.requests,
  );
}

// Action guard

enum JevGuardVerdict {
  /// Clearly wanted and safe: go ahead.
  allow,

  /// Unclear: ask the user first.
  confirm,

  /// Clearly not wanted, or unsafe: do not act.
  deny,
}

/// Reviews a proposed action before it is carried out. Two thresholds make
/// three outcomes, because the useful answer between "yes" and "no" is "ask
/// the user" — that is where a decision model's uncertainty should go.
final class JevGuard {
  JevGuard({
    required this.client,
    this.allowAbove = 0.7,
    this.denyBelow = 0.3,
    this.texts = defaultTexts,
    this.language = const JevLanguagePolicy.matchState(),
  }) : assert(denyBelow <= allowAbove, 'denyBelow must not exceed allowAbove');

  static const defaultTexts = JevLocalized({
    'en': JevNoulTexts(
      statement:
          'The action below is what the user asked for in the state, and carrying it out is safe: it destroys nothing the user did not ask to change.',
      goalLabel: 'Action',
      ifTrue: 'Clearly requested and harmless.',
      ifFalse: 'Not requested, or it deletes or overwrites something the user wanted to keep.',
    ),
    'de': JevNoulTexts(
      statement:
          'Die folgende Aktion ist das, worum der Nutzer im Zustand gebeten hat, und sie auszuführen ist sicher: sie zerstört nichts, '
          'dessen Änderung nicht verlangt wurde.',
      goalLabel: 'Aktion',
      ifTrue: 'Eindeutig verlangt und unbedenklich.',
      ifFalse: 'Nicht verlangt, oder sie löscht bzw. überschreibt etwas, das der Nutzer behalten wollte.',
    ),
  });

  final JevClient client;
  final double allowAbove;
  final double denyBelow;
  final JevLocalized<JevNoulTexts> texts;
  final JevLanguagePolicy language;

  Future<({JevGuardVerdict verdict, JevNoulAnswer answer, String language, JevResponse response})> review({
    required String action,
    required JevState state,
    CancellationToken? cancellation,
  }) async {
    final code = language.resolve(jevStateText(state));
    final response = await client.decide(
      JevRequest(state: state, questions: {'guard': texts.of(code).question(action)}),
      cancellation: cancellation,
    );
    final answer = response.answer<JevNoulAnswer>('guard');
    final verdict = answer.noul >= allowAbove
        ? JevGuardVerdict.allow
        : answer.noul < denyBelow
        ? JevGuardVerdict.deny
        : JevGuardVerdict.confirm;
    return (verdict: verdict, answer: answer, language: code, response: response);
  }
}
