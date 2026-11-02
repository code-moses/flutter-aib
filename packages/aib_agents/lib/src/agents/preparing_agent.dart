import 'dart:convert';
import 'dart:math';

import 'package:aib_core/ports.dart';
import 'package:aib_jev/aib_jev.dart' show JevSelectionPrompt;

import '../conventions.dart';
import '../llm/llm_client.dart';
import 'decisions.dart';
import 'hybrid_agent.dart';
import 'preparation_config.dart';
import 'prompts.dart';
import 'strategies.dart';

/// A hybrid agent with a preparation pass in front of the loop (ADR 0014): read
/// the task, decide what the agent will likely need, fetch it, and hand the
/// model one digested briefing plus a pre-selected tool surface.
///
/// It inherits router, strategies, loop, retry policy and telemetry from
/// [HybridAgent]. Three things differ: the bootstrap plan, the briefing, and
/// the prompt.
///
/// Preparation runs **inside** the loop, as envelopes the engine executes, so
/// it stays in the trace and the budget. It is speculative and strictly
/// additive: wrong preparation costs tokens, never reachability.
final class PreparingAgent extends HybridAgent {
  /// A dense strategy without an embedding client is refused here.
  PreparingAgent({
    required super.client,
    super.router,
    super.config,
    super.configBlocks,
    super.embeddingClient,
    super.decisions,
    this.preparation = const PreparationConfig(),
  }) {
    if (preparation.isDense && embeddingClient == null) {
      throw ArgumentError(
        'preparation strategy "${preparation.strategy.name}" needs an '
        'embedding: block in the agent config',
      );
    }
    if (preparation.needsDecisions && decisions == null) {
      throw ArgumentError(
        'preparation strategy "${preparation.strategy.name}" needs a '
        'decisions: block (with a client) in the agent config',
      );
    }
  }

  /// Hashed into the manifest by the generic config-block mechanism,
  /// so `configBlocks['preparation']` is what identifies a preparation run.
  final PreparationConfig preparation;

  @override
  String get agentId => 'prepared';

  /// The preparation in the manifest whether or not the config arrived as a
  /// `preparation:` block: the prefetch metrics read it from there to tell an
  /// active preparer that found nothing from an agent that prepares nothing.
  @override
  JsonMap get manifestMetadata => {...super.manifestMetadata, 'preparation': preparation.toJson()};

  @override
  String get defaultPromptVersion => switch (config.toolSurface) {
    .promoted => 'prepared_v1',
    .fixed => 'prepared_v3',
  };

  @override
  Map<String, String> get promptFamily => Prompts.preparedFamily[config.toolSurface]!;

  bool get _sharedLayout => preparation.isActive && preparation.layout.isShared;

  bool get _sharedListing => preparation.isActive && preparation.layout == .sharedListing;

  /// Under [PreparationLayout.sharedListing] the envelope listing is part of
  /// the shared prefix.
  @override
  bool get listingInSystem => _sharedListing;

  /// Under the shared layout the task line follows the briefing, so nothing
  /// before the prepared part names the task.
  @override
  bool get taskLineLast => super.taskLineLast || _sharedLayout;

  /// Under the shared layout the intents the episode promoted go last, after
  /// the framework's own tools, which are the same for every task.
  @override
  List<LlmTool> orderTools(List<LlmTool> tools) {
    if (!_sharedLayout) return tools;
    bool promoted(LlmTool tool) => tool.name.startsWith(IntentStrategy.toolPrefix);
    return [...tools.where((tool) => !promoted(tool)), ...tools.where(promoted)];
  }

  /// Under the shared layout, after the episode and off its clock, the prefix
  /// every task shares — system prompt and framework tools — is primed once,
  /// so the next task's first call restores it instead of prefilling it.
  @override
  bool get warmsPrefix => super.warmsPrefix || _sharedLayout;

