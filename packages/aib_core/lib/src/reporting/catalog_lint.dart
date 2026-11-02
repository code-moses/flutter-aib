import 'dart:convert';

import '../common/json.dart';
import '../trace/trace.dart';

/// The shortest description ARTEMIS accepts for an extension tool, and a
/// reasonable floor for any listing entry a model chooses from.
const catalogMinDescriptionLength = 40;

/// One intent as the agent sees it: what the listing shows, plus what
/// `intents.describe` adds once it is asked for.
final class CatalogEntry {
  const CatalogEntry({
    required this.name,
    this.summary,
    this.description,
    this.kind,
    this.effect,
    this.takesParameters,
    this.paramsSchema,
    this.bytes,
  });

  final String name;
  final String? summary;
  final String? description;
  final String? kind;
  final String? effect;
  final bool? takesParameters;
  final JsonMap? paramsSchema;

  /// Encoded size of this entry in the listing, for the size report.
  final int? bytes;

  /// What the listing shows, and the whole of what a choice is made on.
  String? get firstSentence {
    final text = summary ?? description;
    if (text == null || text.trim().isEmpty) return null;
    final end = RegExp(r'[.!?](\s|$)').firstMatch(text);
    return (end == null ? text : text.substring(0, end.start + 1)).trim();
  }
}

/// A rule a catalogue entry breaks. [isError] separates what will break a run
/// from what will cost it turns.
final class CatalogFinding {
  const CatalogFinding({required this.rule, required this.intent, required this.message, this.isError = false});

  final String rule;
  final String intent;
  final String message;
  final bool isError;
}

/// Lints the intent listing an app publishes.
///
/// Only what is mechanically decidable: whether a first sentence says *when*
/// the intent is needed is a judgement no lint makes. On a healthy catalogue
/// these rules say nothing; their value is catching regressions.
List<CatalogFinding> catalogLint(List<CatalogEntry> entries, {int minDescriptionLength = catalogMinDescriptionLength}) {
  final findings = <CatalogFinding>[];
  final byFirstSentence = <String, List<String>>{};

  for (final entry in entries) {
    final sentence = entry.firstSentence;
    if (sentence == null) {
      findings.add(
        CatalogFinding(rule: 'no_summary', intent: entry.name, message: 'Nothing to choose it by: the listing shows an empty line.', isError: true),
      );
    } else {
      byFirstSentence.putIfAbsent(sentence.toLowerCase(), () => []).add(entry.name);
      final text = entry.description ?? entry.summary ?? '';
      if (text.trim().length < minDescriptionLength) {
        findings.add(
          CatalogFinding(
            rule: 'short_description',
            intent: entry.name,
            message:
                '${text.trim().length} characters, under $minDescriptionLength. '
                'Say what it does and what addresses it.',
          ),
        );
      }
    }

    // A `{}` schema is *not* a finding on its own: a parameterless intent
    // publishes one, and `IntentStrategy.objectSchema` normalises it before it
    // reaches an API that would reject it. It is only wrong when the listing
    // promised parameters.
    final schema = entry.paramsSchema;
    if (schema != null && schema.isNotEmpty && schema['type'] != 'object') {
      findings.add(
        CatalogFinding(
          rule: 'non_object_schema',
          intent: entry.name,
          message: 'paramsSchema is not an object schema; function calling wants one.',
          isError: true,
        ),
      );
    }
    if (entry.takesParameters == true && schema != null && schema.isEmpty) {
      findings.add(
        CatalogFinding(
          rule: 'undescribed_parameters',
          intent: entry.name,
          message: 'The listing says it takes parameters and describe shows none.',
          isError: true,
        ),
      );
    }

    // An intent that acts and declares no effect is measured as undeclared,
    // never as harmless — it silently leaves `harm_severity` unscored.
    if (entry.kind == 'act' && (entry.effect == null || entry.effect!.isEmpty)) {
      findings.add(
        CatalogFinding(rule: 'undeclared_effect', intent: entry.name, message: 'An act intent with no IntentEffect is measured as undeclared.'),
      );
    }
  }

  for (final duplicate in byFirstSentence.entries.where((e) => e.value.length > 1)) {
    for (final name in duplicate.value) {
      findings.add(
        CatalogFinding(
          rule: 'duplicate_summary',
          intent: name,
          message: 'Same first sentence as ${duplicate.value.where((n) => n != name).join(", ")}.',
          isError: true,
        ),
      );
    }
  }

  return findings..sort((a, b) => a.intent.compareTo(b.intent));
}

