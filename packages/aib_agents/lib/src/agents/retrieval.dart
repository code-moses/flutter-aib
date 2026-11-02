import 'dart:math' as math;

/// How text becomes terms for lexical retrieval.
enum TermAnalyzer {
  /// Lower-cased words of three or more letters, stop words removed.
  plain,

  /// [plain], then umlauts folded, a light German/English suffix stemmer, and
  /// query compounds split against the catalogue's vocabulary
  /// ("Materialanforderungen" -> "material", "anforderung").
  stem,
}

/// Turns text into retrieval terms under one [TermAnalyzer].
final class TextAnalyzer {
  TextAnalyzer(this.kind);

  final TermAnalyzer kind;

  /// Stemmed terms of the collection, for splitting query compounds.
  Set<String> vocabulary = const {};

  static final _wordBoundary = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

  /// Words worth matching on: short ones and the usual German and English
  /// function words carry no signal and would match everything.
  static const _stopWords = {
    'der', 'die', 'das', 'den', 'dem', 'des', 'ein', 'eine', 'einen', //
    'einem', 'einer', 'und', 'oder', 'für', 'von', 'mit', 'auf', 'wie',
    'viele', 'gibt', 'mir', 'ich', 'the', 'a', 'an', 'and', 'or', 'for', 'of',
    'with', 'on', 'how', 'many', 'show', 'me', 'please',
  };

  /// The words of [text] as written (lower case), before any stemming — what
  /// an app's own search expects.
  static List<String> words(String text) => [
    for (final word in text.toLowerCase().split(_wordBoundary))
      if (word.length >= 3 && !_stopWords.contains(word)) word,
  ];

  /// Terms of a collection document.
  List<String> document(String text) => switch (kind) {
    .plain => words(text),
    .stem => [for (final word in words(text)) stem(word)],
  };

  /// Terms of a query: [document], plus compound parts found in [vocabulary].
  List<String> query(String text) {
    final terms = document(text);
    if (kind == .plain) return terms;
    return [
      for (final term in terms) ...[term, ..._compoundParts(term)],
    ];
  }

  Iterable<String> _compoundParts(String term) sync* {
    if (vocabulary.contains(term)) return;
    for (final part in vocabulary) {
      if (part.length < 4 || part.length >= term.length) continue;
      if (term.endsWith(part)) {
        yield part;
        var head = term.substring(0, term.length - part.length);
        if (head.endsWith('s') && head.length > 4) {
          head = head.substring(0, head.length - 1); // Fugen-s
        }
        if (vocabulary.contains(stem(head))) yield stem(head);
      } else if (term.startsWith(part) && vocabulary.contains(stem(term.substring(part.length)))) {
        yield part;
        yield stem(term.substring(part.length));
      }
    }
  }

  /// A light stemmer for German and English: umlauts folded, then `-em`,
  /// `-er`, `-nd`, `-ing` and single `-t`/`-e`/`-s`/`-n` removed while the
  /// word stays long enough (after CISTEM). Deliberately aggressive and
  /// deliberately small: it only has to make "Anforderungen" and
  /// "Anforderung" the same term.
  static String stem(String word) {
    var w = word.toLowerCase().replaceAll('ä', 'a').replaceAll('ö', 'o').replaceAll('ü', 'u').replaceAll('ß', 'ss');
    for (var changed = true; changed;) {
      changed = false;
      if (w.length > 6 && w.endsWith('ing')) {
        w = w.substring(0, w.length - 3);
        changed = true;
      } else if (w.length > 5 && (w.endsWith('em') || w.endsWith('er') || w.endsWith('nd'))) {
        w = w.substring(0, w.length - 2);
        changed = true;
      } else if (w.length > 4 && (w.endsWith('t') || w.endsWith('e') || w.endsWith('s') || w.endsWith('n'))) {
        w = w.substring(0, w.length - 1);
        changed = true;
      }
    }
    return w;
  }
}

