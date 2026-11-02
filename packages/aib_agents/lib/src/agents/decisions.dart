import 'package:aib_core/ports.dart';
import 'package:aib_jev/aib_jev.dart';

/// The `decisions:` block of an agent YAML: a decision model (`aib_jev`) inside
/// the agent loop, each use switched on by its own sub-block:
///
/// ```yaml
/// decisions:
///   client: {backend: ollama, model: qwen3:4b, format: qwen3}   # a jev: block
///   language: auto          # en | de | auto — the language questions are asked in
///   maxStateChars: 6000     # what the decision model reads of the episode
///   completionCheck:        # a noul "the goal holds" before done is let out
///     threshold: 0.5
///     maxRejections: 1
///   guard:                  # a noul "wanted and safe" before an act runs
///     allowAbove: 0.7
///     denyBelow: 0.3
///     mode: enforce         # enforce | shadow (record only)
///     onConfirm: proceed    # between the thresholds: proceed | ask | deny
///     onError: allow        # allow | deny
///     intents: [form.submit, form.discard, 'action.*']   # empty = every act
///     keys: []              # envelope keys, for apps without intents
///   selection:              # used by `preparation.strategy: jev`
///     threshold: 0.5
///     minKeep: 5            # see SelectionConfig
/// ```
///
/// Hashed into the manifest with the client block: a decider on another model
/// is another arm. Refuses what it does not implement.
final class DecisionsConfig {
  const DecisionsConfig({
    this.language = 'auto',
    this.maxStateChars = 6000,
    this.completionCheck,
    this.guard,
    this.selection = const SelectionConfig(),
  });

  /// `en`, `de`, … or `auto` (the task's language, English when unclear).
  /// Resolved once per episode from the instruction — the user's words, not
  /// the app's JSON, which is what would otherwise be detected.
  final String language;

  /// Upper bound on the state a completion check or guard reads.
  final int maxStateChars;
  final CompletionCheckConfig? completionCheck;
  final GuardConfig? guard;
  final SelectionConfig selection;

  factory DecisionsConfig.fromJson(JsonMap json) {
    _refuseUnknown(json, const {'client', 'language', 'maxStateChars', 'completionCheck', 'guard', 'selection'}, 'decisions');
    return DecisionsConfig(
      language: json['language'] as String? ?? 'auto',
      maxStateChars: (json['maxStateChars'] as num?)?.toInt() ?? 6000,
      completionCheck: json['completionCheck'] == null ? null : CompletionCheckConfig.fromJson(asJsonMap(json['completionCheck'])),
      guard: json['guard'] == null ? null : GuardConfig.fromJson(asJsonMap(json['guard'])),
      selection: json['selection'] == null ? const SelectionConfig() : SelectionConfig.fromJson(asJsonMap(json['selection'])),
    );
  }

  JsonMap toJson() => {
    'language': language,
    'maxStateChars': maxStateChars,
    if (completionCheck case final check?) 'completionCheck': check.toJson(),
    if (guard case final guard?) 'guard': guard.toJson(),
    'selection': selection.toJson(),
  };
}

/// When `done` may leave the loop.
final class CompletionCheckConfig {
  const CompletionCheckConfig({this.threshold = 0.5, this.maxRejections = 1});

  /// The noul a `done` needs. Not a calibrated probability: choose it on
  /// your own runs, and replay other values from `decisions[].noul`.
  final double threshold;

  /// How often one episode's `done` may be sent back. Bounded, because a
  /// checker wrong about a finished task would otherwise hold the agent until
  /// its budget runs out.
  final int maxRejections;

  factory CompletionCheckConfig.fromJson(JsonMap json) {
    _refuseUnknown(json, const {'threshold', 'maxRejections'}, 'decisions.completionCheck');
    return CompletionCheckConfig(
      threshold: (json['threshold'] as num?)?.toDouble() ?? 0.5,
      maxRejections: (json['maxRejections'] as num?)?.toInt() ?? 1,
    );
  }

  JsonMap toJson() => {'threshold': threshold, 'maxRejections': maxRejections};
}

/// Whether the guard acts on its verdict or only records it.
enum GuardMode {
  /// A denied action does not run.
  enforce,

  /// Every action runs; the verdict is recorded. The way to measure a guard
  /// before trusting it: its verdicts can be scored against the episodes'
  /// outcomes without having changed them.
  shadow,
}

/// What happens to an action the guard is unsure about.
enum GuardOnConfirm {
  /// Let it run and record the doubt.
  proceed,

  /// Ask the user through `user.ask {type: confirm}` and run it only on a yes.
  ask,

  /// Treat it like a denial.
  deny,
}

