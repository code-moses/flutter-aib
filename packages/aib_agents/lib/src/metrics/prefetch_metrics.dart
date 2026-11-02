import 'dart:convert';
import 'dart:math';

import 'package:aib_core/aib_core.dart';

import '../conventions.dart';

/// What preparation bought, and what it wasted. The agent states which items it
/// prefetched, the framework decides what that was worth.
///
/// Switched on with `aib evaluate --metrics prefetch`; null throughout for an
/// agent that prepares nothing.
final prefetchMetrics = MetricProvider(
  name: 'prefetch',
  description: 'Precision, recall and waste of a preparing agent\'s prefetch',
  metrics: [
    MetricDefinition(
      name: 'prefetch_item_count',
      unit: 'count',
      description: 'Items speculated before the first LLM call',
      compute: (ctx) => _prepared(ctx).isEmpty ? null : _prepared(ctx).length,
    ),
    MetricDefinition(
      name: 'prefetch_bytes',
      unit: 'bytes',
      description: 'Digest bytes that entered the conversation',
      compute: (ctx) => _sumBytes(_prepared(ctx)),
    ),
    MetricDefinition(
      name: 'prefetch_waste_bytes',
      unit: 'bytes',
      description: 'Digest bytes of items the episode never referenced',
      compute: (ctx) {
        final items = _prepared(ctx);
        if (items.isEmpty) return null;
        final used = _used(ctx, items);
        return _sumBytes([
          for (final item in items)
            if (!used.contains(_id(item))) item,
        ]);
      },
    ),
    MetricDefinition(
      name: 'prefetch_precision',
      unit: 'ratio',
      description: 'Of what was prefetched, the share the agent went on to use',
      compute: (ctx) {
        final items = _prepared(ctx);
        if (items.isEmpty) return null;
        return _used(ctx, items).length / items.length;
      },
    ),
    MetricDefinition(
      name: 'prefetch_recall',
      unit: 'ratio',
      description:
          'Of everything the episode turned out to need, the share already '
          'prepared',
      compute: (ctx) {
        final items = _prepared(ctx);
        if (items.isEmpty) return null;
        final used = {for (final id in _used(ctx, items)) _base(id)};
        // "Needed" is *used*, never "re-requested": a successful prefetch is
        // precisely the thing the agent never asks for again, so re-requests
        // would shrink numerator and denominator together and a perfect
        // preparer would score like no preparer at all. Compared without
        // the digest fingerprint, which a self-fetched result does not have.
        final needed = {...used, ..._selfFetched(ctx)};
        return needed.isEmpty ? null : used.length / needed.length;
      },
    ),
    MetricDefinition(
      name: 'prefetch_refetch_count',
      unit: 'count',
      description: 'Prepared items the agent fetched again — a lossy digest',
      compute: (ctx) {
        final items = _prepared(ctx);
        if (items.isEmpty) return null;
        final again = _selfFetched(ctx);
        return items.where((item) => again.contains(_base(_id(item)))).length;
      },
    ),
    // Against the task's declared gold set (the retrieval oracle)
    //
    // The three measures tool-retrieval papers report. They are independent of
    // the trajectory the agent took, which the precision/recall pair above is
    // not, and they are null unless a task says what a correct solution needs.
    MetricDefinition(
      name: 'tool_recall_at_k',
      unit: 'ratio',
      description:
          'Share of the task\'s reachable required tools that were prepared. '
          'Reachable: in the catalogue the preparer read, so a scope-gated '
          'intent that appears only after a form opens is not held against '
          'it. 0, not null, when an active preparer promoted nothing',
      compute: (ctx) {
        final gold = _reachableGold(ctx);
        if (gold == null || gold.isEmpty || !_preparesTools(ctx)) return null;
        return _promotedTools(ctx).toSet().intersection(gold).length / gold.length;
      },
    ),
    MetricDefinition(
      name: 'tool_completeness_at_k',
      unit: 'ratio',
      description:
          '1 when every reachable required tool was prepared, else 0 — an '
          'agent needs all of them, so a partial set is its own failure',
      compute: (ctx) {
        final gold = _reachableGold(ctx);
        if (gold == null || gold.isEmpty || !_preparesTools(ctx)) return null;
        return gold.difference(_promotedTools(ctx).toSet()).isEmpty ? 1 : 0;
      },
    ),
    MetricDefinition(
      name: 'tool_ndcg_at_k',
      unit: 'ratio',
      description:
          'Ranking quality of the prepared tools against the reachable '
          'required ones (binary relevance, log2 discount); 0 when nothing '
          'was promoted',
      compute: (ctx) {
        final gold = _reachableGold(ctx);
        if (gold == null || gold.isEmpty || !_preparesTools(ctx)) return null;
        final promoted = _promotedTools(ctx);
        if (promoted.isEmpty) return 0;
        var dcg = 0.0;
        for (final (index, id) in promoted.indexed) {
          if (gold.contains(id)) dcg += 1 / (log(index + 2) / ln2);
        }
        var ideal = 0.0;
        final reachable = gold.length < promoted.length ? gold.length : promoted.length;
        for (var index = 0; index < reachable; index++) {
          ideal += 1 / (log(index + 2) / ln2);
        }
        return ideal == 0 ? null : dcg / ideal;
      },
    ),
    MetricDefinition(
      name: 'tool_gold_out_of_scope',
      unit: 'count',
      description:
          'Required tools that were not in the catalogue the preparer read — '
          'reachable only later (a form\'s verbs) or not at all, and left out '
          'of the @k metrics. Null without requiredTools or a catalogue',
      compute: (ctx) {
        final required = _requiredTools(ctx);
        final seen = _catalogueSeen(ctx);
        if (required.isEmpty || seen == null) return null;
        return required.difference(seen).length;
      },
    ),
    MetricDefinition(
      name: 'prefetch_dense_fallbacks',
      unit: 'count',
      description:
          'Times a vector or hybrid preparer could not embed and ranked '
          'lexically instead',
      compute: (ctx) {
        var fallbacks = 0;
        var any = false;
        for (final decision in ctx.decisions) {
          final prepared = asJsonMap(asJsonMap(decision['extra'])['prepared']);
          if (prepared.isNotEmpty) any = true;
          if (prepared['denseFallback'] != null) fallbacks++;
        }
        return any ? fallbacks : null;
      },
    ),
    MetricDefinition(
      name: 'prefetch_embed_calls',
      unit: 'count',
      description: 'Embedding calls the preparer made to rank the catalogue',
      compute: (ctx) => _preparedSum(ctx, 'embedCalls'),
    ),
    MetricDefinition(
      name: 'prefetch_embed_tokens',
      unit: 'tokens',
      description: 'Tokens those embedding calls cost',
      compute: (ctx) => _preparedSum(ctx, 'embedTokens'),
    ),
    MetricDefinition(
      name: 'prefetch_llm_calls',
      unit: 'count',
      description: 'The preparer\'s own model calls, apart from the agent\'s',
      compute: (ctx) =>
          _prefetchDecisions(ctx).isEmpty ? null : _prefetchDecisions(ctx).fold<int>(0, (sum, d) => sum + ((d['llmCalls'] as num?)?.toInt() ?? 0)),
    ),
    MetricDefinition(
      name: 'prefetch_tokens',
      unit: 'tokens',
      description: 'Tokens the preparation pass itself spent',
      compute: (ctx) => _prefetchDecisions(ctx).isEmpty
          ? null
          : _prefetchDecisions(
              ctx,
            ).fold<int>(0, (sum, d) => sum + ((d['tokensPrompt'] as num?)?.toInt() ?? 0) + ((d['tokensCompletion'] as num?)?.toInt() ?? 0)),
    ),
    MetricDefinition(
      name: 'prefetch_latency_ms',
      unit: 'ms',
      description: 'Wall clock the prefetch envelopes took',
      compute: (ctx) {
        final exchanges = _prefetchExchanges(ctx);
        if (exchanges.isEmpty) return null;
        return exchanges.fold<int>(0, (sum, x) => sum + ((x.result?.data['handleMs'] as num?)?.toInt() ?? 0));
      },
    ),
  ],
);

