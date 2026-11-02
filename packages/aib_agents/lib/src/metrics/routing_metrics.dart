import 'package:aib_core/aib_core.dart';

/// What a model router decided. Read from `extra.modelRoute` on the episode's
/// first decision, which the agent writes when its client is a `ModelRouter`.
/// Null throughout for an unrouted agent. Routing accuracy needs the paired
/// always-local and always-cloud runs, so it is a comparison across arms.
///
/// Switched on with `aib evaluate --metrics routing`.
final routingMetrics = MetricProvider(
  name: 'routing',
  description: 'Local/cloud routing decisions of a routed agent',
  metrics: [
    MetricDefinition(
      name: 'route_local',
      unit: 'bool',
      rateName: 'route_local_share',
      description: 'The episode ran on the local model (-> route_local_share)',
      compute: (ctx) => switch (_route(ctx)?['route']) {
        'local' => 1,
        'cloud' => 0,
        _ => null,
      },
    ),
    MetricDefinition(
      name: 'route_probability_local',
      unit: 'ratio',
      description:
          'The decider\'s p(local), where it has one — lets a threshold '
          'sweep be replayed without re-running',
      compute: (ctx) => _route(ctx)?['probabilityLocal'] as num?,
    ),
    MetricDefinition(
      name: 'route_latency_ms',
      unit: 'ms',
      description: 'Time the decider took before the first step',
      compute: (ctx) => _route(ctx)?['latencyMs'] as num?,
    ),
    MetricDefinition(
      name: 'route_fallback',
      unit: 'bool',
      rateName: 'route_fallback_rate',
      description: 'The decider failed and the configured onError route ran',
      compute: (ctx) {
        final route = _route(ctx);
        if (route == null) return null;
        return route['fallback'] == true ? 1 : 0;
      },
    ),
  ],
  features: [
    // Not a number, so it travels as a feature: `aib route` reads it to
    // label each arm by the decider that produced it.
    FeatureDefinition(name: 'route_decider', compute: (ctx) => _route(ctx)?['decider']),
    // The instruction's language as the router detected it, so `aib route`
    // can split accuracy by language on runs whose tasks carry no `lang:` tag.
    FeatureDefinition(name: RouteReport.languageFeature, compute: (ctx) => _route(ctx)?['language']),
  ],
);

JsonMap? _route(MetricContext ctx) {
  for (final decision in ctx.decisions) {
    final route = asJsonMap(decision['extra'])['modelRoute'];
    if (route != null) return asJsonMap(route);
  }
  return null;
}
