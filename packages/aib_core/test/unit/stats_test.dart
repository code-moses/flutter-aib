import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

void main() {
  test('mean, median, p95 with interpolation', () {
    expect(Stats.mean([1, 2, 3, 4]), 2.5);
    expect(Stats.median([1, 2, 3]), 2);
    expect(Stats.median([1, 2, 3, 4]), 2.5);
    expect(Stats.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 95), closeTo(9.55, 1e-9));
    expect(Stats.median([]), isNaN);
  });

  test('stdDev (sample)', () {
    expect(Stats.stdDev([2, 4, 4, 4, 5, 5, 7, 9]), closeTo(2.138, 0.001));
    expect(Stats.stdDev([5]), 0);
  });

  test('Wilson 95% CI matches reference values', () {
    // Reference: p̂=0.8, n=5 -> [0.376, 0.964] (Wilson, z=1.96).
    final ci = Stats.wilson(4, 5);
    expect(ci.low, closeTo(0.376, 0.005));
    expect(ci.high, closeTo(0.964, 0.005));

    final zero = Stats.wilson(0, 5);
    expect(zero.low, 0);
    expect(zero.high, greaterThan(0), reason: 'CI stays informative at 0/5');

    final degenerate = Stats.wilson(0, 0);
    expect(degenerate.low, 0);
    expect(degenerate.high, 1);
  });
}
