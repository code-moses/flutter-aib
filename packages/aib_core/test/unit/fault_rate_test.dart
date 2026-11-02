import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:test/test.dart';

const _fixture = FixtureRef(
  id: 'f',
  data: {
    'db': {'todos': <Object>[]},
  },
);
const _keys = ['state.list', 'state.get', 'state.noop'];

/// Whether each call of each episode met an injected failure.
Future<List<bool>> _faults(int seed, {required int episodes, required int calls, bool distinct = true}) async {
  final environment = PerturbedEnvironment.wrap(MockEnvironment(), [FaultPerturbation(FaultSchedule(seed: seed, failureRate: 0.1))]);
  final faults = <bool>[];
  for (var episode = 0; episode < episodes; episode++) {
    await environment.reset(_fixture);
    for (var i = 0; i < calls; i++) {
      final result = await environment.handle(
        Envelope(key: _keys[i % _keys.length], kind: .observe, payload: {'call': distinct ? episode * calls + i : i}),
      );
      faults.add(result.error?.details?['injected'] == true);
    }
  }
  return faults;
}

void main() {
  test('different calls meet about the rate the schedule names', () async {
    for (final seed in [1, 2, 3]) {
      final faults = await _faults(seed, episodes: 60, calls: 10);
      expect(faults.where((f) => f).length / faults.length, inInclusiveRange(0.07, 0.13), reason: 'seed $seed');
    }
  });

  test('a repeated trajectory meets the same faults', () async {
    final faults = await _faults(1, episodes: 2, calls: 50, distinct: false);
    expect(faults.sublist(50), faults.sublist(0, 50));
    expect(faults, contains(true));
  });
}