/// Intent names a prompt mentions that the catalogue does not publish.
///
/// A prompt that names a renamed intent teaches the model a tool that is not
/// there, and nothing else in the pipeline notices.
List<String> promptIntentsNotInCatalog(String prompt, List<CatalogEntry> entries) {
  final published = {for (final e in entries) e.name};
  final mentioned = RegExp(r'\b[a-z][a-zA-Z]*\.[a-z][a-zA-Z]+\b').allMatches(prompt).map((m) => m.group(0)!).toSet();
  // Only names shaped like this catalogue's: a prompt also mentions file
  // extensions and prose with dots in it.
  final namespaces = {for (final e in entries) e.name.split('.').first};
  return [
    for (final name in mentioned)
      if (namespaces.contains(name.split('.').first) && !published.contains(name)) name,
  ]..sort();
}

/// Reads the catalogue an episode was shown (the results of [listingKey]),
/// merging in what other results listing `intents` revealed about the same
/// entries, such as a describe call. The key is the environment's vocabulary,
/// so the caller names it.
///
/// Reads `description` and `paramsSchema` too, because a catalogue before
/// schema version 3 carried them in the listing itself.
List<CatalogEntry> catalogFromTraces(List<EpisodeTrace> traces, {required String listingKey}) {
  final listing = <String, JsonMap>{};
  final described = <String, JsonMap>{};
  final bytes = <String, int>{};
  for (final trace in traces) {
    for (final exchange in trace.exchanges()) {
      if (exchange.status != 'ok') continue;
      final payload = asJsonMap(exchange.result?.data['payload']);
      final intents = payload['intents'] as List?;
      if (intents == null) continue;
      final target = exchange.key == listingKey ? listing : described;
      for (final raw in intents) {
        final intent = asJsonMap(raw);
        if (intent['name'] case final String name) {
          target[name] = intent;
          if (target == listing) bytes[name] = jsonEncode(intent).length;
        }
      }
    }
  }
  return [
    for (final name in {...listing.keys, ...described.keys})
      CatalogEntry(
        name: name,
        summary: (listing[name]?['summary'] ?? listing[name]?['description']) as String?,
        description: (described[name]?['description'] ?? listing[name]?['description']) as String?,
        kind: (listing[name] ?? described[name] ?? const {})['kind'] as String?,
        effect: (listing[name] ?? described[name] ?? const {})['effect'] as String?,
        takesParameters: listing[name]?['takesParameters'] as bool?,
        paramsSchema: switch (described[name]?['paramsSchema'] ?? listing[name]?['paramsSchema']) {
          null => null,
          final schema => asJsonMap(schema),
        },
        bytes: bytes[name],
      ),
  ]..sort((a, b) => a.name.compareTo(b.name));
}

String catalogLintMarkdown(List<CatalogEntry> entries, List<CatalogFinding> findings, {List<String> promptOnly = const []}) {
  final buffer = StringBuffer();
  final errors = findings.where((f) => f.isError).length;
  buffer
    ..writeln('## Catalogue lint')
    ..writeln()
    ..writeln(
      '${entries.length} intents, ${findings.length} findings '
      '($errors will break a request, ${findings.length - errors} will cost turns).',
    )
    ..writeln();
  if (findings.isNotEmpty) {
    buffer
      ..writeln('| | intent | rule | what |')
      ..writeln('|---|---|---|---|');
    for (final f in findings) {
      buffer.writeln('| ${f.isError ? '✗' : '!'} | `${f.intent}` | ${f.rule} | ${f.message} |');
    }
    buffer.writeln();
  }
  if (promptOnly.isNotEmpty) {
    buffer
      ..writeln(
        '**The prompt names intents the catalogue does not publish:** '
        '${promptOnly.map((n) => '`$n`').join(', ')}.',
      )
      ..writeln();
  }

  final sized = entries.where((e) => e.bytes != null).toList()..sort((a, b) => b.bytes!.compareTo(a.bytes!));
  if (sized.isNotEmpty) {
    final total = sized.fold<int>(0, (sum, e) => sum + e.bytes!);
    buffer
      ..writeln('### Listing size')
      ..writeln()
      ..writeln('$total bytes, re-sent on every turn of every episode.')
      ..writeln()
      ..writeln('| intent | bytes |')
      ..writeln('|---|---|');
    for (final entry in sized.take(10)) {
      buffer.writeln('| `${entry.name}` | ${entry.bytes} |');
    }
    buffer.writeln();
  }
  return buffer.toString();
}
