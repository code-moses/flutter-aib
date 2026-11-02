import 'package:aib_agents/aib_agents.dart';
import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

void main() {
  group('CatalogShufflePerturbation', () {
    Future<List<Object?>> names(BenchmarkEnvironment env, String key) async {
      final payload = (await env.handle(Envelope(key: key, kind: .observe))).payload;
      final entries = key == IntentConventions.catalogKey ? payload['intents'] as List : asJsonMap(payload['capabilities'])['added'] as List;
      return [for (final entry in entries) (entry as Map)['name']];
    }

    final listed = [for (var i = 0; i < 20; i++) 'intent.$i'];

    test('reorders the listing the same way every time', () async {
      final env = PerturbedEnvironment.wrap(_Catalog(listed), [CatalogShufflePerturbation(42)]);
      final first = await names(env, IntentConventions.catalogKey);
      expect(await names(env, IntentConventions.catalogKey), first);
      expect(first, unorderedEquals(listed));
      expect(first, isNot(listed));
    });

    test('reorders what a capability delta adds, too', () async {
      final env = PerturbedEnvironment.wrap(_Catalog(listed), [CatalogShufflePerturbation(42)]);
      final added = await names(env, 'form.open');
      expect(added, unorderedEquals(listed));
      expect(added, isNot(listed));
    });

    test('records its seed', () async {
      final env = PerturbedEnvironment.wrap(_Catalog(listed), [CatalogShufflePerturbation(3)]);
      final record = asJsonMap((await env.describe()).metadata['perturbation']);
      expect(record['catalogShuffleSeed'], 3);
    });
  });
}

final class _Catalog implements BenchmarkEnvironment {
  _Catalog(this.names);

  final List<String> names;

  @override
  Future<EnvironmentDescriptor> describe() async => const EnvironmentDescriptor(environmentId: 'catalog');

  @override
  Future<void> reset(FixtureRef fixture) async {}

  @override
  Future<EnvelopeResult> handle(Envelope envelope) async {
    final entries = [
      for (final name in names) {'name': name},
    ];
    return EnvelopeResult.ok(
      envelope.key == IntentConventions.catalogKey
          ? {'intents': entries}
          : {
              'capabilities': {'added': entries},
            },
    );
  }

  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) async => const FinalStateSnapshot(results: []);
}