  /// The framework's own tools: the prepared intents differ per task.
  @override
  List<LlmTool> get sharedPrefixTools => [
    for (final tool in requestTools)
      if (!tool.name.startsWith(IntentStrategy.toolPrefix)) tool,
  ];

  /// Prefetched items, in the order they were fetched.
  final List<JsonMap> _items = [];

  /// Digests waiting to become the briefing.
  final List<String> _digests = [];

  /// Intent names and summaries the catalogue reported, for the escape hatch.
  final Map<String, String> _catalogue = {};

  /// Intents the catalogue marks `act`: a fetch rule never invokes one.
  final Set<String> _actIntents = {};

  /// What the ranking judged relevant (above threshold, before top-k) — the
  /// escape hatch's `relevant` scope reads it.
  Set<String> _relevant = const {};

  /// Every noul the decision model gave this episode, by candidate, so a
  /// listing it already judged as a catalogue intent is not asked about twice.
  final Map<String, double> _selectionScores = {};

  /// Kept rows per listing label, for the fetch axis.
  final Map<String, List<Object?>> _keptRows = {};

  /// What retrieval scores against: the name, the summary, and every alias the
  /// app published for it. Kept apart from [_catalogue] because the aliases
  /// exist to be *matched*, not to be shown — the briefing prints summaries.
  final Map<String, String> _searchText = {};

  /// Aliases and kind per intent, for the decision model's candidate text.
  final Map<String, List<String>> _aliases = {};
  final Map<String, String> _kinds = {};

  /// Intents the plan described successfully: callable tools before turn 1.
  final List<String> _preparedIntents = [];

  late TextAnalyzer _analyzer;
  Bm25Index? _catalogueIndex;

  var _embedTokens = 0;
  var _embedCalls = 0;

  /// Why dense ranking fell back to lexical in this episode, if it did.
  String? _denseFallback;

  /// What the plan did not prepare, named in the briefing.
  final List<String> _omitted = [];

  JsonMap _pendingExtra = const {};

  /// The task's words as written, for narrowing an app's own search.
  List<String> _words = const [];

  /// The task's retrieval terms under the configured analyzer.
  List<String> _terms = const [];
  var _envelopesPlanned = 0;
  var _catalogueSeen = false;

  @override
  Future<void> startEpisode(TaskSpec task, EnvironmentDescriptor environment) async {
    _items.clear();
    _digests.clear();
    _catalogue.clear();
    _actIntents.clear();
    _relevant = const {};
    _selectionScores.clear();
    _keptRows.clear();
    _searchText.clear();
    _aliases.clear();
    _kinds.clear();
    _preparedIntents.clear();
    _analyzer = TextAnalyzer(preparation.analyzer);
    _catalogueIndex = null;
    _embedTokens = 0;
    _embedCalls = 0;
    _denseFallback = null;
    _omitted.clear();
    _pendingExtra = const {};
    _envelopesPlanned = 0;
    _catalogueSeen = false;
    _words = TextAnalyzer.words(task.instruction);
    _terms = _analyzer.query(task.instruction);
    _descriptor = environment;
    await super.startEpisode(task, environment);
  }

  EnvironmentDescriptor? _descriptor;

  @override
  List<Envelope> bootstrapPlan() {
    final plan = super.bootstrapPlan();
    _envelopesPlanned = plan.length;
    return plan;
  }

  /// Digest facts, plus whatever the preparer's own model calls cost since the
  /// last envelope, reported on the next one whatever happened to the prefetch.
  @override
  JsonMap get pendingExtra {
    final prepared = {
      ...asJsonMap(_pendingExtra['prepared']),
      if (_embedCalls > 0) 'embedCalls': _embedCalls,
      if (_embedTokens > 0) 'embedTokens': _embedTokens,
      'denseFallback': ?_denseFallback,
      'jevFallback': ?_jevFallback,
    };
    _pendingExtra = const {};
    _embedCalls = 0;
    _embedTokens = 0;
    _denseFallback = null;
    _jevFallback = null;
    return prepared.isEmpty ? const {} : {'prepared': prepared};
  }