final class GuardConfig {
  const GuardConfig({
    this.allowAbove = 0.7,
    this.denyBelow = 0.3,
    this.mode = .enforce,
    this.onConfirm = .proceed,
    this.allowOnError = true,
    this.intents = const [],
    this.keys = const [],
  });

  final double allowAbove;
  final double denyBelow;
  final GuardMode mode;
  final GuardOnConfirm onConfirm;

  /// A decision model that fails lets the action through (`onError: allow`) or
  /// stops it (`deny`). Allow is the default: an unreachable guard must not
  /// read as the agent's failure.
  final bool allowOnError;

  /// Intent-name patterns (`form.submit`, `action.*`) reviewed when invoked
  /// through `intents.invoke`.
  final List<String> intents;

  /// Envelope keys reviewed as themselves (an app without intents).
  final List<String> keys;

  /// Whether [envelope] is reviewed. Only acts: an observation changes
  /// nothing, and asking the user is never guarded — it is where a guard's
  /// doubt goes. With neither [intents] nor [keys], every other act is.
  bool covers(Envelope envelope) {
    if (envelope.kind != .act || envelope.isMeta || envelope.key == userAskKey) return false;
    if (intents.isEmpty && keys.isEmpty) return true;
    if (keys.contains(envelope.key)) return true;
    if (envelope.key != intentInvokeKey) return false;
    final intent = envelope.payload['intent'];
    return intent is String && intents.any((pattern) => _globMatches(pattern, intent));
  }

  static const userAskKey = 'user.ask';
  static const intentInvokeKey = 'intents.invoke';

  factory GuardConfig.fromJson(JsonMap json) {
    _refuseUnknown(json, const {'allowAbove', 'denyBelow', 'mode', 'onConfirm', 'onError', 'intents', 'keys'}, 'decisions.guard');
    final allowAbove = (json['allowAbove'] as num?)?.toDouble() ?? 0.7;
    final denyBelow = (json['denyBelow'] as num?)?.toDouble() ?? 0.3;
    if (denyBelow > allowAbove) {
      throw FormatException('decisions.guard: denyBelow ($denyBelow) must not exceed allowAbove ($allowAbove)');
    }
    return GuardConfig(
      allowAbove: allowAbove,
      denyBelow: denyBelow,
      mode: configEnum(GuardMode.values, json['mode'], GuardMode.enforce, 'decisions.guard.mode'),
      onConfirm: configEnum(GuardOnConfirm.values, json['onConfirm'], GuardOnConfirm.proceed, 'decisions.guard.onConfirm'),
      allowOnError: switch (json['onError']) {
        null || 'allow' => true,
        'deny' => false,
        final other => throw FormatException('decisions.guard.onError "$other" is not implemented (allow, deny)'),
      },
      intents: [for (final i in json['intents'] as List? ?? const []) '$i'],
      keys: [for (final k in json['keys'] as List? ?? const []) '$k'],
    );
  }

  JsonMap toJson() => {
    'allowAbove': allowAbove,
    'denyBelow': denyBelow,
    'mode': mode.name,
    'onConfirm': onConfirm.name,
    'onError': allowOnError ? 'allow' : 'deny',
    if (intents.isNotEmpty) 'intents': intents,
    if (keys.isNotEmpty) 'keys': keys,
  };
}

/// What the decision model reads about one catalogue intent.
enum CandidateText {
  /// The summary alone.
  summary,

  /// The summary and the aliases the app published, so a German task meets an
  /// English name. What every selection read until this was configurable.
  summaryAliases,

  /// [summaryAliases] plus whether the intent only reads or changes data.
  summaryAliasesKind;

  /// The text for an intent with [summary], [aliases] and catalogue [kind].
  String render({required String summary, List<String> aliases = const [], String? kind}) {
    if (this == .summary) return summary;
    final text = aliases.isEmpty ? summary : '$summary (also: ${aliases.join(' ')})';
    if (this == .summaryAliases || kind == null) return text;
    return '$text [${kind == 'act' ? 'changes data' : 'reads only'}]';
  }
}

/// What the tool selection adds to what the decision model kept.
enum SelectionExpand {
  none,

  /// Every catalogue intent a kept intent's summary names, one hop: `form.open`
  /// says its ids come "from app.forms". The decision model judges each intent
  /// alone and misses these providers of ids.
  references;

  /// [kept] followed by what it adds, in catalogue order; [summaries] is the
  /// catalogue, name → summary.
  List<String> expand(List<String> kept, Map<String, String> summaries) {
    if (this == none) return kept;
    final keptSet = kept.toSet();
    final named = {for (final name in kept) ...catalogueReferences(summaries)[name] ?? const <String>{}};
    return [
      ...kept,
      for (final name in summaries.keys)
        if (named.contains(name) && !keptSet.contains(name)) name,
    ];
  }
}

