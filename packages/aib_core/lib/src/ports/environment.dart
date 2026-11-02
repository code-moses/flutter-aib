import '../common/json.dart';
import 'envelope.dart';

/// Reference to the deterministic seed state of an episode (spec P3/§5.3).
/// The suite loader inlines the fixture file contents into [data] so that
/// environments never need file-system access of their own.
final class FixtureRef {
  const FixtureRef({required this.id, this.path, this.data});

  final String id;
  final String? path;
  final JsonMap? data;

  JsonMap toJson() => {'id': id, if (path != null) 'path': path, if (data != null) 'data': data};

  factory FixtureRef.fromJson(JsonMap json) =>
      FixtureRef(id: json['id'] as String, path: json['path'] as String?, data: json['data'] == null ? null : asJsonMap(json['data']));
}

/// A ground-truth query, interpreted by the environment (adapter convention;
/// the core treats the string as opaque).
final class StateQuery {
  const StateQuery(this.query);

  final String query;

  JsonMap toJson() => {'query': query};

  factory StateQuery.fromJson(JsonMap json) => StateQuery(json['query'] as String);
}

final class StateQueryResult {
  const StateQueryResult({required this.query, required this.count, this.items = const [], this.error});

  final String query;
  final int count;
  final List<JsonMap> items;
  final String? error;

  JsonMap toJson() => {'query': query, 'count': count, 'items': items, if (error != null) 'error': error};

  factory StateQueryResult.fromJson(JsonMap json) => StateQueryResult(
    query: json['query'] as String,
    count: (json['count'] as num?)?.toInt() ?? 0,
    items: (json['items'] as List? ?? const []).map(asJsonMap).toList(),
    error: json['error'] as String?,
  );
}

extension StateQueryResults on List<StateQueryResult> {
  /// The answer to [query], or null when it was not asked.
  StateQueryResult? resultFor(String query) {
    for (final result in this) {
      if (result.query == query) return result;
    }
    return null;
  }
}

/// Snapshot of the final app state for the ground-truth check (spec §4.2).
final class FinalStateSnapshot {
  const FinalStateSnapshot({required this.results, this.fingerprint});

  final List<StateQueryResult> results;
  final String? fingerprint;

  StateQueryResult? resultFor(String query) => results.resultFor(query);

  JsonMap toJson() => {'results': results.map((r) => r.toJson()).toList(), if (fingerprint != null) 'fingerprint': fingerprint};

  factory FinalStateSnapshot.fromJson(JsonMap json) => FinalStateSnapshot(
    results: (json['results'] as List? ?? const []).map((e) => StateQueryResult.fromJson(asJsonMap(e))).toList(),
    fingerprint: json['fingerprint'] as String?,
  );
}

/// One supported envelope key as published by the environment (runtime
/// discovery, analogous to MCP tool listing — spec §4.2). The core does not
/// interpret this document; it is handed to the agent verbatim.
final class EnvelopeSpec {
  const EnvelopeSpec({required this.key, this.kind, this.description, this.payloadSchema, this.blocksOnUser = false});

  final String key;
  final EnvelopeKind? kind; // hint only — the agent still declares its own
  final String? description;
  final JsonMap? payloadSchema;

  /// Handling this key may block on a human answering. The engine gives such
  /// an envelope its own, longer timeout instead of the remaining wall clock
  /// (a person is not a slow function call), and expects the environment to
  /// report the waiting time as [EnvelopeResult.userWaitMs].
  final bool blocksOnUser;

  JsonMap toJson() => {
    'key': key,
    'kind': ?kind?.name,
    if (description != null) 'description': description,
    if (payloadSchema != null) 'payloadSchema': payloadSchema,
    if (blocksOnUser) 'blocksOnUser': true,
  };

  factory EnvelopeSpec.fromJson(JsonMap json) => EnvelopeSpec(
    key: json['key'] as String,
    kind: json['kind'] == null ? null : EnvelopeKind.values.byName(json['kind'] as String),
    description: json['description'] as String?,
    payloadSchema: json['payloadSchema'] == null ? null : asJsonMap(json['payloadSchema']),
    blocksOnUser: json['blocksOnUser'] == true,
  );
}

final class EnvironmentDescriptor {
  const EnvironmentDescriptor({
    required this.environmentId,
    this.version = '0.0.0',
    this.envelopes = const [],
    this.metadata = const {},
    this.instructions,
  });

  final String environmentId;
  final String version;
  final List<EnvelopeSpec> envelopes;
  final JsonMap metadata;

  /// What the app wants every agent told about this instance: its main
  /// workflows, its vocabulary, an administrator's guidance (ADR 0018).
  /// Appended to the agent's frozen prompt, never replacing it. Null is an app
  /// that says nothing.
  final String? instructions;

  /// Short content hash of [instructions]; null when there are none. What a
  /// run manifest records and a release gate compares.
  String? get instructionsHash => instructions == null ? null : jsonFingerprint(instructions).substring(0, 16);

  JsonMap toJson() => {
    'environmentId': environmentId,
    'version': version,
    'envelopes': envelopes.map((e) => e.toJson()).toList(),
    'metadata': metadata,
    if (instructions != null) 'instructions': instructions,
  };

  factory EnvironmentDescriptor.fromJson(JsonMap json) => EnvironmentDescriptor(
    environmentId: json['environmentId'] as String,
    version: json['version'] as String? ?? '0.0.0',
    envelopes: (json['envelopes'] as List? ?? const []).map((e) => EnvelopeSpec.fromJson(asJsonMap(e))).toList(),
    metadata: asJsonMap(json['metadata']),
    instructions: json['instructions'] as String?,
  );
}

/// Environment port (spec §4.2). Implementations live in adapter packages
/// (aib_flutter, MockEnvironment, remote environments via aib_protocol).
abstract interface class BenchmarkEnvironment {
  /// Runtime discovery document; the core passes it through untouched.
  Future<EnvironmentDescriptor> describe();

  /// Deterministic reset to the fixture state.
  Future<void> reset(FixtureRef fixture);

  /// The single generic communication channel.
  Future<EnvelopeResult> handle(Envelope envelope);

  /// Snapshot of the final state for the ground-truth check.
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries);
}

/// Optional capability (ADR 0002): environments that can fingerprint their
/// state enable state-diff based metrics (`kind_integrity_violations`,
/// `redundant_action_ratio`). The engine probes with `is`.
abstract interface class StateFingerprintProvider {
  Future<String> stateFingerprint();
}

/// Optional capability (J1): what the device spends — `rssBytes`,
/// `energyMj` where the OS keeps a counter, anything else numeric. The engine
/// probes with `is` and samples after reset and after every exchange.
abstract interface class ResourceSampler {
  Future<JsonMap> sampleResources();
}
