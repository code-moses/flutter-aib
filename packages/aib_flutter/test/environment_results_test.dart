import 'dart:typed_data';

import 'package:aib_core/ports.dart';
import 'package:aib_flutter/aib_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

AibIntent _intent(
  String name, {
  EnvelopeKind kind = .act,
  JsonMap schema = const {},
  JsonMap metadata = const {},
  Future<Object?> Function(JsonMap)? handler,
}) => AibIntent(name: name, description: 'd', kind: kind, paramsSchema: schema, metadata: metadata, handler: handler ?? (params) async => 'ok');

void main() {
  group('result capping', () {
    test('an oversized result is cut down and marked', () async {
      final environment = FlutterEnvironment(environmentId: 'test', maxResultBytes: 400);
      IntentBridge()
        ..register(_intent('data.list', handler: (_) async => null))
        ..install(environment);

      environment.registerHandler(
        const EnvelopeSpec(key: 'data.list', kind: .observe),
        (envelope) async => EnvelopeResult.ok({
          'entries': List.generate(400, (i) => {'id': i, 'name': 'Row $i'}),
        }),
      );

      final result = await environment.handle(const Envelope(key: 'data.list', kind: .observe));
      expect(result.payload['truncated'], isTrue);
      expect(result.payload['totalCount'], 400);
      expect(jsonSizeBytes(result.payload), lessThanOrEqualTo(400));
    });

    test('a screenshot survives the cap', () async {
      final environment = FlutterEnvironment(environmentId: 'test', maxResultBytes: 400);
      VisionBridge(
        capture: () async => CapturedScreen(pngBytes: Uint8List.fromList(List.filled(4000, 7)), width: 100, height: 200),
        tapAt: (double x, double y) async {},
      ).install(environment);

      final result = await environment.handle(const Envelope(key: 'screen.capture', kind: .observe));
      // The cap has no list to shorten here, so without the exemption the
      // whole payload becomes a description of itself and the agent goes
      // blind — which is exactly what happened to every ARTEMIS run.
      expect(result.payload['truncated'], isNull);
      expect(result.payload['image'], isNotEmpty);
      expect(result.payload['width'], 100);
    });

    test('without a cap nothing is touched', () async {
      final environment = FlutterEnvironment(environmentId: 'test');
      environment.registerHandler(
        const EnvelopeSpec(key: 'data.list', kind: .observe),
        (envelope) async => EnvelopeResult.ok({'entries': List.generate(400, (i) => i)}),
      );
      final result = await environment.handle(const Envelope(key: 'data.list', kind: .observe));
      expect(result.payload.containsKey('truncated'), isFalse);
    });
  });

  group('fixture loading', () {
    test('a path fixture without a loader says exactly what is missing', () async {
      final environment = FlutterEnvironment(environmentId: 'test', onReset: (_) async {});
      await expectLater(
        environment.reset(const FixtureRef(id: 'demo', path: 'fixtures/a.json')),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('fixtureLoader'))),
      );
    });

    test('the host resolves the path', () async {
      JsonMap? seen;
      final environment = FlutterEnvironment(
        environmentId: 'test',
        onReset: (data) async => seen = data,
        fixtureLoader: (path) async => {'loadedFrom': path},
      );
      await environment.reset(const FixtureRef(id: 'demo', path: 'fixtures/a.json'));
      expect(seen!['loadedFrom'], 'fixtures/a.json');
    });
  });
}
