import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

void main() {
  group('price tiers', () {
    test('cached tokens are a subset billed at their own rate', () {
      const price = ModelPrice(promptPerMTok: 10, completionPerMTok: 100, cachedPromptPerMTok: 1);
      // 100k uncached * 10 + 900k cached * 1 = 1.0 + 0.9
      expect(price.cost(promptTokens: 1000000, completionTokens: 0, cachedPromptTokens: 900000), closeTo(1.9, 1e-9));
    });

    test('a table without the tier bills them at the full rate', () {
      // A table without the tiers, so old runs
      // keep costing exactly what they cost.
      const price = ModelPrice(promptPerMTok: 10, completionPerMTok: 100);
      expect(price.cost(promptTokens: 1000000, completionTokens: 0, cachedPromptTokens: 900000), closeTo(10.0, 1e-9));
    });

    test('a provider over-reporting a subset cannot make a run cheap', () {
      const price = ModelPrice(promptPerMTok: 10, completionPerMTok: 100, cachedPromptPerMTok: 0);
      expect(price.cost(promptTokens: 100, completionTokens: 0, cachedPromptTokens: 999999), closeTo(0, 1e-9));
    });

    test('round-trips through json', () {
      const price = ModelPrice(promptPerMTok: 3, completionPerMTok: 15, cachedPromptPerMTok: 0.3);
      final restored = ModelPrice.fromJson(price.toJson());
      expect(restored.cachedPromptPerMTok, 0.3);
      expect(restored.reasoningPerMTok, isNull);
    });
  });
}
