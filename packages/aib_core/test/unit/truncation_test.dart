import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

void main() {
  group('payload capping', () {
    test('leaves a payload that already fits alone', () {
      final payload = {'items': List.generate(3, (i) => 'item$i')};
      final capped = capPayload(payload, maxBytes: 10000);
      expect(capped.truncated, isFalse);
      expect(capped.payload, same(payload));
    });

    test('shortens the largest list and says how much it dropped', () {
      final payload = {
        'endpointId': 12,
        'items': List.generate(500, (i) => {'id': i, 'name': 'Article $i'}),
      };
      final capped = capPayload(payload, maxBytes: 500);
      expect(capped.truncated, isTrue);
      expect(capped.payload['truncated'], isTrue);
      expect(capped.payload['totalCount'], 500);
      expect(jsonSizeBytes(capped.payload), lessThanOrEqualTo(500));
      // The context the model needs to ask a narrower question survives.
      expect(capped.payload['endpointId'], 12);
    });

    test('a payload with nothing to shorten is described, not mangled', () {
      final capped = capPayload({'blob': 'x' * 5000}, maxBytes: 100);
      expect(capped.truncated, isTrue);
      expect(capped.payload['truncated'], isTrue);
      expect(capped.payload['keys'], ['blob']);
    });
  });
}
