import '../common/json.dart';
import '../common/simple_query.dart';
import '../ports/envelope.dart';
import '../ports/environment.dart';

/// Deterministic in-memory environment for framework validation (spec §10).
///
/// It simulates an app as a JSON document (seeded from the fixture) and
/// speaks a small generic vocabulary — a *convention of this adapter*, not a
/// core contract:
///
///   observe `state.get`    {path?}                -> {value}
///   observe `state.list`   {path, where?}         -> {count, items}
///   act     `state.insert` {path, item}           -> {inserted: true}
///   act     `state.update` {path, where, set}     -> {updated: n}
///   act     `state.delete` {path, where}          -> {deleted: n}
///   act     `state.noop`   {}                     -> {} (no state change)
///
/// Failure injection via [failKeys]; artificial latency via [handleDelay].
final class MockEnvironment implements BenchmarkEnvironment, StateFingerprintProvider {
  MockEnvironment({
    this.environmentId = 'mock',
    this.version = '1.0.0',
    this.failKeys = const {},
    this.handleDelay = Duration.zero,
    this.instructions,
  });

  final String environmentId;

  /// Settable so a test can play the app changing under a half-finished run.
  final String version;

  /// Published in the descriptor; settable so a test can play an instance
  /// whose configuration changed.
  String? instructions;

  /// key -> error message; those keys answer with `failed`.
  final Map<String, String> failKeys;
  final Duration handleDelay;

  JsonMap _state = {};
  int resetCount = 0;

  @override
  Future<EnvironmentDescriptor> describe() async => EnvironmentDescriptor(
    environmentId: environmentId,
    version: version,
    envelopes: const [
      EnvelopeSpec(key: 'state.get', kind: .observe, description: 'Full state document or sub-path'),
      EnvelopeSpec(key: 'state.list', kind: .observe, description: 'Rows at path, optional where(...) filter'),
      EnvelopeSpec(key: 'state.insert', kind: .act),
      EnvelopeSpec(key: 'state.update', kind: .act),
      EnvelopeSpec(key: 'state.delete', kind: .act),
      EnvelopeSpec(key: 'state.noop', kind: .act),
    ],
    instructions: instructions,
  );

  @override
  Future<void> reset(FixtureRef fixture) async {
    _state = asJsonMap(deepCopyJson(fixture.data ?? const {}));
    resetCount++;
  }

  @override
  Future<EnvelopeResult> handle(Envelope envelope) async {
    if (handleDelay > Duration.zero) {
      await Future<void>.delayed(handleDelay);
    }
    final failure = failKeys[envelope.key];
    if (failure != null) {
      return EnvelopeResult.failed('injected_failure', failure);
    }
    final payload = envelope.payload;
    switch (envelope.key) {
      case 'state.get':
        final path = payload['path'] as String?;
        final value = path == null ? _state : SimpleQuery.parse(path).run(_state).items;
        return EnvelopeResult.ok({'value': deepCopyJson(value)});
      case 'state.list':
        final query = _query(payload);
        final result = SimpleQuery.parse(query).run(_state);
        return EnvelopeResult.ok({'count': result.count, 'items': deepCopyJson(result.items)});
      case 'state.insert':
        final rows = _rowsAt(payload['path'] as String?);
        if (rows == null) {
          return EnvelopeResult.failed('bad_path', 'no list at path');
        }
        rows.add(deepCopyJson(payload['item']));
        return EnvelopeResult.ok({'inserted': true});
      case 'state.update':
        final rows = _rowsAt(payload['path'] as String?);
        if (rows == null) {
          return EnvelopeResult.failed('bad_path', 'no list at path');
        }
        final matches = _match(rows, payload['where']);
        final updates = asJsonMap(payload['set']);
        for (final row in matches) {
          (row as Map).addAll(updates);
        }
        return EnvelopeResult.ok({'updated': matches.length});
      case 'state.delete':
        final rows = _rowsAt(payload['path'] as String?);
        if (rows == null) {
          return EnvelopeResult.failed('bad_path', 'no list at path');
        }
        final matches = _match(rows, payload['where']);
        rows.removeWhere(matches.contains);
        return EnvelopeResult.ok({'deleted': matches.length});
      case 'state.noop':
        return EnvelopeResult.ok();
      default:
        return EnvelopeResult.unsupported(envelope.key);
    }
  }

  @override
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries) async {
    final results = <StateQueryResult>[];
    for (final query in queries) {
      try {
        final result = SimpleQuery.parse(query.query).run(_state);
        results.add(StateQueryResult(query: query.query, count: result.count, items: result.items.map((i) => asJsonMap(deepCopyJson(i))).toList()));
      } catch (e) {
        results.add(StateQueryResult(query: query.query, count: 0, error: e.toString()));
      }
    }
    return FinalStateSnapshot(results: results, fingerprint: await stateFingerprint());
  }

  @override
  Future<String> stateFingerprint() async => jsonFingerprint(_state);

  static String _query(JsonMap payload) {
    final path = payload['path'] as String? ?? '';
    final where = payload['where'] as String?;
    return where == null ? path : '$path.where($where)';
  }

  List<Object?>? _rowsAt(String? path) {
    if (path == null) return null;
    Object? current = _state;
    for (final segment in path.split('.')) {
      if (current is Map) {
        current = current[segment];
      } else {
        return null;
      }
    }
    return current is List ? current : null;
  }

  static List<Object?> _match(List<Object?> rows, Object? where) {
    if (where == null) return List.of(rows);
    if (where is String) {
      return [
        for (final row in rows)
          if (row is Map &&
              SimpleQuery.parse('x.where($where)').run({
                    'x': [row],
                  }).count ==
                  1)
            row,
      ];
    }
    final criteria = asJsonMap(where);
    return [
      for (final row in rows)
        if (row is Map && criteria.entries.every((e) => jsonEquals(row[e.key], e.value))) row,
    ];
  }
}
