final _sentenceEnd = RegExp(r'(?<=\.)\s+(?=\p{Lu})', unicode: true);

/// The first sentence of [text], or all of it when there is only one.
///
/// `intents.catalog` publishes this as the summary, so an intent's or tool's
/// first sentence must be enough to choose it by, including what it addresses:
/// "Opens a form by assemblyId and maskId", not "Opens a form."
String firstSentence(String text) {
  final trimmed = text.trim();
  final parts = trimmed.split(_sentenceEnd);
  return parts.length < 2 ? trimmed : parts.first.trim();
}
