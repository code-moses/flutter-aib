import 'dart:async';
import 'dart:convert';

import 'package:aib_core/ports.dart';

import 'flutter_environment.dart';
import 'json_schema.dart';

/// What invoking an intent does to the app, for confirmation policies and
/// harm metrics. Undeclared (null) is not the same as [none].
enum IntentEffect { none, reversible, irreversible, destructive }

/// One app capability exposed to intent-driven agents. Handlers call the
/// same use-case layer as the UI (parity requirement, spec §8.1); agents
/// present the catalog to the LLM as tools (function calling, spec §7).
final class AibIntent {
  const AibIntent({
    required this.name,
    required this.description,
    this.kind = .act,
    this.paramsSchema = const {},
    this.metadata = const {},
    this.effect,
    this.aliases = const [],
    this.examples = const [],
    this.requires = const [],
    required this.handler,
  });

  final String name;
  final String description;

  /// Whether invoking this intent *changes* the app or only reads it. The
  /// environment is the authority, not the agent: frame settling and step
  /// counting follow the kind declared here.
  final EnvelopeKind kind;

  /// JSON schema of the parameters. Published via `intents.catalog` and
  /// enforced by the bridge before the handler runs.
  final JsonMap paramsSchema;

  /// Free-form, app-owned annotations, published verbatim in the catalog. The
  /// framework attaches no meaning to these keys and never branches on them.
  final JsonMap metadata;

  final IntentEffect? effect;

  /// Other names this intent is known by, typically translations of its command
  /// label.
  ///
  /// Retrieval input, which is why it is a field: a preparing agent ranks the
  /// catalogue against the task's words. Published in the listing and dropped
  /// when the listing is rendered for the model, so it costs no tokens.
  final List<String> aliases;

  /// Worked calls: `{params, when?}`, the arguments of a good call and,
  /// optionally, the request it answers.
  ///
  /// For the model, not for retrieval, and published with the *description*
  /// (`intents.describe`, a capability delta): an example costs tokens on every
  /// turn the tool is offered. An agent shows them only under
  /// `agent.examples.intents`.
  final List<JsonMap> examples;

  /// Names of intents this one's parameters depend on — usually the listing
  /// an id comes from. `intents.describe` describes these alongside whatever
  /// was asked for (ADR 0016), so the round trip a task like "count by kind"
  /// needs (list the endpoint, read its filters, then count) collapses from
  /// one call per step to one call.
  final List<String> requires;

  final Future<Object?> Function(JsonMap params) handler;

  JsonMap toCatalogJson() => {
    'name': name,
    'description': description,
    'kind': kind.name,
    'paramsSchema': paramsSchema,
    'effect': ?effect?.name,
    if (metadata.isNotEmpty) 'metadata': metadata,
    if (examples.isNotEmpty) 'examples': examples,
    if (requires.isNotEmpty) 'requires': requires,
  };

  /// What `intents.catalog` lists: enough to decide whether to ask for the
  /// rest, and nothing more. [description]'s first sentence must therefore
  /// stand on its own — see [firstSentence].
  JsonMap toSummaryJson() => {
    'name': name,
    'summary': firstSentence(description),
    'kind': kind.name,
    if (paramsSchema.isNotEmpty) 'takesParameters': true,
    'effect': ?effect?.name,
    if (aliases.isNotEmpty) 'aliases': aliases,
    if (metadata.isNotEmpty) 'metadata': metadata,
    if (requires.isNotEmpty) 'needs': requires,
  };
}

/// Supplies the intents currently in scope. Called on *every* `intents.catalog`
/// observation, so the catalog tracks the app's live state.
typedef IntentCatalogProvider = Iterable<AibIntent> Function();

/// Intent envelope vocabulary — adapter convention (spec §4.4):
///
///   observe `intents.catalog`  {} -> {scope?, intents: [{name, summary, kind,
///                                                takesParameters?, metadata?,
///                                                needs?}]}
///   observe `intents.describe` {names} -> {intents: [{name, description,
///                                                     kind, paramsSchema,
///                                                     metadata?, examples?,
///                                                     requires?}],
///                                          autoIncluded?: [name, ...]}
///   act     `intents.invoke`   {intent, params} -> {result}
///
/// The catalog lists; `intents.describe` hands over descriptions and schemas.
///
/// Every result additionally carries `capabilities: {added, removed}` on the
/// first envelope after the set of in-scope intents changes; see
/// [_capabilityDelta].
final class IntentBridge {
  /// [catalogProvider] makes the catalog dynamic; without one the bridge serves
  /// whatever was [register]ed.
  ///
  /// [scope] is one sentence on what this app's intents can and cannot do,
  /// published once at the top of `intents.catalog` (ADR 0017).
  ///
  /// [invokeTimeout] bounds one `intents.invoke`: a handler that has not
  /// answered by then fails `handler_timeout`, and the agent gets its turn
  /// back. Null waits as long as the episode does.
  IntentBridge({this.catalogProvider, this.scope, this.invokeTimeout});

