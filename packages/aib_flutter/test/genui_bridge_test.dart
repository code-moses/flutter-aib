import 'package:aib_core/aib_core.dart';
import 'package:aib_flutter/aib_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  JsonMap create([String surfaceId = 'main']) => {
    'version': 'v0.9',
    'createSurface': {'surfaceId': surfaceId, 'catalogId': GenUiCatalog.basicCatalogId},
  };

  JsonMap update({
    String surfaceId = 'main',
    List<JsonMap> components = const [
      {
        'id': 'root',
        'component': 'Column',
        'children': ['t'],
      },
      {'id': 't', 'component': 'Text', 'text': 'Blumen gießen'},
    ],
  }) => {
    'version': 'v0.9',
    'updateComponents': {'surfaceId': surfaceId, 'components': components},
  };

  late GenUiBridge bridge;

  FlutterEnvironment build({void Function(List<JsonMap>)? onMessages}) {
    final environment = FlutterEnvironment(environmentId: 'test');
    bridge = GenUiBridge(
      dataContextProvider: () async => {
        'todos': [
          {'title': 'Blumen gießen', 'completed': false},
        ],
      },
      onMessages: onMessages,
    )..install(environment);
    return environment;
  }

  Future<EnvelopeResult> render(FlutterEnvironment environment, Object? messages) =>
      environment.handle(Envelope(key: 'genui.render', kind: .act, payload: {'messages': messages}));

  test('data.context serves the app data document', () async {
    final result = await build().handle(const Envelope(key: 'data.context', kind: .observe));
    expect(result.status, EnvelopeStatus.ok);
    expect((result.payload['todos'] as List).single, containsPair('title', 'Blumen gießen'));
  });

  test('genui.catalog lists component names, not their schemas', () async {
    final result = await build().handle(const Envelope(key: 'genui.catalog', kind: .observe));
    expect(result.status, EnvelopeStatus.ok);
    expect(result.payload['catalogId'], GenUiCatalog.basicCatalogId);
    // A list now: the schemas are 13 KB against 1.3 KB for the names, and a
    // surface uses a handful of types.
    expect(result.payload['components'], isA<List<String>>());
    expect(result.payload['components'], contains('Text'));
    // The default catalog is the one without assets: an agent has no
    // trustworthy source for an image URL.
    expect(result.payload['components'], isNot(contains('Image')));
  });

  test('genui.describe hands over the schemas of the named components', () async {
    final environment = build();
    final result = await environment.handle(
      const Envelope(
        key: 'genui.describe',
        kind: .observe,
        payload: {
          'components': ['Text', 'Nonexistent'],
        },
      ),
    );
    expect(result.status, EnvelopeStatus.ok);
    expect(asJsonMap(result.payload['components']), contains('Text'));
    // Named back rather than silently missing, or their absence reads as
    // "this component has no properties".
    expect(result.payload['unknown'], ['Nonexistent']);

    final empty = await environment.handle(const Envelope(key: 'genui.describe', kind: .observe, payload: {'components': <String>[]}));
    expect(empty.status, EnvelopeStatus.failed);
  });

  test('genui.render accepts an A2UI batch and notifies the host', () async {
    List<JsonMap>? rendered;
    final environment = build(onMessages: (m) => rendered = m);
    final result = await render(environment, [create(), update()]);

    expect(result.status, EnvelopeStatus.ok, reason: result.error?.message);
    expect(result.payload['accepted'], true);
    expect(result.payload['surfaces'], ['main']);
    expect(rendered, hasLength(2));
    expect(bridge.lastMessages, rendered);
  });

  test('a later batch may update a surface an earlier one created', () async {
    final environment = build();
    await render(environment, [create(), update()]);

    final result = await render(environment, [
      update(
        components: const [
          {'id': 'root', 'component': 'Text', 'text': 'Fertig'},
        ],
      ),
    ]);
    expect(result.status, EnvelopeStatus.ok, reason: result.error?.message);
  });

  test("reset forgets the previous episode's surfaces", () async {
    final environment = build();
    await render(environment, [create(), update()]);
    bridge.reset();

    final result = await render(environment, [update()]);
    expect(result.error?.code, 'invalid_surface');
    expect(result.error?.message, contains('no createSurface'));
    expect(bridge.lastMessages, isNull);
  });

  test('malformed batches are rejected with structured errors', () async {
    final environment = build();

    expect((await render(environment, 'not a list')).error?.code, 'bad_payload');
    expect((await render(environment, [])).error?.code, 'bad_payload');
    expect((await render(environment, ['not a map'])).error?.code, 'bad_payload');

    Future<String?> message(Object? messages) async => (await render(environment, messages)).error?.message;

    expect(
      await message([
        {'createSurface': <String, Object?>{}},
      ]),
      contains('version'),
    );
    expect(
      await message([
        {'version': 'v0.9', 'createSurface': <String, Object?>{}, 'deleteSurface': <String, Object?>{}},
      ]),
      contains('exactly one'),
    );
    expect(
      await message([
        {'version': 'v0.9'},
      ]),
      contains('exactly one'),
    );
    expect(
      await message([
        {
          'version': 'v0.9',
          'createSurface': {'surfaceId': '', 'catalogId': 'x'},
        },
      ]),
      contains('surfaceId'),
    );
    expect(
      await message([
        {
          'version': 'v0.9',
          'createSurface': {'surfaceId': 'main', 'catalogId': 'made up'},
        },
      ]),
      contains('catalogId'),
    );
    // An update to a surface nobody created renders nothing and says nothing.
    expect(await message([update()]), contains('no createSurface'));
  });

  test('a batch with no root is rejected: it would display nothing', () async {
    final environment = build();
    final result = await render(environment, [
      create(),
      update(
        components: const [
          {'id': 'body', 'component': 'Text', 'text': 'unreachable'},
        ],
      ),
    ]);
    expect(result.error?.code, 'invalid_surface');
    expect(result.error?.message, contains('"root"'));
  });

  test('a component type the renderer lacks is an error, not a blank box', () async {
    final environment = build();
    final result = await render(environment, [
      create(),
      update(
        components: const [
          {'id': 'root', 'component': 'DataTable', 'rows': <Object?>[]},
        ],
      ),
    ]);
    expect(result.error?.code, 'invalid_surface');
    expect(result.error?.message, contains('DataTable'));
    // The message lists what it *could* have used; an agent that cannot see
    // the alternatives can only guess again.
    expect(result.error?.message, contains('Text'));
  });

  test('a rejected batch leaves no half-created surface behind', () async {
    final environment = build();
    // createSurface succeeds, updateComponents does not.
    await render(environment, [
      create(),
      update(
        components: const [
          {'id': 'root', 'component': 'Nope'},
        ],
      ),
    ]);

    final result = await render(environment, [update()]);
    expect(result.error?.message, contains('no createSurface'));
  });

  test('the host catalog is what gets enforced', () async {
    final environment = FlutterEnvironment(environmentId: 'test');
    GenUiBridge(
      dataContextProvider: () async => const {},
      catalog: const GenUiCatalog(
        components: {
          'Text': {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
            },
            'required': ['text'],
          },
        },
        catalogId: 'app://sysco/catalog',
        rules: 'Deep links go through a Button.',
      ),
    ).install(environment);

    final catalog = await environment.handle(const Envelope(key: 'genui.catalog', kind: .observe));
    expect(catalog.payload['rules'], contains('Deep links'));

    final result = await render(environment, [
      {
        'version': 'v0.9',
        'createSurface': {'surfaceId': 'main', 'catalogId': 'app://sysco/catalog'},
      },
      update(
        components: const [
          {
            'id': 'root',
            'component': 'Column',
            'children': ['t'],
          },
        ],
      ),
    ]);
    expect(result.error?.message, contains('Column'));
  });

  test('a component missing a required property is refused', () async {
    // The failure the first live Sonnet run produced: a document that is
    // structurally perfect A2UI and renders as an error box, because Card
    // takes one `child` and it was handed `children`. Without this check the
    // rubric would read a surface the app never drew.
    final environment = FlutterEnvironment(environmentId: 'test');
    GenUiBridge(
      dataContextProvider: () async => const {},
      catalog: const GenUiCatalog(
        components: {
          // Shaped the way an A2UI catalog states it: `component` is the
          // discriminator and is part of the item's own schema.
          'Card': {
            'type': 'object',
            'properties': {
              'component': {
                'type': 'string',
                'enum': ['Card'],
              },
              'child': {'type': 'string'},
            },
            'required': ['component', 'child'],
          },
        },
      ),
    ).install(environment);

    final result = await render(environment, [
      create(),
      update(
        components: const [
          {
            'id': 'root',
            'component': 'Card',
            'children': ['col'],
          },
        ],
      ),
    ]);
    expect(result.error?.code, 'invalid_surface');
    expect(result.error?.message, contains('child'));
    expect(result.error?.message, contains('required but missing'));
  });

  test('descriptor publishes the genui keys (discovery)', () async {
    final descriptor = await build().describe();
    expect(descriptor.envelopes.map((e) => e.key), containsAll(['data.context', 'genui.catalog', 'genui.render']));
  });
}