/// Decisions of envelopes the agent emitted without being asked to.
List<JsonMap> _prefetchDecisions(MetricContext ctx) => [
  for (final exchange in ctx.exchanges)
    if (asJsonMap(exchange.envelope.data['decision']) case final decision
        when decision['extra'] != null && asJsonMap(decision['extra'])[AgentDecision.prefetchKey] == true)
      decision,
];

List<Exchange> _prefetchExchanges(MetricContext ctx) => [
  for (final exchange in ctx.exchanges)
    if (_isPrefetch(exchange)) exchange,
];

bool _isPrefetch(Exchange exchange) => asJsonMap(asJsonMap(exchange.envelope.data['decision'])['extra'])[AgentDecision.prefetchKey] == true;

/// The items the preparer recorded, in order.
///
/// Read from every decision, not only from the prefetch-marked ones: a digest
/// is written when its *result* comes back, so it rides on the envelope after
/// the one it describes — which for the last prepared observation is the first
/// envelope the model asked for.
List<JsonMap> _prepared(MetricContext ctx) => [
  for (final exchange in ctx.exchanges)
    for (final raw in asJsonMap(asJsonMap(asJsonMap(exchange.envelope.data['decision'])['extra'])['prepared'])['items'] as List? ?? const [])
      asJsonMap(raw),
];