  final IntentCatalogProvider? catalogProvider;
  final String? scope;
  final Duration? invokeTimeout;
  final Map<String, AibIntent> _registered = {};

  /// Intent names the agent has been told about, either by an
  /// `intents.catalog` observation or by a delta on an earlier result. Null
  /// until the first catalog observation: before that the agent has been told
  /// nothing, and announcing a "change" against an empty set would report the
  /// whole catalog as new.
  Set<String>? _published;

  void register(AibIntent intent) {
    _registered[intent.name] = intent;
  }

  void registerAll(Iterable<AibIntent> intents) => intents.forEach(register);

  /// The intents in scope right now. Registered intents always participate;
  /// a provider's intents win on a name collision because they carry the
  /// live context.
  Iterable<AibIntent> currentIntents() {
    final provider = catalogProvider;
    if (provider == null) return _registered.values;
    final byName = <String, AibIntent>{..._registered};
    for (final intent in provider()) {
      byName[intent.name] = intent;
    }
    return byName.values;
  }

  /// What changed in the capability surface since the agent was last told, or
  /// null when nothing did. The app has to say so: a model holding a
  /// complete-looking tool list never re-observes.
  ///
  /// `added` carries the full catalog entry because the agent builds a tool
  /// definition from it; `removed` carries names only. Marking the set
  /// published here keeps a change from being announced twice.
  JsonMap? _capabilityDelta() {
    final published = _published;
    if (published == null) return null;
    final current = {for (final i in currentIntents()) i.name: i};
    final added = [
      for (final entry in current.entries)
        if (!published.contains(entry.key)) entry.value.toCatalogJson(),
    ];
    final removed = [
      for (final name in published)
        if (!current.containsKey(name)) name,
    ]..sort();
    if (added.isEmpty && removed.isEmpty) return null;
    _published = current.keys.toSet();
    return {if (added.isNotEmpty) 'added': added, if (removed.isNotEmpty) 'removed': removed};
  }

