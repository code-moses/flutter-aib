/// Regression tests for the 2026-09-17 code review
/// (the code review in `docs/overview.md`; items R1–R36).
library;

import 'package:aib_core/ports.dart';
import 'package:aib_flutter/aib_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parameters are validated by a JSON Schema implementation', () {
    test(r'$ref, anyOf and type arrays are checked, not ignored', () {
      const schema = {
        r'$defs': {
          'qty': {'type': 'integer', 'minimum': 1},
        },
        'type': 'object',
        'properties': {
          'Menge': {r'$ref': r'#/$defs/qty'},
          'unit': {
            'anyOf': [
              {
                'type': 'string',
                'enum': ['Stück', 'Stunde'],
              },
              {'type': 'null'},
            ],
          },
          'note': {
            'type': ['string', 'null'],
          },
        },
      };
      expect(validateAgainstSchema(const {'Menge': 2, 'unit': null, 'note': null}, schema), isEmpty);
      final violations = validateAgainstSchema(const {'Menge': 0, 'unit': 'Kilo', 'note': 3}, schema);
      expect(violations.join('\n'), contains(r'$.Menge'));
      expect(violations.join('\n'), contains(r'$.unit'));
      expect(violations.join('\n'), contains(r'$.note'));
    });

    test('a missing property is reported once, at the property', () {
      final violations = validateAgainstSchema(
        const {'a': 1},
        const {
          'type': 'object',
          'required': ['child'],
        },
      );
      expect(violations, [r'$.child: required but missing']);
    });

    test('an invalid schema is the app\'s defect and blames no call', () {
      expect(validateAgainstSchema(const {'a': 1}, const {'type': 17}), isEmpty);
    });
  });

  group('an intent result that is not JSON', () {
    test('fails at the intent, not later as a framework fault', () async {
      final environment = FlutterEnvironment(environmentId: 'test');
      IntentBridge(
        catalogProvider: () => [AibIntent(name: 'bad.result', description: 'Returns an object.', handler: (_) async => DateTime(2026))],
      ).install(environment);
      final result = await environment.handle(const Envelope(key: 'intents.invoke', kind: .act, payload: {'intent': 'bad.result'}));
      expect(result.status, EnvelopeStatus.failed);
      expect(result.error?.message, contains('not JSON'));
    });
  });

  group('a scroll reports where the viewport went', () {
    testWidgets('two scrolls that moved answer differently', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(children: [for (var i = 0; i < 200; i++) SizedBox(height: 60, child: Text('Row $i'))]),
          ),
        ),
      );
      final environment = FlutterEnvironment(environmentId: 'scroll', settle: () async => tester.pumpAndSettle());
      SemanticsBridge().install(environment);

      final tree = await environment.handle(const Envelope(key: 'semantics.tree', kind: .observe));
      int? scrollableId(List<Object?> nodes) {
        for (final raw in nodes) {
          final node = raw! as Map;
          if ((node['actions'] as List? ?? const []).contains('scrollUp')) {
            return node['id'] as int;
          }
          final inner = scrollableId(node['children'] as List? ?? const []);
          if (inner != null) return inner;
        }
        return null;
      }

      final id = scrollableId(tree.payload['tree']! as List)!;
      Future<EnvelopeResult> scroll() =>
          environment.handle(Envelope(key: 'semantics.scroll', kind: .act, payload: {'nodeId': id, 'direction': 'up'}));
      final first = await scroll();
      final second = await scroll();
      expect(first.status, EnvelopeStatus.ok);
      expect(first.payload['scrollPosition'], isA<double>());
      expect(second.payload['scrollPosition'], greaterThan(first.payload['scrollPosition']! as double));
      handle.dispose();
    });
  });
}
