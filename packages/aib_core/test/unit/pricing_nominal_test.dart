import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

void main() {
  test('a nominal price is still zero, and says why', () {
    final table = PriceTable.fromJson(const {
      'models': {
        'qwen3:8b': {'promptPerMTok': 0.0, 'completionPerMTok': 0.0, 'nominal': true},
        'claude-sonnet-5': {'promptPerMTok': 2.0, 'completionPerMTok': 10.0},
      },
    });
    expect(table.isNominal('qwen3:8b'), isTrue);
    expect(table.isNominal('claude-sonnet-5'), isFalse);
    expect(table.nominalModels, {'qwen3:8b'});
    // It is a note about billing, not a different number.
    expect(table['qwen3:8b']!.cost(promptTokens: 1000000, completionTokens: 1000), 0);
  });

  test('a model the table does not mention is not nominal, it is unpriced', () {
    // Null cost and zero cost are different claims; only one of them is
    // "priced at zero".
    final table = PriceTable.fromJson(const {'models': <String, Object?>{}});
    expect(table.isNominal('qwen3:8b'), isFalse);
    expect(table['qwen3:8b'], isNull);
  });

  test('the flag survives a round trip through the manifest', () {
    const price = ModelPrice(promptPerMTok: 0, completionPerMTok: 0, nominal: true);
    expect(ModelPrice.fromJson(price.toJson()).nominal, isTrue);
    expect(ModelPrice.fromJson(const ModelPrice(promptPerMTok: 1, completionPerMTok: 2).toJson()).nominal, isFalse);
  });
}
