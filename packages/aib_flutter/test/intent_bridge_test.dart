import 'dart:async';

import 'package:aib_core/ports.dart';
import 'package:aib_flutter/aib_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

AibIntent _intent(
  String name, {
  EnvelopeKind kind = .act,
  JsonMap schema = const {},
  JsonMap metadata = const {},
  List<String> requires = const [],
  Future<Object?> Function(JsonMap)? handler,
}) => AibIntent(
  name: name,
  description: 'd',
  kind: kind,
  paramsSchema: schema,
  metadata: metadata,
  requires: requires,
  handler: handler ?? (params) async => 'ok',
);

Envelope _invoke(String name, [JsonMap params = const {}]) =>
    Envelope(key: 'intents.invoke', kind: .act, payload: {'intent': name, 'params': params});

void main() {
  test('a handler that never answers fails handler_timeout instead of holding the episode', () async {
    final environment = FlutterEnvironment(environmentId: 'test');
    final never = Completer<Object?>();
    IntentBridge(invokeTimeout: const Duration(milliseconds: 50))
      ..register(_intent('form.set', handler: (_) => never.future))
      ..register(_intent('form.describe'))
      ..install(environment);
    final hung = await environment.handle(_invoke('form.set'));
    expect(hung.status, EnvelopeStatus.failed);
    expect(hung.error!.code, 'handler_timeout');
    expect(hung.error!.message, contains('read the state'));
    expect((await environment.handle(_invoke('form.describe'))).status, EnvelopeStatus.ok);
  });

  group('AibIntent metadata passthrough', () {
    test('app-specific fields ride in metadata, untouched by the framework', () {
      final json = _intent(
        'form.submit',
        metadata: const {
          'policy': 'confirm',
          'requiredPermissions': ['CreateOrder'],
          'requiresConnection': true,
          'scopeId': 'draft-17',
        },
      ).toCatalogJson();

      // The framework publishes them verbatim and attaches no meaning: one
      // product's domain model must not leak into a framework meant for many.
      expect(asJsonMap(json['metadata'])['policy'], 'confirm');
      expect(asJsonMap(json['metadata'])['scopeId'], 'draft-17');
      expect(json['kind'], 'act');
    });

    test('a declared effect is published in the listing and the schema', () {
      Future<Object?> none(JsonMap _) async => null;
      final submit = AibIntent(name: 'form.submit', description: 'Submits the open form.', effect: .irreversible, handler: none);
      expect(submit.toSummaryJson()['effect'], 'irreversible');
      expect(submit.toCatalogJson()['effect'], 'irreversible');
      expect(_intent('nav.back').toSummaryJson(), isNot(contains('effect')));
    });

    test('a rejection that names a way on publishes it as suggests', () async {
      final environment = FlutterEnvironment(environmentId: 'test');
      IntentBridge(
        catalogProvider: () => [
          AibIntent(
            name: 'form.open',
            description: 'Opens a form.',
            handler: (_) async => throw const IntentRejected('no form', suggests: ['app.forms']),
          ),
        ],
      ).install(environment);
      final result = await environment.handle(const Envelope(key: 'intents.invoke', kind: .act, payload: {'intent': 'form.open'}));
      expect(result.error!.details, {
        'suggests': ['app.forms'],
      });
    });

    test('examples ride with the description, not the summary listing', () async {
      Future<Object?> none(JsonMap _) async => null;
      final find = AibIntent(
        name: 'todo.find',
        description: 'Finds todos.',
        examples: const [
          {
            'when': 'Show me what is overdue',
            'params': {'overdue': true},
          },
        ],
        handler: none,
      );
      // Paid only for an intent the agent chose to describe: an example is
      // re-sent every turn the tool is offered.
      expect(find.toCatalogJson()['examples'], [
        {
          'when': 'Show me what is overdue',
          'params': {'overdue': true},
        },
      ]);
      expect(find.toSummaryJson(), isNot(contains('examples')));
      expect(_intent('nav.back').toCatalogJson(), isNot(contains('examples')));

      final environment = FlutterEnvironment(environmentId: 'test');
      IntentBridge(catalogProvider: () => [find]).install(environment);
      final described = await environment.handle(
        const Envelope(
          key: 'intents.describe',
          kind: .observe,
          payload: {
            'names': ['todo.find'],
          },
        ),
      );
      expect(asJsonMap((described.payload['intents'] as List).single)['examples'], isNotEmpty);
    });

    test('an intent without metadata does not publish an empty map', () {
      expect(_intent('nav.back').toCatalogJson().containsKey('metadata'), isFalse);
    });
  });

  group('catalog provider', () {
    test('is consulted on every observation, so the catalog tracks context', () async {
      var onDetailPage = false;
      final bridge = IntentBridge(catalogProvider: () => [_intent('nav.back'), if (onDetailPage) _intent('action.invoke')]);
      final environment = FlutterEnvironment(environmentId: 'test');
      bridge.install(environment);

      Future<List<String>> names() async {
        final result = await environment.handle(const Envelope(key: 'intents.catalog', kind: .observe));
        return [for (final raw in result.payload['intents'] as List) asJsonMap(raw)['name'] as String];
      }

      expect(await names(), ['nav.back']);
      onDetailPage = true;
      // A static map would still be answering with the home screen's intents.
      expect(await names(), ['nav.back', 'action.invoke']);
    });

    test('the catalog summarises; intents.describe hands over the rest', () async {
      final environment = FlutterEnvironment(environmentId: 'test');
      IntentBridge(
        catalogProvider: () => [
          AibIntent(
            name: 'form.open',
            description:
                'Opens a form by assemblyId and maskId. Only for masks the '
                'user may see, and only one at a time.',
            kind: .act,
            paramsSchema: const {
              'type': 'object',
              'properties': {
                'maskId': {'type': 'integer'},
              },
            },
            handler: (params) async => 'ok',
          ),
        ],
      ).install(environment);

      final listing = asJsonMap(
        ((await environment.handle(const Envelope(key: 'intents.catalog', kind: .observe))).payload['intents'] as List).single,
      );
      expect(listing['name'], 'form.open');
      expect(listing['summary'], 'Opens a form by assemblyId and maskId.');
      expect(listing['takesParameters'], true);
      expect(listing, isNot(contains('paramsSchema')));
      expect(listing, isNot(contains('description')));

      final described = await environment.handle(
        const Envelope(
          key: 'intents.describe',
          kind: .observe,
          payload: {
            'names': ['form.open'],
          },
        ),
      );
      final full = asJsonMap((described.payload['intents'] as List).single);
      expect(full['description'], startsWith('Opens a form by assemblyId'));
      expect(asJsonMap(full['paramsSchema'])['properties'], contains('maskId'));

      // A name nothing answers to is an error, not a silent omission.
      final unknown = await environment.handle(
        const Envelope(
          key: 'intents.describe',
          kind: .observe,
          payload: {
            'names': ['nope'],
          },
        ),
      );
      expect(unknown.status, EnvelopeStatus.failed);
      expect(unknown.error!.code, 'unknown_intent');

      // But one bad name among good ones describes the good ones and
      // reports the rest: the prompt asks the model to describe
      // generously, and the names it reaches for first are the
      // scope-gated ones (`form.set` before a form is open).
      final partial = await environment.handle(
        const Envelope(
          key: 'intents.describe',
          kind: .observe,
          payload: {
            'names': ['form.open', 'form.set'],
          },
        ),
      );
      expect(partial.status, EnvelopeStatus.ok);
      expect([for (final raw in partial.payload['intents'] as List) asJsonMap(raw)['name']], ['form.open']);
      expect(partial.payload['unknown'], ['form.set']);
    });

    test('a described intent brings its requires along (ADR 0016)', () async {
      final environment = FlutterEnvironment(environmentId: 'test');
      IntentBridge(
        catalogProvider: () => [
          _intent('data.count', requires: const ['app.endpoints', 'endpoint.describe']),
          _intent('app.endpoints'),
          _intent('endpoint.describe'),
          _intent('data.list'),
        ],
      ).install(environment);

      final catalog = await environment.handle(const Envelope(key: 'intents.catalog', kind: .observe));
      final summary = (catalog.payload['intents'] as List).map(asJsonMap).firstWhere((i) => i['name'] == 'data.count');
      expect(summary['needs'], ['app.endpoints', 'endpoint.describe']);

      final described = await environment.handle(
        const Envelope(
          key: 'intents.describe',
          kind: .observe,
          payload: {
            'names': ['data.count'],
          },
        ),
      );
      final names = [for (final raw in described.payload['intents'] as List) asJsonMap(raw)['name']];
      expect(names, ['data.count', 'app.endpoints', 'endpoint.describe']);
      expect(described.payload['autoIncluded'], ['app.endpoints', 'endpoint.describe']);
    });

    test('a require already asked for is not duplicated or marked auto-included', () async {
      final environment = FlutterEnvironment(environmentId: 'test');
      IntentBridge(
        catalogProvider: () => [
          _intent('data.count', requires: const ['app.endpoints']),
          _intent('app.endpoints'),
        ],
      ).install(environment);

      final described = await environment.handle(
        const Envelope(
          key: 'intents.describe',
          kind: .observe,
          payload: {
            'names': ['data.count', 'app.endpoints'],
          },
        ),
      );
      final names = [for (final raw in described.payload['intents'] as List) asJsonMap(raw)['name']];
      expect(names, ['data.count', 'app.endpoints']);
      expect(described.payload, isNot(contains('autoIncluded')));
    });

    test('a require out of scope is skipped, not a dangling name', () async {
      final environment = FlutterEnvironment(environmentId: 'test');
      IntentBridge(
        catalogProvider: () => [
          _intent('data.count', requires: const ['form.set']),
        ],
      ).install(environment);

      final described = await environment.handle(
        const Envelope(
          key: 'intents.describe',
          kind: .observe,
          payload: {
            'names': ['data.count'],
          },
        ),
      );
      expect(described.status, EnvelopeStatus.ok);
      expect([for (final raw in described.payload['intents'] as List) asJsonMap(raw)['name']], ['data.count']);
      expect(described.payload, isNot(contains('autoIncluded')));
    });

    test('describing an intent is not a capability change', () async {
      var formOpen = false;
      final environment = FlutterEnvironment(environmentId: 'test');
      IntentBridge(catalogProvider: () => [_intent('form.open'), if (formOpen) _intent('form.set')]).install(environment);

      await environment.handle(const Envelope(key: 'intents.catalog', kind: .observe));
      formOpen = true;
      // A describe must not carry the delta: it would announce form.set as
      // new *and* return it, and the agent would ingest it twice.
      final described = await environment.handle(
        const Envelope(
          key: 'intents.describe',
          kind: .observe,
          payload: {
            'names': ['form.open'],
          },
        ),
      );
      expect(described.payload, isNot(contains('capabilities')));
    });

    test('invoking an intent that has left scope fails structurally', () async {
      var mounted = true;
      final bridge = IntentBridge(catalogProvider: () => [if (mounted) _intent('form.set')]);
      final environment = FlutterEnvironment(environmentId: 'test');
      bridge.install(environment);

      expect((await environment.handle(_invoke('form.set'))).status, EnvelopeStatus.ok);
      mounted = false;
      final gone = await environment.handle(_invoke('form.set'));
      expect(gone.status, EnvelopeStatus.failed);
      expect(gone.error!.code, 'unknown_intent');
    });

    test('the catalog groups intents sharing a metadata group, in first-seen order', () async {
      final bridge = IntentBridge(
        catalogProvider: () => [
          _intent('data.count', metadata: const {'group': 'data'}),
          _intent('nav.open', metadata: const {'group': 'navigate'}),
          _intent('app.endpoints', metadata: const {'group': 'discover'}),
          _intent('data.list', metadata: const {'group': 'data'}),
          _intent('nav.back', metadata: const {'group': 'navigate'}),
        ],
      );
      final environment = FlutterEnvironment(environmentId: 'test');
      bridge.install(environment);

      final result = await environment.handle(const Envelope(key: 'intents.catalog', kind: .observe));
      final names = [for (final raw in result.payload['intents'] as List) asJsonMap(raw)['name'] as String];
      // "data" is first seen at position 0 and "navigate" at position 1, so
      // both groups stay contiguous in that order; within a group,
      // registration order (data.count before data.list) is kept.
      expect(names, ['data.count', 'data.list', 'nav.open', 'nav.back', 'app.endpoints']);
    });

    test('an app that never sets a group gets back its registration order, unchanged', () async {
      final bridge = IntentBridge(catalogProvider: () => [_intent('c'), _intent('a'), _intent('b')]);
      final environment = FlutterEnvironment(environmentId: 'test');
      bridge.install(environment);

      final result = await environment.handle(const Envelope(key: 'intents.catalog', kind: .observe));
      final names = [for (final raw in result.payload['intents'] as List) asJsonMap(raw)['name'] as String];
      expect(names, ['c', 'a', 'b']);
    });

    test('a scope sentence rides once at the top of the catalog, not per intent', () async {
      final environment = FlutterEnvironment(environmentId: 'test');
      IntentBridge(
        scope: 'Reads endpoints and forms, opens pages, fills and submits forms; nothing deletes a record.',
        catalogProvider: () => [_intent('nav.back')],
      ).install(environment);

      final result = await environment.handle(const Envelope(key: 'intents.catalog', kind: .observe));
      expect(result.payload['scope'], startsWith('Reads endpoints and forms'));
      final listing = asJsonMap((result.payload['intents'] as List).single);
      expect(listing, isNot(contains('scope')), reason: 'stated once, not per intent');
    });

    test('no scope given means none is published', () async {
      final environment = FlutterEnvironment(environmentId: 'test');
      IntentBridge(catalogProvider: () => [_intent('nav.back')]).install(environment);

      final result = await environment.handle(const Envelope(key: 'intents.catalog', kind: .observe));
      expect(result.payload, isNot(contains('scope')));
    });
  });

  group('capability deltas', () {
    /// The defect these exist for: `form.*` is mounted by the open form, the
    /// agent observes the catalog once at bootstrap, and a model looking at a
    /// complete-looking tool list never re-observes. Across 90 episodes of
    /// `sysco-sonnet5-a2ui-v1`, `form.set` was never seen and never called.
    late bool formOpen;
    late FlutterEnvironment environment;

    setUp(() {
      formOpen = false;
      environment = FlutterEnvironment(environmentId: 'test');
      IntentBridge(
        catalogProvider: () => [
          _intent('form.open'),
          if (formOpen) ...[_intent('form.set'), _intent('form.submit')],
        ],
      ).install(environment);
    });

    Future<EnvelopeResult> observeCatalog() => environment.handle(const Envelope(key: 'intents.catalog', kind: .observe));

    test('an act that grows the surface says so, unprompted', () async {
      await observeCatalog();

      formOpen = true;
      final result = await environment.handle(_invoke('form.open'));

      final delta = asJsonMap(result.payload['capabilities']);
      expect(delta['removed'], isNull);
      expect([for (final raw in delta['added'] as List) asJsonMap(raw)['name']], ['form.set', 'form.submit']);
      // Full entries, not names: the agent builds tool definitions from them
      // and cannot spend a turn asking for the schemas.
      final added = asJsonMap((delta['added'] as List).first);
      expect(added, contains('paramsSchema'));
      expect(added, contains('description'));
    });

    test('a change is announced once, not on every envelope after it', () async {
      await observeCatalog();
      formOpen = true;
      await environment.handle(_invoke('form.open'));

      final next = await environment.handle(_invoke('form.open'));
      expect(next.payload.containsKey('capabilities'), isFalse);
    });

    test('leaving scope is reported as names only', () async {
      await observeCatalog();
      formOpen = true;
      await environment.handle(_invoke('form.open'));

      formOpen = false;
      final closed = await environment.handle(_invoke('form.open'));
      final delta = asJsonMap(closed.payload['capabilities']);
      expect(delta['removed'], ['form.set', 'form.submit']);
      expect(delta['added'], isNull);
    });

    test('nothing is announced before the agent has seen a catalog', () async {
      // Otherwise the first act of an episode reports the entire catalog as
      // new, which is noise rather than news.
      formOpen = true;
      final result = await environment.handle(_invoke('form.open'));
      expect(result.payload.containsKey('capabilities'), isFalse);
    });

    test('the catalog observation carries no delta of its own', () async {
      await observeCatalog();
      formOpen = true;
      final catalog = await observeCatalog();
      expect(catalog.payload.containsKey('capabilities'), isFalse);
      expect((catalog.payload['intents'] as List), hasLength(3));
    });
  });

  group('parameter validation', () {
    late FlutterEnvironment environment;

    setUp(() {
      environment = FlutterEnvironment(environmentId: 'test');
      IntentBridge()
        ..register(
          _intent(
            'data.search',
            schema: const {
              'type': 'object',
              'properties': {
                'endpointId': {'type': 'integer'},
                'query': {'type': 'string'},
                'limit': {'type': 'integer', 'minimum': 1, 'maximum': 50},
              },
              'required': ['endpointId', 'query'],
            },
          ),
        )
        ..install(environment);
    });

    test('a missing required parameter is bad_params, not handler_error', () async {
      final result = await environment.handle(_invoke('data.search', const {'query': 'Geberit'}));
      expect(result.status, EnvelopeStatus.failed);
      // The distinction that matters: the model got it wrong, the app did not.
      expect(result.error!.code, 'bad_params');
      expect(result.error!.message, contains('endpointId'));
    });

    test('a wrong type names the path and what was expected', () async {
      final result = await environment.handle(_invoke('data.search', const {'endpointId': 'twelve', 'query': 'x'}));
      expect(result.error!.code, 'bad_params');
      expect(result.error!.message, contains(r'$.endpointId'));
      expect(result.error!.message, contains('integer'));
    });

    test('a value outside its range is rejected', () async {
      final result = await environment.handle(_invoke('data.search', const {'endpointId': 12, 'query': 'x', 'limit': 5000}));
      expect(result.error!.code, 'bad_params');
      expect(result.error!.message, contains('maximum'));
    });

    test('valid parameters reach the handler', () async {
      final result = await environment.handle(_invoke('data.search', const {'endpointId': 12, 'query': 'x'}));
      expect(result.status, EnvelopeStatus.ok);
      expect(result.payload['result'], 'ok');
    });

    test('an empty schema accepts anything, as before', () async {
      final env = FlutterEnvironment(environmentId: 'test');
      IntentBridge()
        ..register(_intent('legacy.intent'))
        ..install(env);
      final result = await env.handle(_invoke('legacy.intent', const {'whatever': true}));
      expect(result.status, EnvelopeStatus.ok);
    });
  });

  group('envelope kind is decided by the environment (F6)', () {
    testWidgets('a mutating intent settles frames even if declared observe', (tester) async {
      var settles = 0;
      final environment = FlutterEnvironment(environmentId: 'test', settle: () async => settles++);
      IntentBridge()
        ..register(_intent('form.describe', kind: .observe))
        ..register(_intent('form.set'))
        ..install(environment);

      // The agent declares observe for both; only the catalog knows better.
      await environment.handle(const Envelope(key: 'intents.invoke', kind: .observe, payload: {'intent': 'form.describe'}));
      expect(settles, 0, reason: 'a read-only intent needs no frame');

      await environment.handle(
        const Envelope(
          key: 'intents.invoke',
          kind: .observe, // a lie, or an honest mistake
          payload: {'intent': 'form.set'},
        ),
      );
      // Before F6 this skipped settling and the next observation read a
      // half-rendered tree — a measurement artefact that looks like the agent
      // misreading the screen.
      expect(settles, 1);
    });

    test('an unknown key is assumed to act', () {
      final environment = FlutterEnvironment(environmentId: 'test');
      expect(environment.resolvedKind(const Envelope(key: 'mystery', kind: .observe)), EnvelopeKind.act);
    });
  });
}
