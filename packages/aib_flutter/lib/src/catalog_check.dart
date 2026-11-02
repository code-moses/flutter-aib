import 'dart:convert';

import 'package:aib_core/catalog.dart';
import 'package:aib_core/ports.dart';

import 'intent_bridge.dart';

/// Lints the intents an app is about to publish; `aib catalog --run` does the
/// same one run later.
List<CatalogFinding> lintIntents(Iterable<AibIntent> intents) => catalogLint([
  for (final intent in intents)
    CatalogEntry(
      name: intent.name,
      summary: firstSentence(intent.description),
      description: intent.description,
      kind: intent.kind.name,
      effect: intent.effect?.name,
      takesParameters: intent.paramsSchema.isNotEmpty,
      paramsSchema: intent.paramsSchema,
      bytes: jsonEncode(intent.toSummaryJson()).length,
    ),
]);

/// Size of the listing, re-sent every turn; recorded next to
/// `catalogFingerprint`.
JsonMap catalogMetadata(Iterable<AibIntent> intents) {
  final summaries = [for (final intent in intents) intent.toSummaryJson()];
  return {'catalogIntentCount': '${summaries.length}', 'catalogBytes': '${jsonEncode(summaries).length}'};
}