  /// A plan result never enters the conversation as itself: it is reduced, and
  /// the reductions leave together as one briefing. Pasting a listing into turn
  /// 1 would pay for discovery and re-send it on every later turn.
  @override
  Future<void> onPlanResult(Envelope sent, EnvelopeResult result, String rendered) async {
    if (!preparation.isActive) {
      await super.onPlanResult(sent, result, rendered);
      return;
    }

    if (sent.key == router.bootstrap && !_catalogueSeen) {
      _catalogueSeen = true;
      _readCatalogue(result.payload);
      enqueuePlan(await _planAfterCatalogue());
    } else {
      await _digest(sent, result, rendered);
      if (preparation.prepares(PreparationAxis.fetch)) enqueuePlan(_planFetches(sent));
    }

    if (plannedRemaining == 0) addUserMessage(_briefing());
  }

  /// Turns the catalogue into the rest of the plan: the intents the task
  /// implicates, then the listings, within the envelope budget.
  Future<List<Envelope>> _planAfterCatalogue() async {
    final planned = <Envelope>[];
    var left = preparation.maxEnvelopes - _envelopesPlanned;

    // Ranked only when something reads the ranking: a dense strategy pays
    // an embedding call for it, and an arm that prepares no tools never did.
    final ranked = preparation.prepares(PreparationAxis.tools) || preparation.hatchScope == .relevant ? await _rank() : const <String>[];
    _relevant = ranked.toSet();
    if (preparation.prepares(PreparationAxis.tools)) {
      final names = preparation.expand.expand(ranked.take(preparation.topK).toList(), _catalogue);
      if (names.isEmpty) {
        _omitted.add('no intent matched the task well enough to describe');
      } else if (left > 0) {
        planned.add(Envelope(key: 'intents.describe', kind: .observe, payload: {'names': names}));
        left--;
      }
    }

    if (preparation.prepares(PreparationAxis.discovery)) {
      final keys = await _discoveryKeys();
      final query = preparation.discoveryQuery == .narrowest ? _narrowestTerm() : null;
      for (final key in keys) {
        if (left <= 0) {
          _omitted.add('$key (out of prefetch budget)');
          continue;
        }
        planned.add(_discoveryEnvelope(key, query));
        left--;
      }
    }

    _envelopesPlanned += planned.length;
    return planned;
  }

  /// A configured listing as the environment accepts it. A name the descriptor
  /// does not declare is an *intent*, reached through `intents.invoke`; sent as
  /// a bare key it would come back `unsupported`.
  Envelope _discoveryEnvelope(String key, String? query) => _readEnvelope(key, {preparation.queryParam: ?query});

  /// A read of [key] with [params], through `intents.invoke` when the key is
  /// an intent rather than a declared envelope key.
  Envelope _readEnvelope(String key, JsonMap params) {
    final declared = {for (final spec in _descriptor?.envelopes ?? const <EnvelopeSpec>[]) spec.key};
    if (declared.contains(key) || !declared.contains('intents.invoke')) {
      return Envelope(key: key, kind: .observe, payload: params);
    }
    return Envelope(key: 'intents.invoke', kind: .observe, payload: {'intent': key, 'params': params});
  }

