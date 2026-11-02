/// Multilingual support: which language a decision's texts are written in.
///
/// The v1 template's frame stays English; it is the contract. What varies is
/// what the caller writes: [JevLanguagePolicy.fixed] asks in one language
/// whatever the state is, [JevLanguagePolicy.matchState] asks in the state's
/// language where a text for it exists.
///
/// Labels never carry language: `A`–`Z` and `0`–`9` are single tokens in every
/// multilingual vocabulary. Candidate ids are shown only as the `answer` of an
/// option.
library;

/// How a decision picks the language of its texts.
sealed class JevLanguagePolicy {
  const JevLanguagePolicy();

  /// Always [code].
  const factory JevLanguagePolicy.fixed(String code) = _Fixed;

  /// The detected language of the state, else [fallback].
  const factory JevLanguagePolicy.matchState({String fallback}) = _MatchState;

  /// `en`, `de`, … → fixed; `auto` → match the state (English fallback).
  factory JevLanguagePolicy.parse(String value) => value == 'auto' ? const JevLanguagePolicy.matchState() : JevLanguagePolicy.fixed(value);

  /// The language to ask in about [state].
  String resolve(String state);

  /// For configs and manifests.
  String get name;
}

final class _Fixed extends JevLanguagePolicy {
  const _Fixed(this.code);

  final String code;

  @override
  String resolve(String state) => code;

  @override
  String get name => code;
}

final class _MatchState extends JevLanguagePolicy {
  const _MatchState({this.fallback = 'en'});

  final String fallback;

  @override
  String resolve(String state) => detectLanguage(state) ?? fallback;

  @override
  String get name => 'auto';
}

/// A text (or anything) per language, with a fallback for the rest.
final class JevLocalized<T> {
  const JevLocalized(this.byLanguage, {this.fallback = 'en'});

  /// One value for every language.
  JevLocalized.only(T value) : byLanguage = {'*': value}, fallback = '*';

  final Map<String, T> byLanguage;
  final String fallback;

  Iterable<String> get languages => byLanguage.keys;

  /// The value for [code]; the fallback's where there is none.
  T of(String code) =>
      byLanguage[code] ??
      byLanguage[fallback] ??
      (throw ArgumentError('no text for "$code" and no fallback "$fallback" (have: ${languages.join(', ')})'));

  /// Whether [code] has its own text rather than the fallback's.
  bool has(String code) => byLanguage.containsKey(code);
}

/// The language of [text] by ISO 639-1 code, or null when the text does not say
/// clearly (too short, mixed, or none of [among]).
///
/// Function words, not a model: short app instructions are where statistical
/// detectors guess. Two hits and a clear lead over the runner-up are required.
String? detectLanguage(String text, {Iterable<String>? among}) {
  // Quoted text is data — a German project name in an English instruction
  // says nothing about the instruction's language.
  final prose = text.toLowerCase().replaceAll(RegExp(r'"[^"]*"|„[^“”]*[“”]|“[^”]*”|«[^»]*»'), ' ');
  final words = RegExp(r"[\p{L}']+", unicode: true).allMatches(prose).map((m) => m[0]!).toList();
  if (words.isEmpty) return null;
  final scores = <String, double>{};
  for (final code in among ?? _stopwords.keys) {
    final list = _stopwords[code];
    if (list == null) continue;
    var score = 0.0;
    for (final word in words) {
      if (list.contains(word)) score += 1;
    }
    // Letters that belong to one language are strong evidence on their own.
    if (_letters[code] case final letters?) {
      score += 1.5 * RegExp('[$letters]').allMatches(prose).length.clamp(0, 3);
    }
    scores[code] = score;
  }
  final ranked = scores.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  if (ranked.isEmpty || ranked.first.value < 2) return null;
  final runnerUp = ranked.length > 1 ? ranked[1].value : 0.0;
  return ranked.first.value >= runnerUp * 1.5 && ranked.first.value > runnerUp ? ranked.first.key : null;
}

/// The languages [detectLanguage] knows.
Iterable<String> get detectableLanguages => _stopwords.keys;

const _letters = {'de': 'äöüß', 'es': 'ñ¿¡', 'fr': 'çœêèà', 'pt': 'ãõç', 'it': 'ìò'};

