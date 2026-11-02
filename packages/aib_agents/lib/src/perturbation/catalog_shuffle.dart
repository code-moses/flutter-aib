import 'dart:math' as math;

import 'package:aib_core/aib_core.dart';

import '../conventions.dart';

/// Reorders the intent catalogue with a fixed seed: the `intents.catalog`
/// listing, and the entries a capability delta adds. An agent that reads
/// should not care; one that learned positions will.
///
/// Apply with `PerturbedEnvironment.wrap(environment, [
/// CatalogShufflePerturbation(seed)])`.
final class CatalogShufflePerturbation extends Perturbation {
  CatalogShufflePerturbation(this.seed);

  final int seed;

  @override
  JsonMap get record => {'catalogShuffleSeed': seed};

  @override
  Future<EnvelopeResult> after(Envelope envelope, EnvelopeResult result) async {
    if (result.status != .ok) return result;
    final payload = {...result.payload};
    var changed = false;
    if (envelope.key == IntentConventions.catalogKey && payload['intents'] is List) {
      payload['intents'] = _shuffled(payload['intents'] as List);
      changed = true;
    }
    final delta = asJsonMap(payload[IntentConventions.capabilitiesKey]);
    if (delta['added'] is List) {
      payload[IntentConventions.capabilitiesKey] = {...delta, 'added': _shuffled(delta['added'] as List)};
      changed = true;
    }
    if (!changed) return result;
    return EnvelopeResult(status: result.status, payload: payload, error: result.error, userWaitMs: result.userWaitMs);
  }

  List<Object?> _shuffled(List<Object?> entries) => List.of(entries)..shuffle(math.Random(seed));
}
