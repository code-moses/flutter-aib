import 'dart:async';
import 'package:aib_core/aib_core.dart';
import 'package:aib_flutter/aib_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _settleSerialisation();
  test('unknown keys are answered with structured unsupported', () async {
    final environment = FlutterEnvironment(environmentId: 'test');
    final result = await environment.handle(const Envelope(key: 'vision.capture', kind: .observe));
    expect(result.status, EnvelopeStatus.unsupported);
    expect(result.error?.code, 'unsupported_key');
  });

  test('handler exceptions become failed results, not crashes', () async {
    final environment = FlutterEnvironment(environmentId: 'test');
    environment.registerHandler(const EnvelopeSpec(key: 'boom', kind: .act), (_) async => throw StateError('bug in handler'));
    final result = await environment.handle(const Envelope(key: 'boom', kind: .act));
    expect(result.status, EnvelopeStatus.failed);
    expect(result.error?.code, 'handler_error');
  });

  test('descriptor publishes registered envelope specs (discovery)', () async {
    final environment = FlutterEnvironment(environmentId: 'test');
    IntentBridge().install(environment);
    final descriptor = await environment.describe();
    expect(descriptor.environmentId, 'test');
    expect(descriptor.envelopes.map((e) => e.key), containsAll(['intents.catalog', 'intents.invoke']));
  });

  test('instructions are read on every describe, and blank ones are none', () async {
    var text = '  Mostly service orders.  ';
    final environment = FlutterEnvironment(environmentId: 'test', instructions: () async => text);

    final first = await environment.describe();
    expect(first.instructions, 'Mostly service orders.');
    expect(first.instructionsHash, hasLength(16));
    expect(EnvironmentDescriptor.fromJson(first.toJson()).instructions, first.instructions);

    text = '   ';
    expect((await environment.describe()).instructions, isNull);
    expect((await FlutterEnvironment(environmentId: 'test').describe()).toJson(), isNot(contains('instructions')));
  });

  test('settle is called after act envelopes only', () async {
    var settleCount = 0;
    final environment = FlutterEnvironment(environmentId: 'test', settle: () async => settleCount++);
    environment.registerHandler(const EnvelopeSpec(key: 'observe.x', kind: .observe), (_) async => EnvelopeResult.ok());
    environment.registerHandler(const EnvelopeSpec(key: 'act.x', kind: .act), (_) async => EnvelopeResult.ok());

    await environment.handle(const Envelope(key: 'observe.x', kind: .observe));
    expect(settleCount, 0);
    await environment.handle(const Envelope(key: 'act.x', kind: .act));
    expect(settleCount, 1);
  });

  test('fingerprint callback enables StateFingerprintProvider', () async {
    final plain = FlutterEnvironment(environmentId: 'plain');
    expect(plain, isNot(isA<StateFingerprintProvider>()));

    final fingerprinting = FlutterEnvironment(environmentId: 'fp', fingerprint: () async => 'abc');
    expect(fingerprinting, isA<StateFingerprintProvider>());
    expect(await (fingerprinting as StateFingerprintProvider).stateFingerprint(), 'abc');
  });

  group('IntentBridge', () {
    test('catalog lists intents; invoke routes to the handler', () async {
      final environment = FlutterEnvironment(environmentId: 'test');
      final calls = <JsonMap>[];
      final bridge = IntentBridge()
        ..register(
          AibIntent(
            name: 'todo.create',
            description: 'Creates a todo.',
            paramsSchema: const {
              'type': 'object',
              'properties': {
                'title': {'type': 'string'},
              },
            },
            handler: (params) async {
              calls.add(params);
              return {'id': 'todo-1'};
            },
          ),
        );
      bridge.install(environment);

      final catalog = await environment.handle(const Envelope(key: 'intents.catalog', kind: .observe));
      expect((catalog.payload['intents'] as List).single, containsPair('name', 'todo.create'));

      final invoke = await environment.handle(
        const Envelope(
          key: 'intents.invoke',
          kind: .act,
          payload: {
            'intent': 'todo.create',
            'params': {'title': 'X'},
          },
        ),
      );
      expect(invoke.status, EnvelopeStatus.ok);
      expect(asJsonMap(invoke.payload['result'])['id'], 'todo-1');
      expect(calls.single['title'], 'X');
    });

    test('unknown intent and domain rejection are structured errors', () async {
      final environment = FlutterEnvironment(environmentId: 'test');
      IntentBridge()
        ..register(
          AibIntent(name: 'todo.delete', description: 'Deletes a todo.', handler: (params) async => throw const IntentRejected('todo not found')),
        )
        ..install(environment);

      final unknown = await environment.handle(const Envelope(key: 'intents.invoke', kind: .act, payload: {'intent': 'nope'}));
      expect(unknown.error?.code, 'unknown_intent');

      final rejected = await environment.handle(const Envelope(key: 'intents.invoke', kind: .act, payload: {'intent': 'todo.delete'}));
      expect(rejected.error?.code, 'intent_rejected');
      expect(rejected.error?.message, contains('todo not found'));
    });
  });
}

void _settleSerialisation() {
  group('settles never overlap', () {
    test('a second settle queues behind an abandoned one', () async {
      var running = 0;
      var maxConcurrent = 0;
      final gate = Completer<void>();

      final environment = FlutterEnvironment(
        environmentId: 'test',
        settle: () async {
          running++;
          maxConcurrent = maxConcurrent > running ? maxConcurrent : running;
          if (!gate.isCompleted) await gate.future;
          running--;
        },
        onReset: (_) async {},
      )..registerHandler(const EnvelopeSpec(key: 'a.act', kind: .act), (_) async => EnvelopeResult.ok(const {}));

      // The engine abandons this one; its settle keeps running.
      final abandoned = environment.handle(const Envelope(key: 'a.act', kind: .act));
      await Future<void>.delayed(Duration.zero);

      final queued = environment.reset(const FixtureRef(id: 'f', data: {}));
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await Future.wait<void>([abandoned.then((_) {}), queued]);

      // Two overlapping pumpAndSettle calls are a permanent TestAsyncUtils
      // fault, not a slow episode.
      expect(maxConcurrent, 1);
    });

    test('a settle that throws does not fail the next one', () async {
      var calls = 0;
      final environment = FlutterEnvironment(
        environmentId: 'test',
        settle: () async {
          calls++;
          if (calls == 1) throw StateError('pumpAndSettle timed out');
        },
        onReset: (_) async {},
      );

      await expectLater(environment.reset(const FixtureRef(id: 'f', data: {})), throwsStateError);
      await environment.reset(const FixtureRef(id: 'f', data: {}));
      expect(calls, 2);
    });
  });
}