const _stopwords = <String, Set<String>>{
  'en': {
    'the',
    'a',
    'an',
    'and',
    'or',
    'of',
    'to',
    'in',
    'on',
    'for',
    'with',
    'is',
    'are',
    'was',
    'be',
    'it',
    'this',
    'that',
    'my',
    'your',
    'all',
    'from',
    'by',
    'as',
    'at',
    'please',
    'new',
    'named',
    'called',
    'set',
    'add',
    'create',
    'delete',
    'show',
    'find',
    'which',
    'what',
    'me',
    'how',
    'many',
    'there',
    'open',
    'mark',
    'do',
    'not',
    'you',
    'have',
    'has',
    'into',
    'rename',
    'move',
    'list',
    'titled',
    'only',
  },
  'de': {
    'der',
    'die',
    'das',
    'den',
    'dem',
    'des',
    'ein',
    'eine',
    'einen',
    'einem',
    'einer',
    'und',
    'oder',
    'zu',
    'im',
    'in',
    'mit',
    'für',
    'auf',
    'ist',
    'sind',
    'nicht',
    'von',
    'bitte',
    'alle',
    'mein',
    'meine',
    'lege',
    'an',
    'lösche',
    'zeige',
    'setze',
    'neuen',
    'neue',
    'namens',
    'ich',
    'sie',
    'wir',
    'es',
    'auch',
    'noch',
    'wie',
    'was',
    'welche',
    'welches',
    'aus',
    'bei',
    'nach',
    'vom',
    'zum',
    'zur',
    'zeig',
    'mir',
    'ins',
    'um',
    'ab',
    'benenne',
    'stelle',
    'verschiebe',
    'hake',
    'öffne',
    'ändere',
    'füge',
    'markiere',
    'viele',
    'gibt',
    'soll',
    'dass',
    'nur',
    'falls',
    'du',
    'musst',
    'hinzu',
    'als',
    'erledigt',
  },
  'fr': {
    'le',
    'la',
    'les',
    'un',
    'une',
    'des',
    'et',
    'ou',
    'de',
    'du',
    'à',
    'au',
    'aux',
    'pour',
    'avec',
    'est',
    'sont',
    'dans',
    'sur',
    'pas',
    'ne',
    'mon',
    'ma',
    'mes',
    'votre',
    'veuillez',
    'créer',
    'supprimer',
    'nouveau',
    'nouvelle',
    'je',
    'il',
    'elle',
    'nous',
    'vous',
  },
  'es': {
    'el',
    'la',
    'los',
    'las',
    'un',
    'una',
    'y',
    'o',
    'de',
    'del',
    'al',
    'para',
    'con',
    'es',
    'son',
    'en',
    'por',
    'no',
    'mi',
    'mis',
    'tu',
    'su',
    'crear',
    'borrar',
    'nuevo',
    'nueva',
    'yo',
    'que',
    'favor',
    'llamado',
  },
  'it': {
    'il',
    'lo',
    'la',
    'i',
    'gli',
    'le',
    'un',
    'uno',
    'una',
    'e',
    'o',
    'di',
    'da',
    'del',
    'della',
    'per',
    'con',
    'è',
    'sono',
    'in',
    'su',
    'non',
    'mio',
    'mia',
    'crea',
    'elimina',
    'nuovo',
    'nuova',
    'che',
    'chiamato',
  },
  'nl': {
    'de',
    'het',
    'een',
    'en',
    'of',
    'van',
    'naar',
    'in',
    'op',
    'voor',
    'met',
    'is',
    'zijn',
    'niet',
    'mijn',
    'maak',
    'verwijder',
    'nieuwe',
    'nieuw',
    'ik',
    'je',
    'wij',
    'dat',
    'die',
    'genaamd',
  },
  'pt': {
    'o',
    'a',
    'os',
    'as',
    'um',
    'uma',
    'e',
    'ou',
    'de',
    'do',
    'da',
    'dos',
    'das',
    'para',
    'com',
    'é',
    'são',
    'em',
    'no',
    'na',
    'não',
    'meu',
    'minha',
    'criar',
    'excluir',
    'novo',
    'nova',
    'eu',
    'que',
    'chamado',
  },
};