  void install(FlutterEnvironment environment) {
    environment.registerKindResolver(resolveKind);

    environment.registerResultDecorator((envelope, result) async {
      // The catalog observation republishes the whole set itself, so a delta
      // alongside it would say the same thing twice.
      if (envelope.key == 'intents.catalog' || envelope.key == 'intents.describe') {
        return result;
      }
      final delta = _capabilityDelta();
      if (delta == null) return result;
      return EnvelopeResult(
        status: result.status,
        payload: {...result.payload, 'capabilities': delta},
        error: result.error,
        userWaitMs: result.userWaitMs,
      );
    });

    environment.registerHandler(
      const EnvelopeSpec(
        key: 'intents.catalog',
        kind: .observe,
        description:
            'Lists the app intents in scope: name, one-line summary and kind '
            '(observe/act). Use intents.describe for the ones you need.',
      ),
      (envelope) async {
        final intents = currentIntents().toList();
        _published = {for (final intent in intents) intent.name};
        return EnvelopeResult.ok({
          if (scope != null) 'scope': scope,
          'intents': [for (final intent in _groupedForCatalog(intents)) intent.toSummaryJson()],
        });
      },
    );

    environment.registerHandler(
      const EnvelopeSpec(
        key: 'intents.describe',
        kind: .observe,
        description: 'Full description and parameter schema of the named intents.',
        payloadSchema: {
          'type': 'object',
          'properties': {
            'names': {
              'type': 'array',
              'items': {'type': 'string'},
            },
          },
          'required': ['names'],
        },
      ),
      (envelope) async {
        final wanted = [for (final raw in envelope.payload['names'] as List? ?? const []) '$raw'];
        if (wanted.isEmpty) {
          return EnvelopeResult.failed(EnvelopeError.badParams, 'names must not be empty');
        }
        final byName = {for (final i in currentIntents()) i.name: i};
        final found = [
          for (final name in wanted)
            if (byName.containsKey(name)) name,
        ];
        final unknown = [
          for (final name in wanted)
            if (!byName.containsKey(name)) name,
        ];
        // An unknown name must not fail the whole call: the names asked for
        // early are often scope-gated ones.
        if (found.isEmpty) {
          final known = byName.keys.toList()..sort();
          return EnvelopeResult.failed('unknown_intent', 'No intent ${unknown.join(', ')} (known: ${known.join(', ')})');
        }
        // ADR 0016: what was asked for needs, in scope, minus what was asked
        // for already — described alongside it, one round trip instead of the
        // discover-then-describe-then-describe chain a filtered count needs.
        final requiredNames = {for (final name in found) ...byName[name]!.requires}..removeAll(found);
        final autoIncluded = [
          for (final name in requiredNames)
            if (byName.containsKey(name)) name,
        ];
        return EnvelopeResult.ok({
          'intents': [
            for (final name in [...found, ...autoIncluded]) byName[name]!.toCatalogJson(),
          ],
          if (unknown.isNotEmpty) 'unknown': unknown,
          if (autoIncluded.isNotEmpty) 'autoIncluded': autoIncluded,
        });
      },
    );

    environment.registerHandler(
      const EnvelopeSpec(
        key: 'intents.invoke',
        kind: .act,
        description: 'Invokes an app intent by name.',
        payloadSchema: {
          'type': 'object',
          'properties': {
            'intent': {'type': 'string'},
            'params': {'type': 'object'},
          },
          'required': ['intent'],
        },
      ),
      (envelope) async {
        final name = envelope.payload['intent'] as String?;
        final intent = name == null ? null : currentIntents().where((i) => i.name == name).firstOrNull;
        if (intent == null) {
          final known = currentIntents().map((i) => i.name).toList()..sort();
          return EnvelopeResult.failed('unknown_intent', 'No intent "$name" (known: ${known.join(', ')})');
        }
        final params = asJsonMap(envelope.payload['params']);

        // Schema violations are the model's mistake, so `bad_params`, not
        // `handler_error`.
        final violations = validateAgainstSchema(params, intent.paramsSchema);
        if (violations.isNotEmpty) {
          return EnvelopeResult.failed(
            EnvelopeError.badParams,
            'Parameters for "$name" do not match its schema: '
            '${violations.join('; ')}',
            details: {'violations': violations, 'schema': intent.paramsSchema},
          );
        }

        try {
          final pending = intent.handler(params);
          final timeout = invokeTimeout;
          final Object? result;
          if (timeout == null) {
            result = await pending;
          } else {
            try {
              result = await Future.value(pending).timeout(timeout);
            } on TimeoutException {
              return EnvelopeResult.failed(
                'handler_timeout',
                'intent "$name" did not answer within ${timeout.inSeconds} s. It may still finish in the '
                    'background: read the state before you call it again.',
              );
            }
          }
          // A value that cannot be encoded would only fail later, in the
          // engine's accounting, as a framework fault with no intent attached.
          try {
            jsonEncode(result);
          } on JsonUnsupportedObjectError catch (e) {
            return EnvelopeResult.failed(
              'handler_error',
              'intent "$name" returned a value that is not JSON: '
                  '${e.unsupportedObject.runtimeType}',
            );
          }
          return EnvelopeResult.ok({'result': result});
        } on IntentRejected catch (e) {
          return EnvelopeResult.failed('intent_rejected', e.message, details: e.suggests.isEmpty ? null : {EnvelopeResult.suggestsKey: e.suggests});
        }
      },
    );
  }

  /// The kind the *environment* ascribes to an envelope, used by
  /// [FlutterEnvironment] to decide whether to settle frames. Returns
  /// null when this bridge does not own the envelope.
  EnvelopeKind? resolveKind(Envelope envelope) {
    if (envelope.key != 'intents.invoke') return null;
    final name = envelope.payload['intent'] as String?;
    if (name == null) return null;
    return currentIntents().where((i) => i.name == name).firstOrNull?.kind;
  }
}

/// [intents], with every intent sharing a `metadata['group']` value made
/// contiguous (ADR 0017).
///
/// A stable grouping: intents keep their relative order within a group, and
/// groups appear in the order their first member was registered. Ungrouped
/// intents form one group of their own.
List<AibIntent> _groupedForCatalog(List<AibIntent> intents) {
  final groups = <String, List<AibIntent>>{};
  for (final intent in intents) {
    final key = intent.metadata['group'] as String? ?? '';
    (groups[key] ??= []).add(intent);
  }
  return [for (final group in groups.values) ...group];
}

/// Domain-level rejection (validation error etc.) — reported as a structured
/// `failed` result instead of a handler crash.
final class IntentRejected implements Exception {
  const IntentRejected(this.message, {this.suggests = const []});

  final String message;

  /// Intents (or envelope keys) that answer this dead end; published as
  /// `error.details.suggests` so a metric can tell advice from a dead end.
  final List<String> suggests;

  @override
  String toString() => 'IntentRejected: $message';
}