/// Which other catalogue intents each intent's summary names, as a whole word.
Map<String, Set<String>> catalogueReferences(Map<String, String> summaries) => {
  for (final MapEntry(key: name, value: summary) in summaries.entries)
    name: {
      for (final other in summaries.keys)
        if (other != name && RegExp('(?<![\\w.])${RegExp.escape(other)}(?!\\w)').hasMatch(summary)) other,
    },
};

/// Relevance selection for the preparer (`preparation.strategy: jev`).
///
/// ```yaml
/// selection:
///   threshold: 0.4
///   minKeep: 5                   # never fewer intents than this (tools only)
///   maxKeep: 5                   # never more than this before expand (tools only)
///   prompt: needed_v1            # a JevSelectionPrompt id, or an inline map
///   candidateText: summaryAliases
///   expand: references           # none | references (tools only)
/// ```
final class SelectionConfig {
  const SelectionConfig({
    this.threshold = 0.5,
    this.perRequest = 50,
    this.maxRowChars = 400,
    this.minKeep = 0,
    this.maxKeep = 0,
    this.prompt = JevSelectionPrompt.neededV1,
    this.promptJson,
    this.candidateText = .summaryAliases,
    this.expand = .none,
  });

  /// A candidate is kept when its noul reaches this. Absolute, unlike
  /// `preparation.minScore`, because a noul already is on a fixed scale.
  final double threshold;

  /// Candidates per request; see [JevAsk.judgeEach].
  final int perRequest;

  /// How much of one listing row the decision model reads.
  final int maxRowChars;

  /// The tool selection keeps at least this many intents, best first, whatever
  /// their noul. A floor, because the noul is not calibrated. Listings and rows
  /// have no floor: "none of these" is a real answer there.
  final int minKeep;

  /// The tool selection keeps at most this many intents, best first, before
  /// [expand] adds their references; 0 is no cap. Every kept intent is a
  /// full-schema tool in the first prompt.
  final int maxKeep;

  /// Asked about catalogue intents and listings, which are tools; rows of a
  /// listing are always asked [JevSelectionPrompt.neededV1].
  final JevSelectionPrompt prompt;

  /// The inline form [prompt] came from, when it was not a built-in id.
  final JsonMap? promptJson;

  final CandidateText candidateText;

  /// See [SelectionExpand]; tools only, after [threshold], [minKeep] and
  /// [maxKeep].
  final SelectionExpand expand;

  factory SelectionConfig.fromJson(JsonMap json) {
    _refuseUnknown(json, const {
      'threshold',
      'perRequest',
      'maxRowChars',
      'minKeep',
      'maxKeep',
      'prompt',
      'candidateText',
      'expand',
    }, 'decisions.selection');
    final minKeep = (json['minKeep'] as num?)?.toInt() ?? 0;
    final maxKeep = (json['maxKeep'] as num?)?.toInt() ?? 0;
    if (maxKeep < 0 || (maxKeep > 0 && maxKeep < minKeep)) {
      throw FormatException('decisions.selection.maxKeep must be 0 (no cap) or at least minKeep ($minKeep), got $maxKeep');
    }
    final rawPrompt = json['prompt'];
    return SelectionConfig(
      threshold: (json['threshold'] as num?)?.toDouble() ?? 0.5,
      perRequest: (json['perRequest'] as num?)?.toInt() ?? 50,
      maxRowChars: (json['maxRowChars'] as num?)?.toInt() ?? 400,
      minKeep: minKeep,
      maxKeep: maxKeep,
      prompt: switch (rawPrompt) {
        null => JevSelectionPrompt.neededV1,
        final String id => JevSelectionPrompt.byId(id),
        final Map<Object?, Object?> map => JevSelectionPrompt.fromJson(asJsonMap(map)),
        _ => throw FormatException('decisions.selection.prompt must be a prompt id or a map, got $rawPrompt'),
      },
      promptJson: rawPrompt is Map ? asJsonMap(rawPrompt) : null,
      candidateText: configEnum(CandidateText.values, json['candidateText'], CandidateText.summaryAliases, 'decisions.selection.candidateText'),
      expand: configEnum(SelectionExpand.values, json['expand'], SelectionExpand.none, 'decisions.selection.expand'),
    );
  }

  JsonMap toJson() => {
    'threshold': threshold,
    'perRequest': perRequest,
    'maxRowChars': maxRowChars,
    // Only what departs from the default, so earlier arms keep their hash.
    if (minKeep > 0) 'minKeep': minKeep,
    if (maxKeep > 0) 'maxKeep': maxKeep,
    if (promptJson != null) 'prompt': promptJson else if (prompt.id != JevSelectionPrompt.neededV1.id) 'prompt': prompt.id,
    if (candidateText != .summaryAliases) 'candidateText': candidateText.name,
    if (expand != .none) 'expand': expand.name,
  };
}

