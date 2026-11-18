import 'package:aib_core/ports.dart';

import 'flutter_environment.dart';
import 'json_schema.dart';

/// The component vocabulary and the house rules a host's renderer accepts.
///
/// Published to the agent through `genui.catalog` and enforced by
/// [GenUiBridge] on every `genui.render`: a component type the renderer does
/// not know would otherwise reach the app as a blank box, and the agent would
/// never learn why.
///
/// [catalogId] is the A2UI catalog URI the host renders; it is what a
/// `createSurface` message must name. [protocolVersion] is the A2UI version its
/// messages carry: `v0.9` (default) or `1.0`.
final class GenUiCatalog {
  /// Component type name — exactly as it appears in a component's
  /// `"component"` field (`Text`, `Column`, `Card`, …) — mapped to the JSON
  /// schema of that component's properties.
  ///
  /// An empty schema means "this type exists, and that is all I know": the
  /// bridge then checks the name and nothing else. A host that can hand over
  /// its renderer's real schemas should, because the properties are where a
  /// model's mistakes actually land — a `Card` given `children` instead of
  /// `child` is a perfectly plausible document that renders as an error box.
  final Map<String, JsonMap> components;

  final String catalogId;

  /// `v0.9` or `1.0`.
  final String protocolVersion;

  /// Host-specific conventions the agent cannot infer from the component
  /// list — deep links, for instance. Sent verbatim with `genui.catalog`.
  final String rules;

  const GenUiCatalog({required this.components, this.catalogId = basicCatalogId, this.rules = '', this.protocolVersion = v0_9});

  static const v0_9 = 'v0.9';
  static const v1_0 = '1.0';

  /// The A2UI v0.9 basic catalog.
  static const basicCatalogId = 'https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json';

  /// The A2UI v1.0 basic catalog.
  static const basicV1CatalogId = 'https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json';

  /// The basic catalog's component *names* minus the ones that need an asset
  /// URL — an agent has no trustworthy source for one, so most hosts render
  /// without them.
  ///
  /// Names only: the schemas belong to the renderer, and the framework does
  /// not depend on one. A host should build its catalog from its renderer's
  /// component schemas instead, and get property validation with it.
  static const basicNoAssets = GenUiCatalog(components: _basicNoAssetComponents);

  /// [basicNoAssets] for A2UI v1.0: the same component names.
  static const basicNoAssetsV1 = GenUiCatalog(components: _basicNoAssetComponents, catalogId: basicV1CatalogId, protocolVersion: v1_0);

  static const _basicNoAssetComponents = <String, JsonMap>{
    'Button': {},
    'Card': {},
    'CheckBox': {},
    'ChoicePicker': {},
    'Column': {},
    'DateTimeInput': {},
    'Divider': {},
    'Icon': {},
    'List': {},
    'Modal': {},
    'Row': {},
    'Slider': {},
    'Tabs': {},
    'Text': {},
    'TextField': {},
  };

  /// Whether a message's `version` field is this catalog's protocol version
  /// (`1.0` may be written `v1.0`).
  bool acceptsVersion(Object? version) => protocolVersion == v1_0 ? version == '1.0' || version == 'v1.0' : version == protocolVersion;

  /// The component type names, sorted — what an error message lists.
  List<String> get componentNames => components.keys.toList()..sort();

  JsonMap toJson() => {
    'catalogId': catalogId,
    'protocolVersion': protocolVersion,
    'components': {for (final name in componentNames) name: components[name]!},
    if (rules.isNotEmpty) 'rules': rules,
  };

  /// What `genui.catalog` lists: the component names and the host rules,
  /// without the property schemas. The schemas are the bulk of it — 13 KB
  /// against 1.3 KB here — and a surface uses a handful of component types.
  JsonMap toSummaryJson() => {
    'catalogId': catalogId,
    'protocolVersion': protocolVersion,
    'components': componentNames,
    if (rules.isNotEmpty) 'rules': rules,
  };

  /// The property schemas of [names], for `genui.describe`. Unknown names come
  /// back in `unknown` rather than silently missing, or a model would read
  /// their absence as "no properties".
  JsonMap describe(Iterable<String> names) {
    final known = <String, JsonMap>{};
    final unknown = <String>[];
    for (final name in names) {
      final schema = components[name];
      if (schema == null) {
        unknown.add(name);
      } else {
        known[name] = schema;
      }
    }
    return {'components': known, if (unknown.isNotEmpty) 'unknown': unknown};
  }
}

