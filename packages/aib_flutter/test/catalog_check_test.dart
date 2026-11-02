import 'package:aib_core/aib_core.dart';
import 'package:aib_flutter/aib_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

AibIntent _intent({
  String name = 'form.open',
  String description =
      'Open a form for filling, by assemblyId and maskId. Its ids come from '
      'app.forms and exist nowhere else.',
  EnvelopeKind kind = .observe,
  IntentEffect? effect,
  JsonMap schema = const {'type': 'object', 'properties': {}},
}) => AibIntent(name: name, description: description, kind: kind, paramsSchema: schema, effect: effect, handler: (_) async => null);

void main() {
  group('lintIntents', () {
    test('a healthy set of intents has nothing said about it', () {
      expect(lintIntents([_intent(), _intent(name: 'form.close', description: 'Close the open form and keep its draft on the device.')]), isEmpty);
    });

    test('catches an act intent that declares no effect, before a run does', () {
      final findings = lintIntents([_intent(kind: .act)]);
      expect(findings.map((f) => f.rule), contains('undeclared_effect'));
    });

    test('catches two intents the listing cannot tell apart', () {
      final findings = lintIntents([_intent(name: 'a.one'), _intent(name: 'a.two')]);
      expect(findings.map((f) => f.rule), contains('duplicate_summary'));
    });

    test('a parameterless intent is not scolded for an empty schema', () {
      expect(
        lintIntents([_intent(name: 'nav.back', schema: const {}, description: 'Go back to the page the user came from, if there is one.')]),
        isEmpty,
      );
    });
  });

  test('catalogMetadata counts the listing and what it costs per turn', () {
    final metadata = catalogMetadata([_intent(), _intent(name: 'form.close')]);
    expect(metadata['catalogIntentCount'], '2');
    expect(int.parse(metadata['catalogBytes']! as String), greaterThan(0));
  });
}