/// A decision model and what the agent asks it: [DecisionsConfig] with a
/// client, and `aib_jev`'s ready-made decisions built from it.
///
/// dart:io-free, so an app builds it from the same `decisions:` block the
/// benchmark ran — with a [JevClient] of its own choosing (a server, the
/// device's llama.cpp) where the harness reads the `client:` block.
final class AgentDecisions {
  AgentDecisions({required this.client, this.config = const DecisionsConfig()});

  /// [DecisionsConfig.fromJson] plus a client from the block's `client:` via
  /// [clientFor] — `JevConfig.clientFromJson` in an app, the environment-
  /// reading factory in the harness.
  factory AgentDecisions.fromJson(JsonMap block, {required JevClient Function(JsonMap clientBlock) clientFor}) {
    if (block['client'] == null) {
      throw const FormatException('decisions requires a "client" block (a jev: block: backend, model, …)');
    }
    return AgentDecisions(client: clientFor(asJsonMap(block['client'])), config: DecisionsConfig.fromJson(block));
  }

  final JevClient client;
  final DecisionsConfig config;

  /// The language to ask in for a task with [instruction].
  String languageFor(String instruction) => JevLanguagePolicy.parse(config.language).resolve(instruction);

  /// Null when the block has no `completionCheck`.
  JevCompletionCheck? completionCheckIn(String language) => switch (config.completionCheck) {
    null => null,
    final check => JevCompletionCheck(client: client, threshold: check.threshold, language: JevLanguagePolicy.fixed(language)),
  };

  /// Null when the block has no `guard`.
  JevGuard? guardIn(String language) => switch (config.guard) {
    null => null,
    final guard => JevGuard(client: client, allowAbove: guard.allowAbove, denyBelow: guard.denyBelow, language: JevLanguagePolicy.fixed(language)),
  };

  /// [prompt] overrides the configured one (rows of a listing are no tools).
  JevSelector selectorIn(String language, {JevSelectionPrompt? prompt}) => JevSelector(
    client: client,
    prompt: prompt ?? config.selection.prompt,
    language: JevLanguagePolicy.fixed(language),
    perRequest: config.selection.perRequest,
  );
}

/// One decision the loop asked for, as it rides on `AgentDecision.extra`
/// under [key] — facts only (what was asked, what came back, what the loop
/// did), so the `decisions` metrics are a trace derivation.
final class DecisionRecord {
  const DecisionRecord({
    required this.purpose,
    required this.verdict,
    this.noul,
    this.threshold,
    this.subject,
    this.latencyMs = 0,
    this.model,
    this.language,
    this.error,
    this.enforced = true,
    this.scores,
  });

  static const key = 'decisions';

  /// `completion`, `guard`, `select`.
  final String purpose;

  /// `accept` / `reject` for a completion check; `allow` / `confirm` /
  /// `deny` for a guard; `error` when the decision model failed.
  final String verdict;
  final double? noul;
  final double? threshold;

  /// What was judged: the intent or key of a guarded action.
  final String? subject;
  final int latencyMs;
  final String? model;
  final String? language;
  final String? error;

  /// False when the verdict was recorded but not acted on (shadow mode, a
  /// check past its rejection limit).
  final bool enforced;

  /// A selection's noul per candidate asked, so a selection threshold can be
  /// replayed from the trace instead of re-run. Null for the one-question
  /// decisions, whose [noul] says it all.
  final Map<String, double>? scores;

  JsonMap toJson() => {
    'purpose': purpose,
    'verdict': verdict,
    'noul': ?noul,
    'threshold': ?threshold,
    'subject': ?subject,
    'latencyMs': latencyMs,
    'model': ?model,
    'language': ?language,
    'error': ?error,
    if (!enforced) 'enforced': false,
    'scores': ?scores,
  };
}

/// `form.*` matches `form.submit`; anything else must be equal.
bool _globMatches(String pattern, String name) {
  if (!pattern.contains('*')) return pattern == name;
  final regex = RegExp('^${pattern.split('*').map(RegExp.escape).join('.*')}\$');
  return regex.hasMatch(name);
}

/// The [values] entry [raw] names; [fallback] when absent. A name nothing
/// implements is refused.
T configEnum<T extends Enum>(List<T> values, Object? raw, T fallback, String field) {
  if (raw == null) return fallback;
  return values.asNameMap()[raw] ?? (throw FormatException('$field "$raw" is not implemented (${values.map((v) => v.name).join(', ')})'));
}

void _refuseUnknown(JsonMap json, Set<String> known, String block) {
  final unknown = json.keys.where((k) => !known.contains(k)).toList();
  if (unknown.isNotEmpty) {
    throw FormatException('$block: unknown key(s) ${unknown.join(', ')} (known: ${known.join(', ')})');
  }
}