/// genui envelope vocabulary — adapter convention (spec §4.4):
///
///   observe `data.context`  {} -> app-defined data document
///   observe `genui.catalog`  {} -> {catalogId, components: [names], rules?}
///   observe `genui.describe` {components: [names]} -> {components: {name:
///                                                      schema}, unknown?}
///   act     `genui.render`  {messages: [...]} -> {accepted, surfaces}
///
/// The payload is a batch of **A2UI messages** (https://a2ui.org) in the
/// catalog's protocol version (v0.9 by default, or 1.0; ADR 0012). A batch
/// because a surface needs
/// at least two messages (`createSurface`, then `updateComponents`), and one
/// render is one act.
///
/// ```json
/// {"messages": [
///   {"version": "v0.9",
///    "createSurface": {"surfaceId": "s1", "catalogId": "…/catalogs/basic/catalog.json"}},
///   {"version": "v0.9",
///    "updateComponents": {"surfaceId": "s1", "components": [
///      {"id": "root", "component": "Column", "children": ["t"]},
///      {"id": "t", "component": "Text", "text": "Hallo"}]}}
/// ]}
/// ```
///
/// The rendered surface is judged from the *trace*; [onMessages] additionally
/// lets the app display it live.
/// [GenUiBridge.prepare]'s output: the batch to show and what the result adds.
final class GenUiPrepared {
  const GenUiPrepared(this.messages, {this.result = const {}});

  final List<JsonMap> messages;
  final JsonMap result;
}

final class GenUiBridge {
  GenUiBridge({required this.dataContextProvider, this.catalog = GenUiCatalog.basicNoAssets, this.onMessages, this.prepare});

  /// The app data offered to generative-UI agents (e.g. all todos).
  final Future<JsonMap> Function() dataContextProvider;

  /// What the host's renderer understands. Enforced on every render.
  final GenUiCatalog catalog;

  /// Optional live rendering hook for the host app: one accepted batch.
  final void Function(List<JsonMap> messages)? onMessages;

  /// Optional host step between validation and display (e.g. a chart that
  /// names its data). A [FormatException] rejects the batch as
  /// `invalid_surface`.
  final Future<GenUiPrepared> Function(List<JsonMap> messages)? prepare;

  /// The last accepted batch (inspectable by tests/hosts).
  List<JsonMap>? lastMessages;

  /// Surfaces created so far, mapped to the component ids defined on them. An
  /// `updateComponents` may address a surface an *earlier* batch created, so
  /// this outlives a single render. Cleared by [reset].
  final _surfaces = <String, Set<String>>{};

  /// Forgets the surfaces of the previous episode. The environment calls this
  /// on a fixture reset; without it, the second batch of the second episode
  /// could update a surface only the first episode ever created.
  void reset() {
    _surfaces.clear();
    lastMessages = null;
  }

  void install(FlutterEnvironment environment) {
    environment.registerHandler(
      const EnvelopeSpec(key: 'data.context', kind: .observe, description: 'App data context for generative UI.'),
      (envelope) async => EnvelopeResult.ok(await dataContextProvider()),
    );

    environment.registerHandler(
      const EnvelopeSpec(
        key: 'genui.catalog',
        kind: .observe,
        description:
            'The A2UI component catalog this app renders: catalog id, the '
            'component names you may use and the host rules. Property '
            'schemas come from genui.describe.',
      ),
      (envelope) async => EnvelopeResult.ok(catalog.toSummaryJson()),
    );

    environment.registerHandler(
      const EnvelopeSpec(
        key: 'genui.describe',
        kind: .observe,
        description: 'Property schemas of the named A2UI component types.',
        payloadSchema: {
          'type': 'object',
          'properties': {
            'components': {
              'type': 'array',
              'items': {'type': 'string'},
            },
          },
          'required': ['components'],
        },
      ),
      (envelope) async {
        final wanted = [for (final raw in envelope.payload['components'] as List? ?? const []) '$raw'];
        if (wanted.isEmpty) {
          return EnvelopeResult.failed(EnvelopeError.badParams, 'components must not be empty');
        }
        return EnvelopeResult.ok(catalog.describe(wanted));
      },
    );

    environment.registerHandler(
      EnvelopeSpec(
        key: 'genui.render',
        kind: .act,
        description: 'Render a UI surface by applying a batch of A2UI ${catalog.protocolVersion} messages.',
        payloadSchema: {
          'type': 'object',
          'properties': {
            'messages': {
              'type': 'array',
              'items': {
                'type': 'object',
                // Read by agents to write the host's A2UI version.
                'properties': {
                  'version': {'const': catalog.protocolVersion},
                },
              },
            },
          },
          'required': ['messages'],
        },
      ),
      (envelope) async {
        final raw = envelope.payload['messages'];
        if (raw is! List || raw.isEmpty) {
          return EnvelopeResult.failed('bad_payload', '"messages" must be a non-empty list of A2UI messages');
        }
        final messages = <JsonMap>[];
        for (final (i, message) in raw.indexed) {
          if (message is! Map) {
            return EnvelopeResult.failed('bad_payload', 'messages[$i] must be a JSON object');
          }
          messages.add(asJsonMap(message));
        }

        // Validated against a copy, so a batch that fails halfway leaves no
        // half-created surface behind for the next one to build on.
        final surfaces = {
          for (final entry in _surfaces.entries) entry.key: {...entry.value},
        };
        final error = validateBatch(messages, catalog, surfaces: surfaces);
        if (error != null) {
          return EnvelopeResult.failed('invalid_surface', error);
        }

        var shown = messages;
        JsonMap added = const {};
        if (prepare case final prepare?) {
          try {
            final prepared = await prepare(messages);
            shown = prepared.messages;
            added = prepared.result;
          } on FormatException catch (e) {
            return EnvelopeResult.failed('invalid_surface', e.message);
          }
        }

        _surfaces
          ..clear()
          ..addAll(surfaces);
        lastMessages = shown;
        onMessages?.call(shown);
        return EnvelopeResult.ok({...added, 'accepted': true, 'surfaces': _surfaces.keys.toList()});
      },
    );
  }

