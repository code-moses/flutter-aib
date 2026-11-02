import 'dart:convert';
import 'dart:typed_data';

import 'package:aib_core/ports.dart';

import 'flutter_environment.dart';

/// Screen/pointer envelope vocabulary — adapter convention (spec §4.4):
///
///   observe `screen.capture`  {} -> {image, format, width, height, scale}
///   act     `pointer.tap`     {x, y}
///   act     `pointer.drag`    {fromX, fromY, toX, toY}
///   act     `pointer.text`    {text}   (types into the focused field)
///
/// Coordinates are **logical pixels of the captured image's coordinate space**,
/// i.e. what the agent sees at `scale = 1`. The bridge does not interpret them;
/// the host callbacks do.
final class VisionBridge {
  VisionBridge({required this.capture, required this.tapAt, this.dragFrom, this.enterText});

  /// Host-provided screenshot. Under `flutter_test` this is a
  /// `RenderRepaintBoundary.toImage()` round trip, on a device it can be the
  /// platform screenshot API — the bridge only transports the bytes.
  final Future<CapturedScreen> Function() capture;

  /// Host-provided pointer tap in logical pixels.
  final Future<void> Function(double x, double y) tapAt;

  /// Optional drag/scroll gesture.
  final Future<void> Function(double fromX, double fromY, double toX, double toY)? dragFrom;

  /// Optional text entry into the currently focused field.
  final Future<void> Function(String text)? enterText;

  void install(FlutterEnvironment environment) {
    environment.registerHandler(
      const EnvelopeSpec(
        key: 'screen.capture',
        kind: .observe,
        description:
            'Screenshot of the current screen (base64 PNG) with its size in '
            'logical pixels.',
      ),
      (envelope) async {
        final screen = await capture();
        return EnvelopeResult.ok({
          'image': base64Encode(screen.pngBytes),
          'format': 'png;base64',
          'width': screen.width,
          'height': screen.height,
          'scale': screen.devicePixelRatio,
        });
      },
      // A PNG is one string, not a list: the cap would hand the agent a
      // description of the screenshot instead of the screenshot.
      cappable: false,
    );

    environment.registerHandler(
      const EnvelopeSpec(
        key: 'pointer.tap',
        kind: .act,
        description: 'Tap at a position in logical pixels.',
        payloadSchema: {
          'type': 'object',
          'properties': {
            'x': {'type': 'number'},
            'y': {'type': 'number'},
          },
          'required': ['x', 'y'],
        },
      ),
      (envelope) async {
        final x = _number(envelope.payload['x']);
        final y = _number(envelope.payload['y']);
        if (x == null || y == null) {
          return EnvelopeResult.failed('bad_payload', '"x" and "y" required');
        }
        await tapAt(x, y);
        return EnvelopeResult.ok({'tapped': true, 'x': x, 'y': y});
      },
    );

    final drag = dragFrom;
    if (drag != null) {
      environment.registerHandler(
        const EnvelopeSpec(
          key: 'pointer.drag',
          kind: .act,
          description: 'Drag from one position to another (logical pixels).',
          payloadSchema: {
            'type': 'object',
            'properties': {
              'fromX': {'type': 'number'},
              'fromY': {'type': 'number'},
              'toX': {'type': 'number'},
              'toY': {'type': 'number'},
            },
            'required': ['fromX', 'fromY', 'toX', 'toY'],
          },
        ),
        (envelope) async {
          final from = (_number(envelope.payload['fromX']), _number(envelope.payload['fromY']));
          final to = (_number(envelope.payload['toX']), _number(envelope.payload['toY']));
          if (from.$1 == null || from.$2 == null || to.$1 == null || to.$2 == null) {
            return EnvelopeResult.failed('bad_payload', '"fromX", "fromY", "toX", "toY" required');
          }
          await drag(from.$1!, from.$2!, to.$1!, to.$2!);
          return EnvelopeResult.ok({'dragged': true});
        },
      );
    }

    final type = enterText;
    if (type != null) {
      environment.registerHandler(
        const EnvelopeSpec(
          key: 'pointer.text',
          kind: .act,
          description: 'Type text into the currently focused field.',
          payloadSchema: {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
            },
            'required': ['text'],
          },
        ),
        (envelope) async {
          final text = envelope.payload['text'];
          if (text is! String) {
            return EnvelopeResult.failed('bad_payload', '"text" required');
          }
          await type(text);
          return EnvelopeResult.ok({'typed': true});
        },
      );
    }
  }

  static double? _number(Object? value) => value is num ? value.toDouble() : null;
}

/// One screenshot: PNG bytes plus the geometry an agent needs to translate
/// what it sees into tap coordinates.
final class CapturedScreen {
  const CapturedScreen({required this.pngBytes, required this.width, required this.height, this.devicePixelRatio = 1.0});

  final Uint8List pngBytes;

  /// Size in logical pixels — the coordinate space of `pointer.*`.
  final double width;
  final double height;
  final double devicePixelRatio;
}
