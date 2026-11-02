import 'package:aib_core/ports.dart';

import 'decisions.dart' show SelectionExpand, configEnum;
import 'retrieval.dart';

export 'retrieval.dart';

/// How the preparing agent decides what to fetch before its first LLM call.
enum PreparationStrategy {
  /// No preparation. [PreparingAgent] is then [HybridAgent] with another
  /// prompt hash — the control condition that separates "preparation helped"
  /// from "the new prompt helped".
  none,

  /// Exact and near-exact matches of catalogue names and summaries against the
  /// task's words. Deterministic, no LLM call.
  rules,

  /// BM25 over the catalogue's names, summaries and aliases. Deterministic,
  /// no model call.
  lexical,

  /// Cosine similarity over a pinned embedding model. The answer to a query
  /// and a catalogue in different languages, which no amount of term matching
  /// reaches.
  vector,

  /// [lexical] and [vector] fused by reciprocal rank fusion — the standard
  /// recipe, because sparse and dense retrieval fail in opposite directions.
  hybrid,

  /// A decision model (`decisions:` block) judges every candidate on its own: a
  /// `noul` "this is needed for the task" per catalogue intent, listing and
  /// row. Absolute threshold (`decisions.selection.threshold`), so "nothing is
  /// relevant" is an answer it can give.
  jev,
}

/// What the preparer may speculate about.
enum PreparationAxis {
  /// Promote intents the task implicates to callable tools, without spending a
  /// turn on `intents.describe`.
  tools,

  /// Run the app's listing observations up front, narrowed by a derived query.
  discovery,

  /// Resolve the names in the task to the app's own identifiers. Needs an
  /// app-specific resolver; refused rather than approximated.
  entities,

  /// Pre-read and pre-aggregate row data. Off by design: what the app *holds*
  /// is what the task may be about to change, and a stale pre-aggregate is a
  /// wrong answer with a confident source.
  data,

  /// Follow-up reads driven by a listing's kept rows ([FetchRule]): search
  /// the data list the preparer judged relevant for the thing the task
  /// names. Reads only — a rule whose intent the catalogue marks `act` is
  /// refused at run time — and within the prefetch budget. The app's
  /// vocabulary lives in the rules, never in the framework.
  fetch,
}

/// Whether a discovery listing is narrowed by the task's longest word.
enum DiscoveryQuery {
  /// Narrowed: fewer rows, and a lexical preparer's only way to find the one
  /// that matters.
  narrowest,

  /// The whole listing — for a preparer that selects rows itself (`jev`),
  /// where narrowing by one word would hide a synonym it could have matched.
  none,
}

/// What the escape hatch lists of the catalogue.
enum HatchScope {
  /// Every intent in scope, with its summary.
  all,

  /// The intents the preparer judged relevant with their summaries; the rest
  /// by name only, so they stay reachable through `describe_intents` without
  /// costing a summary each. "Ignore irrelevant tools", without making them
  /// unreachable.
  relevant,
}

/// How the prepared episode is laid out in the request.
enum PreparationLayout {
  /// The task line first, the prepared intents among the other tools, and the
  /// described schemas repeated in the briefing.
  taskFirst,

  /// Everything the same for every task first, so a local server's prompt cache
  /// carries it from one task to the next: the framework's own tools before the
  /// prepared intents, the task line after the briefing, and the described
  /// intents named in the briefing rather than repeated. The tool surface stays
  /// the standard one: full schemas, fixed for the episode once prepared.
  ///
  /// Ollama renders the tools right after the system prompt, and on a
  /// sliding-window model it can only restore a cached prefix from a checkpoint
  /// about 1k tokens before the end of an earlier prompt, so the per-task part
  /// must be last and short.
  shared,

  /// [shared], with two more things moved out of the per-task part:
  ///
  /// - The environment's envelope listing goes into the system message.
  /// - The escape hatch's catalogue leaves out the intents already prepared, which
  ///   are already callable.
  sharedListing;

  /// Whether the layout shares the prefix ([shared] or [sharedListing]).
  bool get isShared => this != taskFirst;
}

/// One follow-up read of the `fetch` axis.
///
/// ```yaml
/// fetch:
///   - after: app.endpoints         # the listing whose kept rows drive it
///     intent: data.search          # an intent, or a declared envelope key
///     params: {endpointId: '{row.id}', query: '{query}', limit: 5}
///     maxRows: 2                   # for the best two kept rows
/// ```
///
/// Placeholders: `{row.<field>}` (a field of the kept row), `{query}` (the
/// task's longest word), `{task}` (the instruction). A value that is exactly
/// one placeholder keeps the field's type, so an integer id stays an integer.
final class FetchRule {
  const FetchRule({required this.after, required this.intent, this.params = const {}, this.maxRows = 1});

  /// Intent name or envelope key of the listing, as the preparer sent it.
  final String after;
  final String intent;
  final JsonMap params;
  final int maxRows;

