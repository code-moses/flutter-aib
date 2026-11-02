import '../common/draw.dart';
import '../common/json.dart';
import '../ports/envelope.dart';
import '../ports/environment.dart';

/// One change a run makes to the channel between agent and environment.
///
/// Perturbations name no environment's vocabulary themselves (ADR 0002):
/// what counts as talking to the user is read off the descriptor
/// ([EnvelopeSpec.blocksOnUser]), and a perturbation that needs to know an
/// app's keys lives with the code that knows them.
abstract base class Perturbation {
  /// Merged into `descriptor.metadata['perturbation']`, which comparability
  /// reads.
  JsonMap get record;

  /// The environment's descriptor, each time it is described.
  void onDescribe(EnvironmentDescriptor descriptor) {}

  void onReset() {}

  /// A result instead of handling [envelope], or null to pass it on.
  Future<EnvelopeResult?> before(Envelope envelope) async => null;

  /// Rewrites the result the environment gave.
  Future<EnvelopeResult> after(Envelope envelope, EnvelopeResult result) async => result;
}

/// An environment with [Perturbation]s applied, in order. One wrapper for any
/// number of perturbations, so optional capabilities are forwarded in one
/// place.
base class PerturbedEnvironment implements BenchmarkEnvironment, ResourceSampler {
  PerturbedEnvironment._(this.inner, this.perturbations);

  /// [inner] with [perturbations]; [inner] itself when there are none.
  static BenchmarkEnvironment wrap(BenchmarkEnvironment inner, List<Perturbation> perturbations) {
    if (perturbations.isEmpty) return inner;
    return inner is StateFingerprintProvider
        ? _FingerprintingPerturbedEnvironment(inner, perturbations)
        : PerturbedEnvironment._(inner, perturbations);
  }

  final BenchmarkEnvironment inner;
  final List<Perturbation> perturbations;

  /// Always declared, so wrapping keeps the samples; an empty one is skipped.
  @override
  Future<JsonMap> sampleResources() async => switch (inner) {
    final ResourceSampler sampler => await sampler.sampleResources(),
    _ => const {},
  };

  @override
  Future<EnvironmentDescriptor> describe() async {
    final descriptor = await inner.describe();
    for (final perturbation in perturbations) {
      perturbation.onDescribe(descriptor);
    }
    return EnvironmentDescriptor(
      environmentId: descriptor.environmentId,
      version: descriptor.version,
      envelopes: descriptor.envelopes,
      metadata: {
        ...descriptor.metadata,
        'perturbation': {...asJsonMap(descriptor.metadata['perturbation']), for (final perturbation in perturbations) ...perturbation.record},
      },
      instructions: descriptor.instructions,
    );
  }

  @override
  Future<void> reset(FixtureRef fixture) {
    for (final perturbation in perturbations) {
      perturbation.onReset();
    }
    return inner.reset(fixture);
  }

  @override
  Future<EnvelopeResult> handle(Envelope envelope) async {
    for (final perturbation in perturbations) {
      final replaced = await perturbation.before(envelope);
      if (replaced != null) return replaced;
    }
    var result = await inner.handle(envelope);
    for (final perturbation in perturbations) {
      result = await perturbation.after(envelope, result);
    }
    return result;
  }

  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) => inner.captureFinalState(queries);
}

final class _FingerprintingPerturbedEnvironment extends PerturbedEnvironment implements StateFingerprintProvider {
  _FingerprintingPerturbedEnvironment(super.inner, super.perturbations) : super._();

  @override
  Future<String> stateFingerprint() => (inner as StateFingerprintProvider).stateFingerprint();
}

/// Seeded faults on the channel.
final class FaultSchedule {
  const FaultSchedule({
    required this.seed,
    this.failureRate = 0,
    this.unreachableRate = 0,
    this.latencyRate = 0,
    this.latency = const Duration(seconds: 2),
  });

  final int seed;

  /// A transient `failed` the agent may retry.
  final double failureRate;

  /// The server is gone for this call.
  final double unreachableRate;

  /// The call succeeds after [latency].
  final double latencyRate;
  final Duration latency;

  JsonMap toJson() => {
    'seed': seed,
    'failureRate': failureRate,
    'unreachableRate': unreachableRate,
    'latencyRate': latencyRate,
    'latencyMs': latency.inMilliseconds,
  };
}

/// Injects [schedule]'s faults into app envelopes — never into `meta.*`, and
/// never into envelopes the environment declares as waiting on a person.
///
/// The draw depends on seed, the envelope's index in the episode and the call
/// itself, so a trajectory meets the same faults whatever order episodes run
/// in, and different calls meet different ones.
/// Injected errors carry `details.injected`.
final class FaultPerturbation extends Perturbation {
  FaultPerturbation(this.schedule);

  final FaultSchedule schedule;
  var _index = 0;
  Set<String> _userKeys = const {};

  @override
  JsonMap get record => {'faults': schedule.toJson()};

  @override
  void onDescribe(EnvironmentDescriptor descriptor) {
    _userKeys = {
      for (final spec in descriptor.envelopes)
        if (spec.blocksOnUser) spec.key,
    };
  }

  @override
  void onReset() => _index = 0;

  @override
  Future<EnvelopeResult?> before(Envelope envelope) async {
    if (envelope.isMeta || _userKeys.contains(envelope.key)) return null;
    final draw = stableUnitDraw(
      '${schedule.seed}:${_index++}:${envelope.key}:'
      '${jsonFingerprint(envelope.payload)}',
    );
    var threshold = schedule.unreachableRate;
    if (draw < threshold) {
      return _injected('unreachable', 'Server unreachable');
    }
    threshold += schedule.failureRate;
    if (draw < threshold) {
      return _injected('transient_failure', 'Temporary failure, try again');
    }
    threshold += schedule.latencyRate;
    if (draw < threshold) await Future<void>.delayed(schedule.latency);
    return null;
  }

  static EnvelopeResult _injected(String code, String message) => EnvelopeResult(
    status: .failed,
    error: EnvelopeError(code: code, message: message, details: const {'injected': true}),
  );
}
