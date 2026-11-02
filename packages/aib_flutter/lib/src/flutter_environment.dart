import 'package:aib_core/ports.dart';

import 'frame_attribution.dart';

typedef EnvelopeHandler = Future<EnvelopeResult> Function(Envelope envelope);
typedef FixtureResetHandler = Future<void> Function(JsonMap fixtureData);
typedef StateQueryHandler = Future<StateQueryResult> Function(StateQuery query);

/// Resolves a [FixtureRef.path] to fixture data. Injected by the host
/// because file access is a platform decision, not an environment one: a
/// `flutter_test` harness reads it with `dart:io`, an on-device harness from
/// bundled assets, and a web build has no file system at all. Keeping it out
/// of this package is what makes `aib_flutter` `dart:io`-free.
typedef FixtureLoader = Future<JsonMap> Function(String path);

/// Answers "does handling this envelope change the app?" for envelopes whose
/// effect is not fixed by their key. `intents.invoke` is the case that
/// matters: one key, many capabilities, some read-only. Returning null means
/// "no opinion" — the registered [EnvelopeSpec.kind] decides.
typedef EnvelopeKindResolver = EnvelopeKind? Function(Envelope envelope);

/// Lets a bridge annotate a result after its handler has run and the frames
/// have settled.
///
/// For an app whose *capability surface* moves: opening a page mounts intents,
/// and no result of the envelope that caused it would mention them, so the
/// environment says so unprompted (ADR 0013).
///
/// Runs for every envelope: the mount an act triggered may not have settled
/// until the observation that follows it.
typedef EnvelopeResultDecorator = Future<EnvelopeResult> Function(Envelope envelope, EnvelopeResult result);