  factory FetchRule.fromJson(JsonMap json) {
    final after = json['after'];
    final intent = json['intent'];
    if (after is! String || intent is! String) {
      throw const FormatException('preparation.fetch: every rule needs "after" and "intent"');
    }
    return FetchRule(after: after, intent: intent, params: asJsonMap(json['params']), maxRows: (json['maxRows'] as num?)?.toInt() ?? 1);
  }

  /// [params] for one kept [row] of a task with [query] and [task].
  JsonMap paramsFor(JsonMap row, {String? query, required String task}) {
    Object? fill(Object? value) {
      if (value is Map) return {for (final e in value.entries) '${e.key}': fill(e.value)};
      if (value is List) return [for (final v in value) fill(v)];
      if (value is! String) return value;
      Object? resolve(String name) => switch (name) {
        'query' => query,
        'task' => task,
        _ when name.startsWith('row.') => _field(row, name.substring(4)),
        _ => null,
      };
      final whole = RegExp(r'^\{([^{}]+)\}$').firstMatch(value);
      if (whole != null) return resolve(whole.group(1)!);
      return value.replaceAllMapped(RegExp(r'\{([^{}]+)\}'), (m) => '${resolve(m.group(1)!) ?? ''}');
    }

    return {for (final e in params.entries) e.key: ?fill(e.value)};
  }

  static Object? _field(JsonMap row, String path) {
    Object? current = row;
    for (final part in path.split('.')) {
      if (current is! Map) return null;
      current = current[part];
    }
    return current;
  }

  JsonMap toJson() => {'after': after, 'intent': intent, if (params.isNotEmpty) 'params': params, 'maxRows': maxRows};
}

/// The `preparation:` block of an agent YAML. Hashed into the manifest, so a
/// run always says which preparer produced it.
///
/// ```yaml
/// preparation:
///   strategy: lexical
///   prepare: [tools, discovery]
///   topK: 5
///   minScore: 0.25
///   discoveryKeys: [app.forms, app.endpoints]
///   queryParam: query
///   budget: {maxEnvelopes: 4, maxBriefingBytes: 4096}
///   escapeHatch: true
///   analyzer: plain            # or stem
///   preparedHint: true         # name the prepared intents as callable
///   layout: shared             # taskFirst | shared | sharedListing (see PreparationLayout)
///   expand: references         # none | references, after topK (not jev: see decisions.selection)
/// ```
final class PreparationConfig {
  const PreparationConfig({
    this.strategy = .none,
    this.prepare = const [PreparationAxis.tools],
    this.topK = 5,
    this.minScore = 0.25,
    this.rrfK = 60,
    this.discoveryKeys = const [],
    this.queryParam = 'query',
    this.maxEnvelopes = 4,
    this.maxBriefingBytes = 4096,
    this.escapeHatch = true,
    this.analyzer = .plain,
    this.fetch = const [],
    this.discoveryQuery = .narrowest,
    this.hatchScope = .all,
    this.preparedHint = false,
    this.layout = .taskFirst,
    this.expand = .none,
  });

  final PreparationStrategy strategy;
  final List<PreparationAxis> prepare;

  /// How many catalogue entries or listing rows survive a reduction.
  final int topK;

  /// Below this share of the best score an item is not worth its digest bytes.
  /// Relative, so it means the same thing whether the scores underneath are
  /// BM25 or cosine.
  final double minScore;

  /// The rank-fusion constant of [PreparationStrategy.hybrid]. 60 is the value
  /// from the original RRF paper; lower sharpens the head of each list.
  final int rrfK;

  /// Envelope keys of the app's listing observations, in the order they are
  /// prefetched. Empty = derive them from the environment descriptor. Named by
  /// configuration because they are one app's vocabulary.
  final List<String> discoveryKeys;

  /// Parameter a listing takes to narrow itself.
  final String queryParam;

  /// Prefetch turns, the bootstrap observation included.
  final int maxEnvelopes;

  /// Hard ceiling on the briefing. A digest that silently hides the answer is
  /// the same failure class as an oracle that cannot see the right thing, so
  /// the briefing says what it dropped.
  final int maxBriefingBytes;

  /// Keep `describe_intents` offered and list every in-scope intent name in
  /// the briefing. Never false in a shipped profile: tool retrieval is the
  /// only subtractive lever here, and without the hatch a retrieval miss is an
  /// unreachable capability.
  final bool escapeHatch;

  /// How the lexical rankers turn text into terms. `stem` adds a light
  /// German/English stemmer and compound splitting; `plain` is the default so
  /// existing configurations keep their hash and their behaviour.
  final TermAnalyzer analyzer;

  /// The `fetch` axis' rules, in order.
  final List<FetchRule> fetch;

  final DiscoveryQuery discoveryQuery;
  final HatchScope hatchScope;

  /// Say in the briefing which intents are already callable tools, so the model
  /// does not spend its first turn describing them.
  final bool preparedHint;

  final PreparationLayout layout;

  /// What the tools axis adds to the top-k intents a ranking kept: under
  /// `references`, the intents their summaries name (`form.open` → its id
  /// provider `app.forms`). A ranker scores each intent against the task
  /// alone and misses exactly these. For `jev` the same expansion is
  /// `decisions.selection.expand`, applied before its own cut.
  final SelectionExpand expand;

