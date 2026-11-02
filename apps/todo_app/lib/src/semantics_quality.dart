/// Build variant of the semantics quality (spec §8.1):
/// `--dart-define=SEMANTICS_QUALITY=good|bad`.
///
/// `bad` models realistically poor accessibility: unlabelled icon buttons,
/// generic button texts, merged tile blobs, unlabelled text fields. The
/// *functionality* is identical — only the semantics surface degrades
/// (basis of the `semantics_degradation_delta` metric, spec §6.4).
enum SemanticsQuality {
  good,
  bad;

  static const SemanticsQuality fromEnvironment = String.fromEnvironment('SEMANTICS_QUALITY', defaultValue: 'good') == 'bad'
      ? SemanticsQuality.bad
      : SemanticsQuality.good;
}