/// BM25 (`k1 = 1.2`, `b = 0.75`, Robertson & Spärck Jones) over one collection,
/// with its own document frequencies and average length. The collection is
/// whatever is being ranked: the catalogue, the declared listing keys, the rows
/// of one listing.
final class Bm25Index {
  Bm25Index(Map<String, String> documents, this.analyzer)
    : _tokens = {for (final entry in documents.entries) entry.key: analyzer.document(entry.value)} {
    final lengths = _tokens.values.map((t) => t.length);
    _averageLength = _tokens.isEmpty ? 0 : lengths.fold(0, (a, b) => a + b) / _tokens.length;
    for (final tokens in _tokens.values) {
      for (final term in tokens.toSet()) {
        _documentFrequency.update(term, (n) => n + 1, ifAbsent: () => 1);
      }
    }
  }

  static const _k1 = 1.2;
  static const _b = 0.75;

  final TextAnalyzer analyzer;
  final Map<String, List<String>> _tokens;
  final Map<String, int> _documentFrequency = {};
  late final double _averageLength;

  /// Every term of the collection.
  Set<String> get vocabulary => _documentFrequency.keys.toSet();

  /// Raw BM25 per document; 0 where no query term occurs.
  Map<String, double> bm25(Iterable<String> queryTerms) {
    final terms = queryTerms.toSet();
    return {for (final entry in _tokens.entries) entry.key: _score(entry.value, terms)};
  }

  /// Share of the distinct query terms each document contains.
  Map<String, double> coverage(Iterable<String> queryTerms) {
    final terms = queryTerms.toSet();
    return {for (final entry in _tokens.entries) entry.key: terms.isEmpty ? 0 : terms.where(entry.value.contains).length / terms.length};
  }

  double _score(List<String> tokens, Set<String> terms) {
    if (tokens.isEmpty) return 0;
    var score = 0.0;
    for (final term in terms) {
      final frequency = tokens.where((token) => token == term).length;
      if (frequency == 0) continue;
      final length = _averageLength == 0 ? 1 : _averageLength;
      final saturated = frequency * (_k1 + 1) / (frequency + _k1 * (1 - _b + _b * tokens.length / length));
      score += _idf(term) * saturated;
    }
    return score;
  }

  /// Robertson–Spärck Jones idf with the usual smoothing, floored at zero so
  /// a term every document contains cannot subtract from a match.
  double _idf(String term) {
    final total = _tokens.length;
    if (total == 0) return 0;
    final hits = _documentFrequency[term] ?? 0;
    final value = math.log((total - hits + 0.5) / (hits + 0.5) + 1);
    return value < 0 ? 0 : value;
  }
}

/// Min–max normalises [scores] over every candidate, so a threshold means the
/// same share of the observed spread whatever the ranker. Equal scores
/// normalise to 1 when positive, else 0.
Map<String, double> minMaxNormalise(Map<String, double> scores) {
  if (scores.isEmpty) return const {};
  final low = scores.values.reduce(math.min);
  final high = scores.values.reduce(math.max);
  if (high == low) {
    return {for (final key in scores.keys) key: high > 0 ? 1.0 : 0.0};
  }
  return {for (final entry in scores.entries) entry.key: (entry.value - low) / (high - low)};
}

/// Keys whose normalised score reaches [minScore], best first; ties keep the
/// candidates' order. With [requireMatch], a raw score of 0 (no term in
/// common) never qualifies, whatever its normalised value.
List<String> rankAbove(Map<String, double> raw, double minScore, {bool requireMatch = false}) {
  final normalised = minMaxNormalise(raw);
  final order = raw.keys.toList();
  final kept = [
    for (final key in order)
      if (normalised[key]! >= minScore && (!requireMatch || raw[key]! > 0)) key,
  ];
  kept.sort((a, b) {
    final byScore = raw[b]!.compareTo(raw[a]!);
    return byScore != 0 ? byScore : order.indexOf(a) - order.indexOf(b);
  });
  return kept;
}