  /// The fetch axis: follow-up reads for the rows a listing kept, within the
  /// prefetch budget, after the listing named by each rule.
  List<Envelope> _planFetches(Envelope sent) {
    final label = IntentConventions.intentOf(sent.key, sent.payload) ?? sent.key;
    final rows = _keptRows[label];
    if (rows == null) return const [];
    final planned = <Envelope>[];
    for (final rule in preparation.fetch) {
      if (rule.after != label) continue;
      if (_actIntents.contains(rule.intent)) {
        // Preparation reads; it never changes the app. A rule that names an
        // act is a config error, and running it would be a side effect the
        // agent never decided on.
        _omitted.add('${rule.intent} (the catalogue marks it act; fetch only reads)');
        continue;
      }
      if (rows.isEmpty) {
        _omitted.add('${rule.intent} (no row of $label was kept to fetch for)');
        continue;
      }
      for (final row in rows.take(rule.maxRows)) {
        if (_envelopesPlanned + planned.length >= preparation.maxEnvelopes) {
          _omitted.add('${rule.intent} for more rows of $label (out of prefetch budget)');
          break;
        }
        final params = rule.paramsFor(asJsonMap(row), query: _narrowestTerm(), task: currentTask?.instruction ?? '');
        planned.add(_readEnvelope(rule.intent, params));
      }
    }
    _envelopesPlanned += planned.length;
    return planned;
  }

  /// Configured keys, or the observe keys the environment declares whose own
  /// description matches the task. The framework must not learn an app's
  /// listing vocabulary.
  ///
  /// Under `jev` the configured keys are candidates and the decision model
  /// picks among them.
  Future<List<String>> _discoveryKeys() async {
    final configured = preparation.discoveryKeys;
    if (preparation.strategy == .jev) {
      final candidates = configured.isNotEmpty
          ? {for (final key in configured) key: _catalogue[key] ?? _declaredDescription(key) ?? key}
          : {
              for (final spec in _descriptor?.envelopes ?? const <EnvelopeSpec>[])
                if (spec.kind == .observe && spec.key != router.bootstrap && !spec.key.startsWith('intents.')) spec.key: spec.description ?? spec.key,
            };
      final kept = await _select(candidates, purpose: 'select-listings');
      final skipped = candidates.keys.where((key) => !kept.contains(key)).toList();
      if (skipped.isNotEmpty) _omitted.add('${skipped.join(', ')} (judged not needed for this task)');
      return kept.take(preparation.topK).toList();
    }
    if (configured.isNotEmpty) {
      return configured;
    }
    final documents = {
      for (final spec in _descriptor?.envelopes ?? const <EnvelopeSpec>[])
        if (spec.kind == .observe && spec.key != router.bootstrap && !spec.key.startsWith('intents.'))
          spec.key: '${spec.key} ${spec.description ?? ''}',
    };
    return rankAbove(_lexicalScores(Bm25Index(documents, _analyzer)), preparation.minScore, requireMatch: true).take(preparation.topK).toList();
  }

  String? _declaredDescription(String key) {
    for (final spec in _descriptor?.envelopes ?? const <EnvelopeSpec>[]) {
      if (spec.key == key) return spec.description;
    }
    return null;
  }

  /// Candidates the decision model judges needed, most needed first. Scores
  /// already given this episode are reused; the rest are asked in one
  /// selection, and its spend rides on the next envelope as a side call.
  ///
  /// A decision model that fails keeps every candidate, in the given order:
  /// preparation is speculative, and the escape hatch covers the rest.
  ///
  /// [minKeep] keeps that many of the best candidates whatever their noul;
  /// [maxKeep] (0: no cap) keeps no more than that many.
  Future<List<String>> _select(Map<String, String> candidates, {required String purpose, int minKeep = 0, int maxKeep = 0}) async {
    final decisions = this.decisions!;
    final threshold = decisions.config.selection.threshold;
    final missing = {
      for (final e in candidates.entries)
        if (!_selectionScores.containsKey(e.key)) e.key: e.value,
    };
    if (missing.isNotEmpty) {
      final watch = Stopwatch()..start();
      try {
        final selection = await decisions
            .selectorIn(decisionLanguage, prompt: purpose == 'select-rows' ? JevSelectionPrompt.neededV1 : null)
            .selectFor(task: currentTask?.instruction ?? '', candidates: missing, threshold: threshold, minKeep: minKeep);
        _selectionScores.addAll(selection.scores);
        final spend = selection.spend;
        recordDecision(
          DecisionRecord(
            purpose: purpose,
            verdict: 'kept ${selection.selected.length}/${missing.length}',
            threshold: threshold,
            latencyMs: spend.latencyMs > 0 ? spend.latencyMs : watch.elapsedMilliseconds,
            model: spend.model,
            language: selection.language,
            scores: selection.scores,
          ),
          sideCall: SideCall(
            purpose: purpose,
            model: spend.model,
            tokensPrompt: spend.inputTokens,
            tokensCompletion: spend.outputTokens,
            latencyMs: spend.latencyMs,
            calls: spend.requests,
          ),
        );
      } on Exception catch (e) {
        recordDecision(DecisionRecord(purpose: purpose, verdict: 'error', latencyMs: watch.elapsedMilliseconds, error: '$e', enforced: false));
        _jevFallback = '$e';
        return candidates.keys.toList();
      }
    }
    final ranked = candidates.keys.toList()..sort((a, b) => (_selectionScores[b] ?? 0).compareTo(_selectionScores[a] ?? 0));
    final kept = [
      for (final (rank, key) in ranked.indexed)
        if ((_selectionScores[key] ?? 0) >= threshold || rank < minKeep) key,
    ];
    return maxKeep > 0 && kept.length > maxKeep ? kept.sublist(0, maxKeep) : kept;
  }