  /// Structural validation of one A2UI batch; null = valid.
  ///
  /// [surfaces] maps a known surface id to the component ids defined on it, and
  /// is **updated in place** as the batch is walked.
  ///
  /// Rejects only documents the renderer could not act on, the violations that
  /// produce silence rather than an error: a surface never created, a batch
  /// with no `root`, an unknown component type, a `Card` given `children` where
  /// it wanted `child`.
  static String? validateBatch(List<JsonMap> messages, GenUiCatalog catalog, {required Map<String, Set<String>> surfaces}) {
    const bodyKeys = {'createSurface', 'updateComponents', 'updateDataModel', 'deleteSurface'};
    // Surfaces this batch touched. "No root" is only an error for those: a
    // batch that updates the data model of an existing surface says nothing
    // about that surface's components.
    final touched = <String>{};

    for (final (i, message) in messages.indexed) {
      if (!catalog.acceptsVersion(message['version'])) {
        return 'messages[$i].version must be "${catalog.protocolVersion}"';
      }
      final present = bodyKeys.where(message.containsKey).toList();
      if (present.length != 1) {
        return 'messages[$i] must contain exactly one of '
            '${bodyKeys.join(", ")}; got '
            '${present.isEmpty ? "none" : present.join(", ")}';
      }
      final key = present.single;
      final rawBody = message[key];
      if (rawBody is! Map) return 'messages[$i].$key must be an object';
      final body = asJsonMap(rawBody);
      final surfaceId = body['surfaceId'];
      if (surfaceId is! String || surfaceId.isEmpty) {
        return 'messages[$i].$key.surfaceId must be a non-empty string';
      }

      switch (key) {
        case 'createSurface':
          if (body['catalogId'] != catalog.catalogId) {
            return 'messages[$i].createSurface.catalogId must be '
                '"${catalog.catalogId}"';
          }
          surfaces[surfaceId] = <String>{};
          touched.add(surfaceId);
        case 'updateComponents':
          final known = surfaces[surfaceId];
          if (known == null) {
            return 'messages[$i].updateComponents addresses surface '
                '"$surfaceId", which no createSurface has created';
          }
          final error = _validateComponents(body['components'], catalog, known, 'messages[$i].updateComponents');
          if (error != null) return error;
          touched.add(surfaceId);
        case 'updateDataModel':
          if (!surfaces.containsKey(surfaceId)) {
            return 'messages[$i].updateDataModel addresses surface '
                '"$surfaceId", which no createSurface has created';
          }
        case 'deleteSurface':
          if (surfaces.remove(surfaceId) == null) {
            return 'messages[$i].deleteSurface addresses surface '
                '"$surfaceId", which no createSurface has created';
          }
          touched.remove(surfaceId);
      }
    }

    for (final surfaceId in touched) {
      if (!surfaces[surfaceId]!.contains('root')) {
        return 'surface "$surfaceId" has no component with id "root"; '
            'nothing would be displayed';
      }
    }
    return null;
  }

  static String? _validateComponents(Object? raw, GenUiCatalog catalog, Set<String> known, String where) {
    if (raw is! List || raw.isEmpty) {
      return '$where.components must be a non-empty list';
    }
    for (final (j, component) in raw.indexed) {
      if (component is! Map) return '$where.components[$j] must be an object';
      final map = asJsonMap(component);
      final id = map['id'];
      if (id is! String || id.isEmpty) {
        return '$where.components[$j].id must be a non-empty string';
      }
      final type = map['component'];
      if (type is! String || type.isEmpty) {
        return '$where.components[$j].component must be a non-empty string';
      }
      final schema = catalog.components[type];
      if (schema == null) {
        return '$where.components[$j].component "$type" is not in this app\'s '
            'catalog (${catalog.componentNames.join(", ")})';
      }
      // `id` addresses the component and belongs to no catalog item, so it
      // is dropped before the check; `component` is not, because A2UI
      // catalogs carry it as the discriminator (`package:genui` declares it
      // required, with the type name as its only allowed value).
      final properties = {
        for (final entry in map.entries)
          if (entry.key != 'id') entry.key: entry.value,
      };
      final violations = validateAgainstSchema(properties, schema);
      if (violations.isNotEmpty) {
        return '$where.components[$j] ($type "$id"): '
            '${violations.join("; ")}';
      }
      known.add(id);
    }
    return null;
  }
}