String _id(JsonMap item) => '${item['id']}';

/// An item id without its digest fingerprint: `obs:<label>#<fp>` ->
/// `obs:<label>`.
String _base(String id) {
  final hash = id.indexOf('#');
  return hash < 0 ? id : id.substring(0, hash);
}

/// Whether the episode's agent prepares tools: a `preparation:` block whose
/// strategy is not `none` and whose axes include `tools` (the default).
bool _preparesTools(MetricContext ctx) {
  final agent = asJsonMap(ctx.trace.firstOfType(TraceEventTypes.episodeStart)?.data['agent']);
  final metadata = asJsonMap(agent['metadata']);
  final block = metadata['preparation'] is Map
      ? asJsonMap(metadata['preparation'])
      : asJsonMap(asJsonMap(asJsonMap(metadata['configBlocks'])['preparation'])['config']);
  final strategy = block['strategy'];
  if (strategy == null || strategy == 'none') return false;
  final axes = block['prepare'];
  return axes is! List || axes.contains('tools');
}

/// Intent names in the catalogue observations the preparer made, or null
/// when it made none.
Set<String>? _catalogueSeen(MetricContext ctx) {
  Set<String>? names;
  for (final exchange in _prefetchExchanges(ctx)) {
    if (exchange.key != IntentConventions.catalogKey) continue;
    names ??= {};
    for (final raw in asJsonMap(exchange.result?.data['payload'])['intents'] as List? ?? const []) {
      if (asJsonMap(raw)['name'] case final String name) names.add(name);
    }
  }
  return names;
}

/// The gold set restricted to what the preparer could have seen, in the item
/// id space; the whole gold set when no catalogue was observed.
Set<String>? _reachableGold(MetricContext ctx) {
  final required = _requiredTools(ctx);
  if (required.isEmpty) return null;
  final seen = _catalogueSeen(ctx);
  return {
    for (final name in required)
      if (seen == null || seen.contains(name)) 'tool:$name',
  };
}

/// The task's gold set, in the item id space.
Set<String> _requiredTools(MetricContext ctx) => {...?ctx.task?.requiredTools};

/// Prepared tool items, in the order retrieval ranked them.
List<String> _promotedTools(MetricContext ctx) => [
  for (final item in _prepared(ctx))
    if (_id(item).startsWith('tool:')) _id(item),
];

/// Sums one numeric field the preparer recorded next to its items.
num? _preparedSum(MetricContext ctx, String field) {
  num? total;
  for (final exchange in ctx.exchanges) {
    final prepared = asJsonMap(asJsonMap(asJsonMap(exchange.envelope.data['decision'])['extra'])['prepared']);
    if (prepared[field] case final num value) total = (total ?? 0) + value;
  }
  return total;
}

num _sumBytes(List<JsonMap> items) => items.fold<num>(0, (sum, item) => sum + ((item['bytes'] as num?) ?? 0));

/// Ids of prepared items the agent referenced afterwards: a promoted tool that
/// was called, or a digest value that turns up in a later payload or in the
/// closing summary.
Set<String> _used(MetricContext ctx, List<JsonMap> items) {
  final called = <String>{};
  final buffer = StringBuffer();
  for (final exchange in ctx.exchanges) {
    if (_isPrefetch(exchange)) continue;
    final payload = asJsonMap(exchange.envelope.data['payload']);
    if (exchange.key == IntentConventions.invokeKey) {
      called.add('tool:${payload['intent']}');
    }
    buffer.write(jsonEncode(payload));
  }
  final haystack = buffer.toString();
  return {
    for (final item in items)
      if (called.contains(_id(item)) || [for (final value in item['values'] as List? ?? const []) '$value'].any(haystack.contains)) _id(item),
  };
}

/// Items of the same id space the agent obtained on its own, later in the
/// episode — what preparation *could* have saved it.
Set<String> _selfFetched(MetricContext ctx) {
  final fetched = <String>{};
  for (final exchange in ctx.exchanges) {
    if (_isPrefetch(exchange) || exchange.isMeta) continue;
    final payload = asJsonMap(exchange.envelope.data['payload']);
    if (exchange.key == IntentConventions.describeKey) {
      for (final name in payload['names'] as List? ?? const []) {
        fetched.add('tool:$name');
      }
      continue;
    }
    if (exchange.kind == 'observe') {
      fetched.add('obs:${IntentConventions.label(exchange.key, payload)}');
    }
  }
  return fetched;
}