  /// Why the decision model's selection fell back to keeping everything.
  String? _jevFallback;

  /// The task's longest word: a listing is narrowed by the most specific thing
  /// the task names, in German usually the compound noun. Not stemmed, because
  /// the app's own search reads it.
  String? _narrowestTerm() {
    if (_words.isEmpty) return null;
    return _words.reduce((a, b) => b.length > a.length ? b : a);
  }

  /// Reads the catalogue the *environment* published, not the rendering the
  /// model gets: the aliases retrieval ranks on are dropped from that
  /// rendering.
  void _readCatalogue(JsonMap payload) {
    for (final raw in payload['intents'] as List? ?? const []) {
      final intent = asJsonMap(raw);
      if (intent['name'] case final String name) {
        if (intent['kind'] == 'act') _actIntents.add(name);
        final summary = '${intent['summary'] ?? ''}';
        final aliases = [for (final alias in intent['aliases'] as List? ?? const []) '$alias'];
        _catalogue[name] = summary;
        _aliases[name] = aliases;
        if (intent['kind'] case final String kind) _kinds[name] = kind;
        _searchText[name] = [name, summary, ...aliases].join(' ');
      }
    }
    final index = Bm25Index(_searchText, _analyzer);
    _catalogueIndex = index;
    // Compounds in the task can only be split once the vocabulary is known.
    _analyzer.vocabulary = index.vocabulary;
    _terms = _analyzer.query(currentTask?.instruction ?? '');
  }

  /// Reduces one prefetched result and records what it bought.
  Future<void> _digest(Envelope sent, EnvelopeResult result, String rendered) async {
    // A failed or unsupported result is not data. Digesting one puts an error
    // string in the briefing, records an item nothing can ever use, and bills
    // its bytes as waste — which is precisely what the first live run did.
    if (result.status != .ok) {
      _omitted.add('${sent.key} (${result.status.name})');
      return;
    }
    final payload = result.payload;
    final (text, values) = switch (sent.key) {
      'intents.describe' => (rendered, const <String>[]),
      _ => await _reduceListing(sent, payload, rendered),
    };
    final names = [for (final name in sent.payload['names'] as List? ?? const []) '$name'];
    if (sent.key == 'intents.describe') _preparedIntents.addAll(names);

    // Never cut a description: its schemas are written down nowhere else —
    // except, under the shared layout, in the tools it promoted, so the
    // briefing names them instead of repeating them.
    final capped = sent.key == 'intents.describe' ? (_sharedLayout ? '' : text) : _cap(text);
    if (capped.isNotEmpty) _digests.add('${sent.key}: $capped');

    final items = sent.key == 'intents.describe'
        ? [
            // The digest's bytes shared out across the names it describes,
            // so the items sum to what entered the conversation.
            for (final name in names) {'id': 'tool:$name', 'bytes': capped.isEmpty ? name.length : capped.length ~/ names.length},
          ]
        : [
            {
              // Named by the intent for an invoked listing: every listing
              // reached through `intents.invoke` shared one key.
              'id':
                  'obs:${IntentConventions.label(sent.key, sent.payload)}'
                  '#${_fingerprint(capped)}',
              'bytes': capped.length,
              if (values.isNotEmpty) 'values': values,
            },
          ];
    _items.addAll(items);
    _pendingExtra = {
      'prepared': {'items': items, 'bytes': capped.length},
    };
  }

