import '../common/json.dart';

/// Price of one model, per million tokens (the unit every provider quotes).
final class ModelPrice {
  const ModelPrice({
    required this.promptPerMTok,
    required this.completionPerMTok,
    this.cachedPromptPerMTok,
    this.cacheWritePerMTok,
    this.reasoningPerMTok,
    this.nominal = false,
  });

  final double promptPerMTok;
  final double completionPerMTok;

  /// Rate for prompt tokens served from the provider's cache. Null means the
  /// table does not distinguish: cached tokens are billed at the full prompt
  /// rate.
  final double? cachedPromptPerMTok;

  /// Rate for prompt tokens written *into* the cache. Null bills them at
  /// [promptPerMTok].
  final double? cacheWritePerMTok;

  /// Rate for hidden reasoning tokens. Null means they are billed at
  /// [completionPerMTok], which is what most providers actually do.
  final double? reasoningPerMTok;

  /// The price is zero because no API money changes hands, not because the
  /// model is free. Reports name these models and say the money column is not
  /// the whole cost; rank them on tokens or wall clock.
  final bool nominal;

  double cost({
    required int promptTokens,
    required int completionTokens,
    int cachedPromptTokens = 0,
    int cacheWriteTokens = 0,
    int reasoningTokens = 0,
  }) {
    // Cached, written and reasoning tokens are *subsets*, so each is removed
    // from its parent count before being charged at its own rate. Clamping
    // guards against a provider reporting a subset larger than its total, and
    // the write clamp accounts for the read already taken out, so a
    // mis-reporting provider cannot make a prompt cost less than nothing.
    final cached = cachedPromptPerMTok == null ? 0 : cachedPromptTokens.clamp(0, promptTokens);
    final written = cacheWritePerMTok == null ? 0 : cacheWriteTokens.clamp(0, promptTokens - cached);
    final reasoning = reasoningPerMTok == null ? 0 : reasoningTokens.clamp(0, completionTokens);
    return (promptTokens - cached - written) / 1e6 * promptPerMTok +
        cached / 1e6 * (cachedPromptPerMTok ?? promptPerMTok) +
        written / 1e6 * (cacheWritePerMTok ?? promptPerMTok) +
        (completionTokens - reasoning) / 1e6 * completionPerMTok +
        reasoning / 1e6 * (reasoningPerMTok ?? completionPerMTok);
  }

  JsonMap toJson() => {
    'promptPerMTok': promptPerMTok,
    'completionPerMTok': completionPerMTok,
    if (cachedPromptPerMTok != null) 'cachedPromptPerMTok': cachedPromptPerMTok,
    if (cacheWritePerMTok != null) 'cacheWritePerMTok': cacheWritePerMTok,
    if (reasoningPerMTok != null) 'reasoningPerMTok': reasoningPerMTok,
    if (nominal) 'nominal': true,
  };

  factory ModelPrice.fromJson(JsonMap json) => ModelPrice(
    promptPerMTok: (json['promptPerMTok'] as num?)?.toDouble() ?? 0,
    completionPerMTok: (json['completionPerMTok'] as num?)?.toDouble() ?? 0,
    cachedPromptPerMTok: (json['cachedPromptPerMTok'] as num?)?.toDouble(),
    cacheWritePerMTok: (json['cacheWritePerMTok'] as num?)?.toDouble(),
    reasoningPerMTok: (json['reasoningPerMTok'] as num?)?.toDouble(),
    nominal: json['nominal'] == true,
  );
}

/// Pinned price table for `cost_usd` (spec §6.3: "tokens × pinned price table,
/// versioned in the RunManifest, since prices are volatile"). Travels in the
/// run manifest, so a run is costed with the prices that applied when it ran.
///
/// ```yaml
/// currency: USD
/// asOf: 2026-08-01
/// source: https://www.anthropic.com/pricing
/// models:
///   claude-sonnet-4-6: { promptPerMTok: 3.0, completionPerMTok: 15.0 }
/// ```
final class PriceTable {
  const PriceTable({required this.models, this.currency = 'USD', this.asOf, this.source});

  final Map<String, ModelPrice> models;
  final String currency;

  /// Date the prices were taken — without it the numbers are unciteable.
  final String? asOf;
  final String? source;

  bool get isEmpty => models.isEmpty;

  /// Models whose zero is a statement about API billing, not about cost.
  Set<String> get nominalModels => {
    for (final entry in models.entries)
      if (entry.value.nominal) entry.key,
  };

  /// Whether [model] is priced at all, and only nominally.
  bool isNominal(String? model) => this[model]?.nominal ?? false;

  /// Exact match first, then the longest row the id extends by a version
  /// suffix. Only a suffix that starts with a digit (`-20260214`), a tag
  /// separator (`:`, `@`) or a quantisation tag (`-q4`) counts, so
  /// `gpt-4o-mini` does not get `gpt-4o`'s rate.
  ModelPrice? operator [](String? model) {
    if (model == null) return null;
    final exact = models[model];
    if (exact != null) return exact;
    String? best;
    for (final key in models.keys) {
      if (!model.startsWith(key) || model.length == key.length) continue;
      final rest = model.substring(key.length);
      if (!_versionSuffix.hasMatch(rest)) continue;
      if (best == null || key.length > best.length) best = key;
    }
    return best == null ? null : models[best];
  }

  static final _versionSuffix = RegExp(r'^([-_.]\d|[:@]|-q\d)');

  JsonMap toJson() => {
    'currency': currency,
    if (asOf != null) 'asOf': asOf,
    if (source != null) 'source': source,
    'models': {for (final entry in models.entries) entry.key: entry.value.toJson()},
  };

  factory PriceTable.fromJson(JsonMap json) => PriceTable(
    currency: json['currency'] as String? ?? 'USD',
    asOf: json['asOf'] as String?,
    source: json['source'] as String?,
    models: {for (final entry in asJsonMap(json['models']).entries) entry.key: ModelPrice.fromJson(asJsonMap(entry.value))},
  );

  static const empty = PriceTable(models: {});
}