  /// Whether the strategy needs a decision model (`decisions:` block).
  bool get needsDecisions => strategy == .jev;

  /// Whether the strategy needs an embedding model.
  bool get isDense => strategy == .vector || strategy == .hybrid;

  bool get isActive => strategy != .none;

  bool prepares(PreparationAxis axis) => prepare.contains(axis);

  factory PreparationConfig.fromJson(JsonMap json) {
    final budget = asJsonMap(json['budget']);
    final axes = _axes(json['prepare']);
    final fetch = [for (final rule in json['fetch'] as List? ?? const []) FetchRule.fromJson(asJsonMap(rule))];
    if (axes.contains(PreparationAxis.fetch) && fetch.isEmpty) {
      throw const FormatException('preparation axis "fetch" needs "fetch" rules (after, intent, params)');
    }
    return PreparationConfig(
      strategy: _strategy(json['strategy']),
      prepare: axes,
      topK: (json['topK'] as num?)?.toInt() ?? 5,
      minScore: (json['minScore'] as num?)?.toDouble() ?? 0.25,
      rrfK: (json['rrfK'] as num?)?.toInt() ?? 60,
      discoveryKeys: [for (final key in json['discoveryKeys'] as List? ?? const []) '$key'],
      queryParam: json['queryParam'] as String? ?? 'query',
      maxEnvelopes: (budget['maxEnvelopes'] as num?)?.toInt() ?? 4,
      maxBriefingBytes: (budget['maxBriefingBytes'] as num?)?.toInt() ?? 4096,
      escapeHatch: json['escapeHatch'] as bool? ?? true,
      analyzer: switch (json['analyzer']) {
        null || 'plain' => TermAnalyzer.plain,
        'stem' => TermAnalyzer.stem,
        final other => throw FormatException('preparation analyzer "$other" is not implemented (plain, stem)'),
      },
      fetch: fetch,
      discoveryQuery: configEnum(DiscoveryQuery.values, json['discoveryQuery'], DiscoveryQuery.narrowest, 'preparation discoveryQuery'),
      hatchScope: configEnum(HatchScope.values, json['escapeHatchScope'], HatchScope.all, 'preparation escapeHatchScope'),
      preparedHint: json['preparedHint'] as bool? ?? false,
      layout: configEnum(PreparationLayout.values, json['layout'], PreparationLayout.taskFirst, 'preparation layout'),
      expand: switch (configEnum(SelectionExpand.values, json['expand'], SelectionExpand.none, 'preparation expand')) {
        .references when _strategy(json['strategy']) == .jev => throw const FormatException(
          'preparation.expand is for the rankers; a jev preparer expands in decisions.selection.expand',
        ),
        final expand => expand,
      },
    );
  }

  /// An unimplemented strategy is refused, not silently replaced: a config
  /// that names `vector` and runs `lexical` produces a number for an
  /// experiment nobody ran.
  static PreparationStrategy _strategy(Object? value) {
    if (value == null) return .none;
    for (final strategy in PreparationStrategy.values) {
      if (strategy.name == value) return strategy;
    }
    throw FormatException(
      'preparation strategy "$value" is not implemented '
      '(${PreparationStrategy.values.map((s) => s.name).join(', ')})',
    );
  }

  static List<PreparationAxis> _axes(Object? value) {
    if (value == null) return const [PreparationAxis.tools];
    final axes = [
      for (final raw in value as List)
        PreparationAxis.values.firstWhere((axis) => axis.name == raw, orElse: () => throw FormatException('unknown preparation axis "$raw"')),
    ];
    for (final axis in axes) {
      if (axis == .entities || axis == .data) {
        throw FormatException(
          'preparation axis "${axis.name}" is not implemented — it needs an '
          'app-specific resolver',
        );
      }
    }
    return axes;
  }

  JsonMap toJson() => {
    'strategy': strategy.name,
    'prepare': [for (final axis in prepare) axis.name],
    'topK': topK,
    'minScore': minScore,
    if (strategy == .hybrid) 'rrfK': rrfK,
    if (discoveryKeys.isNotEmpty) 'discoveryKeys': discoveryKeys,
    'queryParam': queryParam,
    'budget': {'maxEnvelopes': maxEnvelopes, 'maxBriefingBytes': maxBriefingBytes},
    'escapeHatch': escapeHatch,
    if (analyzer != .plain) 'analyzer': analyzer.name,
    // Only when set, so every configuration from before these keys keeps
    // its hash.
    if (fetch.isNotEmpty) 'fetch': [for (final rule in fetch) rule.toJson()],
    if (discoveryQuery != .narrowest) 'discoveryQuery': discoveryQuery.name,
    if (hatchScope != .all) 'escapeHatchScope': hatchScope.name,
    if (preparedHint) 'preparedHint': true,
    if (layout != .taskFirst) 'layout': layout.name,
    if (expand != .none) 'expand': expand.name,
  };
}