  /// Top-k rows of a listing, scored against the task, plus what was dropped.
  ///
  /// Under `jev` each row is judged on its own and only rows at or above the
  /// threshold survive — possibly none, which BM25's relative cut cannot say.
  Future<(String, List<String>)> _reduceListing(Envelope sent, JsonMap payload, String rendered) async {
    final key = sent.key;
    final label = IntentConventions.intentOf(sent.key, sent.payload) ?? sent.key;
    final entry = payload.entries
        .where((e) => e.value is List)
        .fold<MapEntry<String, Object?>?>(
          null,
          (largest, e) => largest == null || (e.value as List).length > (largest.value as List).length ? e : largest,
        );
    if (entry == null) return (rendered, _values(rendered));

    final rows = entry.value as List;
    final List<Object?> kept;
    if (preparation.strategy == .jev) {
      kept = await _jevRows(label, rows);
    } else {
      // Scored once, against the rows' own statistics, best first; ties keep
      // the app's order.
      final raw = _lexicalScores(Bm25Index({for (final (index, row) in rows.indexed) '$index': jsonEncode(row)}, _analyzer));
      final order = [for (var i = 0; i < rows.length; i++) i]
        ..sort((a, b) {
          final byScore = raw['$b']!.compareTo(raw['$a']!);
          return byScore != 0 ? byScore : a - b;
        });
      kept = [for (final i in order.take(preparation.topK)) rows[i]];
    }
    _keptRows[label] = kept;
    final dropped = rows.length - kept.length;
    final text = jsonEncode({
      ...{...payload}..remove(entry.key),
      entry.key: kept,
      if (dropped > 0)
        'note':
            'and $dropped more — call $key yourself, with a '
            '${preparation.queryParam}, for the rest',
    });
    return (text, _values(jsonEncode(kept)));
  }

  /// Distinctive strings of a digest: what "the agent used this" is read off
  /// later. Words from the task itself are excluded — an id it was given is
  /// not something preparation found.
  List<String> _values(String rendered) {
    final seen = <String>{};
    // Value position only: a field *name* is in the request anyway, as part of
    // whatever schema the agent was given, so counting one as "used" would
    // credit preparation with a word the agent never needed it for.
    for (final match in RegExp(r':\s*"([^"]{3,40})"').allMatches(rendered)) {
      final value = match.group(1)!;
      if (_words.contains(value.toLowerCase()) || value.contains(' ')) continue;
      seen.add(value);
    }
    for (final match in RegExp(r':\s*(\d{2,})').allMatches(rendered)) {
      seen.add(match.group(1)!);
    }
    return seen.take(12).toList();
  }

  /// Rows of [label] the decision model judges needed, best first, at most
  /// top-k. Candidate ids carry the listing's name so two listings' rows
  /// never share a score.
  Future<List<Object?>> _jevRows(String label, List<Object?> rows) async {
    final maxChars = decisions!.config.selection.maxRowChars;
    final ids = [for (var i = 0; i < rows.length; i++) '$label#$i'];
    final candidates = {
      for (final (i, row) in rows.indexed)
        ids[i]: () {
          final text = jsonEncode(row);
          return text.length <= maxChars ? text : '${text.substring(0, maxChars)}…';
        }(),
    };
    final kept = await _select(candidates, purpose: 'select-rows');
    return [for (final id in kept.take(preparation.topK)) rows[ids.indexOf(id)]];
  }