/// In-process implementation of the Environment port for Flutter apps
/// (spec §3.2, ADR 0004). Host-agnostic: envelope handlers are registered by
/// bridges (SemanticsBridge, IntentBridge) and by the app itself
/// (reset/state-query hooks) — the environment only routes and settles
/// frames.
///
/// The published envelope keys are *conventions of the installed bridges*
/// (documented in this package's README), not core contracts: unknown keys
/// are answered with a structured `unsupported` (spec §4.2).
base class FlutterEnvironment implements BenchmarkEnvironment, ResourceSampler {
  /// [fingerprint] enables the state-diff metrics (`redundant_action_ratio`,
  /// `kind_integrity_violations`); with it the returned environment also
  /// implements [StateFingerprintProvider] (ADR 0002).
  factory FlutterEnvironment({
    required String environmentId,
    String version = '0.1.0',
    Future<void> Function()? settle,
    FixtureResetHandler? onReset,
    StateQueryHandler? onStateQuery,
    Future<String> Function()? fingerprint,
    FixtureLoader? fixtureLoader,
    int? maxResultBytes,
    JsonMap metadata = const {},
    Future<String?> Function()? instructions,
    FrameAttribution? frames,
  }) => fingerprint == null
      ? FlutterEnvironment._(
          environmentId: environmentId,
          version: version,
          settle: settle,
          onReset: onReset,
          onStateQuery: onStateQuery,
          fixtureLoader: fixtureLoader,
          maxResultBytes: maxResultBytes,
          metadata: metadata,
          instructions: instructions,
          frames: frames,
        )
      : _FingerprintingFlutterEnvironment(
          environmentId: environmentId,
          version: version,
          settle: settle,
          onReset: onReset,
          onStateQuery: onStateQuery,
          fingerprint: fingerprint,
          fixtureLoader: fixtureLoader,
          maxResultBytes: maxResultBytes,
          metadata: metadata,
          instructions: instructions,
          frames: frames,
        );

  FlutterEnvironment._({
    required this.environmentId,
    required this.version,
    this.settle,
    this.onReset,
    this.onStateQuery,
    this.fixtureLoader,
    this.maxResultBytes,
    this.metadata = const {},
    this.instructions,
    this.frames,
  }) {
    frames?.start();
  }

  final String environmentId;
  final String version;

  /// Frame settling after mutations — under `flutter_test` typically
  /// `tester.pumpAndSettle`, in a live app an `endOfFrame` loop.
  final Future<void> Function()? settle;

  /// The settle in flight, so a second caller queues behind it.
  ///
  /// `Future.timeout` does not cancel what it times out: an abandoned
  /// `handle`'s `pumpAndSettle` keeps running, and a second one makes
  /// `TestAsyncUtils` reject every later call as a "Guarded function conflict".
  Future<void>? _settling;

  /// Settles, never concurrently. A failed settle does not fail the next one:
  /// the error belongs to the call that asked for it.
  Future<void> settleNow() {
    final settleFn = settle;
    if (settleFn == null) return Future.value();
    final queued = (_settling ?? Future<void>.value()).then((_) => settleFn());
    _settling = queued.catchError((Object _) {});
    return queued;
  }

  /// Restores the fixture state deterministically (app hook).
  final FixtureResetHandler? onReset;

  /// Answers ground-truth queries (app hook; see `SimpleQuery` in aib_core for the
  /// reference query convention).
  final StateQueryHandler? onStateQuery;

  /// Resolves [FixtureRef.path]; required only for fixtures that carry a
  /// path instead of inline `data`.
  final FixtureLoader? fixtureLoader;

  /// Ceiling on a single result payload. Null means no cap. Capped results are
  /// marked `truncated` and counted.
  final int? maxResultBytes;

  final JsonMap metadata;

  /// The app's own frame costs, sampled after each exchange; null samples
  /// nothing ([FrameAttribution]).
  final FrameAttribution? frames;

  @override
  Future<JsonMap> sampleResources() async => frames?.take() ?? const {};

  /// [EnvironmentDescriptor.instructions], read on every [describe]: an
  /// instance's configuration can change between two episodes.
  final Future<String?> Function()? instructions;

  final Map<String, EnvelopeHandler> _handlers = {};
  final List<EnvelopeSpec> _specs = [];
  final Set<String> _uncappedKeys = {};
  final List<EnvelopeKindResolver> _kindResolvers = [];
  final List<EnvelopeResultDecorator> _resultDecorators = [];

  /// Bridges and apps register their envelope vocabulary here; [spec] is
  /// published via [describe] (runtime discovery, spec §4.2).
  ///
  /// [cappable] false exempts the result from [maxResultBytes]. The cap
  /// shortens the largest top-level list; a payload without one is replaced by
  /// a description of itself, so a screenshot reaches the agent as nothing at
  /// all. Only the registrant knows its payload cannot be summarised.
  void registerHandler(EnvelopeSpec spec, EnvelopeHandler handler, {bool cappable = true}) {
    _handlers[spec.key] = handler;
    _specs.removeWhere((s) => s.key == spec.key);
    _specs.add(spec);
    if (cappable) {
      _uncappedKeys.remove(spec.key);
    } else {
      _uncappedKeys.add(spec.key);
    }
  }

  /// Lets a bridge refine the kind of an envelope it owns (see
  /// [EnvelopeKindResolver]). Consulted in registration order; the first
  /// non-null answer wins.
  void registerKindResolver(EnvelopeKindResolver resolver) {
    _kindResolvers.add(resolver);
  }

  /// Lets a bridge annotate every result this environment produces (see
  /// [EnvelopeResultDecorator]). Applied in registration order.
  void registerResultDecorator(EnvelopeResultDecorator decorator) {
    _resultDecorators.add(decorator);
  }

  /// The kind this environment ascribes to [envelope], the authority for frame
  /// settling.
  ///
  /// `envelope.kind`, the agent's own declaration, is not consulted: an agent
  /// could mutate the app while claiming to observe it, and the next
  /// observation would read a half-rendered frame. The engine cross-checks
  /// declarations (`kind_integrity_violations`).
  EnvelopeKind resolvedKind(Envelope envelope) {
    for (final resolver in _kindResolvers) {
      final kind = resolver(envelope);
      if (kind != null) return kind;
    }
    for (final spec in _specs) {
      if (spec.key == envelope.key && spec.kind != null) return spec.kind!;
    }
    // Unknown key: assume it acts. Settling an observation costs a frame;
    // not settling an action costs a wrong measurement.
    return .act;
  }

  @override
  Future<EnvironmentDescriptor> describe() async => EnvironmentDescriptor(
    environmentId: environmentId,
    version: version,
    envelopes: List.unmodifiable(_specs),
    metadata: metadata,
    instructions: _blankToNull(await instructions?.call()),
  );

  static String? _blankToNull(String? text) => text == null || text.trim().isEmpty ? null : text.trim();

  @override
  Future<void> reset(FixtureRef fixture) async {
    final resetHandler = onReset;
    if (resetHandler == null) {
      throw StateError('FlutterEnvironment "$environmentId" has no onReset handler');
    }
    var data = fixture.data;
    final path = fixture.path;
    if (data == null && path != null) {
      final loader = fixtureLoader;
      if (loader == null) {
        throw StateError(
          'Fixture "${fixture.id}" resolves to path "$path", but '
          'FlutterEnvironment "$environmentId" has no fixtureLoader. '
          'Pass one, or inline the data in the fixture.',
        );
      }
      data = await loader(path);
    }
    await resetHandler(data ?? const {});
    await settleNow();
  }

  @override
  Future<EnvelopeResult> handle(Envelope envelope) async {
    final handler = _handlers[envelope.key];
    if (handler == null) {
      return EnvelopeResult.unsupported(envelope.key);
    }
    try {
      final result = await handler(envelope);
      if (resolvedKind(envelope) == .act) {
        await settleNow();
      }
      // Decorated *after* capping, so that what a decorator adds cannot be
      // truncated away by a payload that was already too large. A decorator
      // therefore owes the same restraint the cap enforces: say what changed,
      // not everything that is now true.
      var decorated = _capped(envelope, result);
      for (final decorator in _resultDecorators) {
        decorated = await decorator(envelope, decorated);
      }
      return decorated;
    } catch (e) {
      return EnvelopeResult.failed('handler_error', e.toString());
    }
  }

  EnvelopeResult _capped(Envelope envelope, EnvelopeResult result) {
    final max = maxResultBytes;
    if (max == null || result.status != .ok || _uncappedKeys.contains(envelope.key)) {
      return result;
    }
    final capped = capPayload(result.payload, maxBytes: max);
    if (!capped.truncated) return result;
    return EnvelopeResult(status: result.status, payload: capped.payload, error: result.error, userWaitMs: result.userWaitMs);
  }

  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) async {
    final queryHandler = onStateQuery;
    final results = <StateQueryResult>[];
    for (final query in queries) {
      if (queryHandler == null) {
        results.add(StateQueryResult(query: query.query, count: 0, error: 'environment has no state query handler'));
        continue;
      }
      try {
        results.add(await queryHandler(query));
      } catch (e) {
        results.add(StateQueryResult(query: query.query, count: 0, error: e.toString()));
      }
    }
    return FinalStateSnapshot(results: results);
  }
}

final class _FingerprintingFlutterEnvironment extends FlutterEnvironment implements StateFingerprintProvider {
  _FingerprintingFlutterEnvironment({
    required super.environmentId,
    required super.version,
    super.settle,
    super.onReset,
    super.onStateQuery,
    required this._fingerprint,
    super.fixtureLoader,
    super.maxResultBytes,
    super.metadata,
    super.instructions,
    super.frames,
  }) : super._();

  final Future<String> Function() _fingerprint;

  @override
  Future<String> stateFingerprint() => _fingerprint();

  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) async {
    final snapshot = await super.captureFinalState(queries);
    return FinalStateSnapshot(results: snapshot.results, fingerprint: await _fingerprint());
  }
}
