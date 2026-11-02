import 'dart:convert';

import '../common/json.dart';
import '../metrics/metrics.dart';

/// Decides one assertion of a registered kind against an episode.
///
/// Composites call [assertionHolds] for their parts, so a provider's kind
/// nests inside `anyOf` like a built-in one.
typedef AssertionPredicate = bool Function(MetricContext context, JsonMap assertion);

/// Kinds the core evaluates itself. They read keys, kinds, statuses and
/// payload text only — no environment's vocabulary (ADR 0002). Kinds that
/// need one (`everIntent`, `confirmBefore`, …) come from a [MetricProvider].
const builtinAssertionKinds = {'neverKey', 'everKey', 'maxActions', 'noFailedEnvelopes', 'everSeen', 'anyOf', 'allOf'};

/// Whether [kind] can be evaluated in [context]: built in, or registered.
bool isKnownAssertionKind(MetricContext context, Object? kind) => builtinAssertionKinds.contains(kind) || context.assertions.containsKey(kind);

/// Whether one policy-style assertion holds for the episode. An unknown kind
/// never holds; callers that report it check [isKnownAssertionKind] first. The
/// single implementation behind `traceAssertion` criteria, `policies:` and
/// `refusalRequires:`.
bool assertionHolds(MetricContext context, JsonMap assertion) {
  final xs = context.exchanges;
  final kind = assertion['kind'];
  return switch (kind) {
    'neverKey' => xs.every((x) => x.key != assertion['key']),
    'everKey' => xs.any((x) => x.key == assertion['key']),
    'maxActions' => context.actions.length <= ((assertion['value'] as num?) ?? 0),
    'noFailedEnvelopes' => xs.every((x) => x.status != 'failed'),
    // The agent was shown this text in some result.
    'everSeen' => xs.any((x) => jsonEncode(x.result?.data['payload']).contains('${assertion['text']}')),
    // Composites, so a task can accept either of two routes.
    'anyOf' => (assertion['of'] as List? ?? const []).any((inner) => assertionHolds(context, asJsonMap(inner))),
    'allOf' => (assertion['of'] as List? ?? const []).every((inner) => assertionHolds(context, asJsonMap(inner))),
    _ => context.assertions[kind]?.call(context, assertion) ?? false,
  };
}