  String _cap(String text) => text.length <= preparation.maxBriefingBytes
      ? text
      : '${text.substring(0, preparation.maxBriefingBytes)}… [digest cut at '
            '${preparation.maxBriefingBytes} bytes — call the intent yourself '
            'for the rest]';

  /// One message: what was fetched, what is in scope, and what was not done.
  String _briefing() {
    final prepared = preparation.preparedHint || _sharedLayout ? _callablePrepared : const <String>[];
    return [
      'Preparation: the following was read for you before your first turn. It '
          'cost you no tokens to fetch, and it may be incomplete.',
      ..._digests,
      if (prepared.isNotEmpty) ...[
        '',
        'Already described for you and callable now — call these tools directly, '
            'without describe_intents: '
            '${[for (final name in prepared) '${IntentStrategy.toolNameFor(name)} ($name)'].join(', ')}.',
      ],
      if (preparation.escapeHatch && _catalogue.isNotEmpty) ...[
        '',
        ...switch (config.toolSurface) {
          // The prepared intents are not in the list below: it is about what is
          // *not* callable yet.
          .promoted when _sharedListing && prepared.isNotEmpty => [
            'Every other intent in scope. None of these is callable yet: pass the '
                'names you need to describe_intents, in one call, and they become '
                'tools from the next turn. Calling a catalogue name directly does '
                'nothing.',
          ],
          // Naming an intent without promoting it is a trap unless the mapping
          // is spelled out: a provider silently drops a call to a tool it was
          // not offered, and the turn comes back empty — which the loop can only
          // read as "no usable response". The catalogue rendering says this for
          // the same reason; a briefing that lists names must say it too.
          .promoted => [
            'Every intent in scope. None of these is callable yet: pass the names '
                'you need to describe_intents, in one call, and they become tools '
                'from the next turn. Calling a catalogue name directly does nothing.',
          ],
          // A tool without its schema is a guess at the parameters; the
          // catalogue rendering says the same.
          .fixed => [
            'Every intent in scope. Each is already a tool; pass the names you '
                'need to describe_intents, in one call, to read their parameters '
                'before calling them.',
          ],
        },
        ..._hatchLines(exclude: _sharedListing ? prepared.toSet() : const {}),
      ],
      '',
      'Not prepared: ${_omitted.isEmpty ? 'nothing else was planned' : _omitted.join('; ')}. '
          'Anything absent above is still reachable the normal way — describe '
          'the intent and call it.',
    ].join('\n');
  }

  /// Prepared intents that did become tools: a name the app could not
  /// describe is not one.
  List<String> get _callablePrepared {
    final tools = {for (final tool in strategyTools) tool.name};
    return [
      for (final name in _preparedIntents)
        if (tools.contains(IntentStrategy.toolNameFor(name))) name,
    ];
  }

  /// The escape hatch's catalogue: all of it, or — scope `relevant`, when
  /// the ranking judged anything relevant — the relevant intents with their
  /// summaries and the rest by name, still reachable.
  ///
  /// Intents in [exclude] are left out altogether.
  List<String> _hatchLines({Set<String> exclude = const {}}) {
    final entries = [
      for (final entry in _catalogue.entries)
        if (!exclude.contains(entry.key)) entry,
    ];
    final pruned = preparation.hatchScope == .relevant && _relevant.isNotEmpty;
    if (!pruned) return [for (final entry in entries) '- ${entry.key}: ${entry.value}'];
    final others = [
      for (final entry in entries)
        if (!_relevant.contains(entry.key)) entry.key,
    ];
    return [
      for (final entry in entries)
        if (_relevant.contains(entry.key)) '- ${entry.key}: ${entry.value}',
      if (others.isNotEmpty) 'Also in scope, judged unrelated to this task (names only): ${others.join(', ')}',
    ];
  }

