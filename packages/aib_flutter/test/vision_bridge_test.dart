import 'dart:convert';
import 'dart:typed_data';

import 'package:aib_core/aib_core.dart';
import 'package:aib_flutter/aib_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ({FlutterEnvironment environment, List<String> log}) build({
    Future<void> Function(String)? enterText,
    Future<void> Function(double, double, double, double)? dragFrom,
  }) {
    final log = <String>[];
    final environment = FlutterEnvironment(environmentId: 'test');
    VisionBridge(
      capture: () async => CapturedScreen(pngBytes: Uint8List.fromList([137, 80, 78, 71]), width: 400, height: 800, devicePixelRatio: 2),
      tapAt: (x, y) async => log.add('tap($x,$y)'),
      dragFrom: dragFrom,
      enterText: enterText,
    ).install(environment);
    return (environment: environment, log: log);
  }

  test('screen.capture returns base64 PNG plus the tap coordinate space', () async {
    final result = await build().environment.handle(const Envelope(key: 'screen.capture', kind: .observe));
    expect(result.status, EnvelopeStatus.ok);
    expect(base64Decode(result.payload['image'] as String).take(4), [137, 80, 78, 71]);
    expect(result.payload['format'], 'png;base64');
    expect(result.payload['width'], 400);
    expect(result.payload['scale'], 2);
  });

  test('pointer.tap forwards logical pixels to the host', () async {
    final built = build();
    final result = await built.environment.handle(const Envelope(key: 'pointer.tap', kind: .act, payload: {'x': 120, 'y': 240.5}));
    expect(result.status, EnvelopeStatus.ok);
    expect(built.log.single, 'tap(120.0,240.5)');
  });

  test('missing coordinates are a structured failure, not a crash', () async {
    final result = await build().environment.handle(const Envelope(key: 'pointer.tap', kind: .act, payload: {'x': 120}));
    expect(result.status, EnvelopeStatus.failed);
    expect(result.error!.code, 'bad_payload');
  });

  test('optional gestures are only published when the host supports them', () async {
    final without = await build().environment.describe();
    expect(without.envelopes.map((e) => e.key), containsAll(['screen.capture', 'pointer.tap']));
    expect(without.envelopes.map((e) => e.key), isNot(contains('pointer.drag')));
    // Agents asking for an unsupported capability get `unsupported` (§4.2).
    expect((await build().environment.handle(const Envelope(key: 'pointer.text', kind: .act))).status, EnvelopeStatus.unsupported);

    final typed = <String>[];
    final with_ = build(enterText: (text) async => typed.add(text), dragFrom: (a, b, c, d) async {});
    expect((await with_.environment.describe()).envelopes.map((e) => e.key), containsAll(['pointer.drag', 'pointer.text']));
    await with_.environment.handle(const Envelope(key: 'pointer.text', kind: .act, payload: {'text': 'Milch kaufen'}));
    expect(typed.single, 'Milch kaufen');
  });

  testWidgets('a real widget tree can be captured through the bridge', (tester) async {
    // The screenshot path a widget-test host uses: one RepaintBoundary
    // around the app, toImage() inside runAsync (PNG encoding is genuinely
    // asynchronous).
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: const MaterialApp(
          home: Scaffold(body: Center(child: Text('Milch kaufen'))),
        ),
      ),
    );

    final environment = FlutterEnvironment(environmentId: 'test');
    VisionBridge(
      capture: () async {
        final boundary = boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: .png);
        return CapturedScreen(pngBytes: data!.buffer.asUint8List(), width: boundary.size.width, height: boundary.size.height);
      },
      tapAt: (x, y) async => tester.tapAt(Offset(x, y)),
    ).install(environment);

    final result = await tester.runAsync(() => environment.handle(const Envelope(key: 'screen.capture', kind: .observe)));
    expect(result!.status, EnvelopeStatus.ok);
    final png = base64Decode(result.payload['image'] as String);
    expect(png.take(4), [137, 80, 78, 71], reason: 'PNG magic number');
    expect(result.payload['width'], 800);
  });
}