  // Retrieval

  /// Catalogue names by relevance, best first.
  ///
  /// `rules` matches terms exactly, `lexical` is BM25, `vector` is cosine over
  /// a pinned embedding model, and `hybrid` fuses BM25 and vector with
  /// reciprocal rank fusion, which combines ranks, so the two score scales need
  /// no calibration. Each ranker's threshold is applied to min–max normalised
  /// scores ([rankAbove]).
  Future<List<String>> _rank() async {
    if (preparation.strategy == .jev) {
      final selection = decisions!.config.selection;
      final kept = await _select(
        {for (final name in _catalogue.keys) name: _selectionText(name)},
        purpose: 'select-tools',
        minKeep: selection.minKeep,
        maxKeep: selection.maxKeep,
      );
      return selection.expand.expand(kept, _catalogue);
    }
    final index = _catalogueIndex;
    final lexical = index == null ? const <String>[] : rankAbove(_lexicalScores(index), preparation.minScore, requireMatch: true);
    if (!preparation.isDense) return lexical;
    final dense = await _denseRanking();
    // Retrieval is speculative, so a preparer that cannot embed degrades to
    // the deterministic half rather than preparing nothing — and records
    // that it did, on the next decision (`prepared.denseFallback`).
    if (dense == null) return lexical;
    return preparation.strategy == .vector ? dense : _fuse([lexical, dense]);
  }

  /// What the decision model reads about an intent: its summary, and the
  /// aliases the app published so a German task meets an English name.
  String _selectionText(String name) =>
      decisions!.config.selection.candidateText.render(summary: _catalogue[name] ?? '', aliases: _aliases[name] ?? const [], kind: _kinds[name]);

  /// Raw scores of [index] for the task under the configured strategy:
  /// term coverage for `rules`, BM25 otherwise.
  Map<String, double> _lexicalScores(Bm25Index index) => preparation.strategy == .rules ? index.coverage(_terms) : index.bm25(_terms);

  /// One embedding call for the task and the whole catalogue. A multilingual
  /// encoder also handles a query and a catalogue in different languages, where
  /// term matching has nothing to match.
  ///
  /// Null when it could not rank; [_denseFallback] then says why.
  Future<List<String>?> _denseRanking() async {
    final client = embeddingClient!;
    if (_searchText.isEmpty) {
      _denseFallback = 'empty catalogue';
      return null;
    }
    final names = _searchText.keys.toList();
    try {
      final response = await client.embed([currentTask?.instruction ?? '', for (final name in names) _searchText[name]!]);
      _embedTokens += response.promptTokens;
      _embedCalls++;
      final query = response.vectors.first;
      return rankAbove({for (final (index, name) in names.indexed) name: _cosine(query, response.vectors[index + 1])}, preparation.minScore);
    } on Exception catch (e) {
      _denseFallback = '$e';
      return null;
    }
  }

  /// Reciprocal rank fusion (Cormack, Clarke & Buettcher 2009): each item
  /// scores the sum of `1 / (k + rank)` over the lists it appears in, with the
  /// paper's `k = 60`.
  List<String> _fuse(List<List<String>> rankings) {
    final scored = <String, double>{};
    for (final ranking in rankings) {
      for (final (index, name) in ranking.indexed) {
        scored[name] = (scored[name] ?? 0) + 1 / (preparation.rrfK + index + 1);
      }
    }
    return scored.keys.toList()..sort((a, b) => scored[b]!.compareTo(scored[a]!));
  }

  static double _cosine(List<double> a, List<double> b) {
    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;
    for (var i = 0; i < a.length && i < b.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 0;
    return dot / (sqrt(normA) * sqrt(normB));
  }

  static String _fingerprint(String text) => jsonFingerprint(text).substring(0, 8);
}
