import 'package:aib_core/aib_core.dart';

import '../agents/decisions.dart';

/// What a decision model in the loop decided (`decisions:` block): the
/// completion check before `done`, the guard before an act, the preparer's
/// relevance selection.
///
/// Read from `extra.decisions`. Null throughout for an agent whose config has
/// no `decisions:` block, so an arm that never checks reads as "not measured"
/// rather than zero checks. Spend is a side call, priced by the core as
/// `side_call_cost_usd` and `side_call_latency_ms`.
///
/// Switched on with `aib evaluate --metrics decisions`.
final decisionMetrics = MetricProvider(
  name: 'decisions',
  description: 'Completion checks, action guards and relevance selection by a decision model',
  metrics: [
    MetricDefinition(
      name: 'completion_check_count',
      unit: 'count',
      description: 'Completion checks asked before a done was let out',
      compute: (ctx) => _configured(ctx, 'completionCheck') ? _records(ctx, 'completion').length : null,
    ),
    MetricDefinition(
      name: 'completion_rejections',
      unit: 'count',
      description: 'done calls the completion check sent back',
      compute: (ctx) => _configured(ctx, 'completionCheck') ? _records(ctx, 'completion').where((r) => r['verdict'] == 'reject').length : null,
    ),
    MetricDefinition(
      name: 'completion_rejected',
      unit: 'bool',
      rateName: 'completion_rejection_rate',
      description: 'The completion check sent back at least one done in the episode (-> completion_rejection_rate)',
      compute: (ctx) {
        if (!_configured(ctx, 'completionCheck')) return null;
        return _records(ctx, 'completion').any((r) => r['verdict'] == 'reject') ? 1 : 0;
      },
    ),
    MetricDefinition(
      name: 'guard_review_count',
      unit: 'count',
      description: 'Actions the guard reviewed',
      compute: (ctx) => _configured(ctx, 'guard') ? _records(ctx, 'guard').length : null,
    ),
    MetricDefinition(
      name: 'guard_denials',
      unit: 'count',
      description: 'Actions the guard judged unwanted or unsafe (acted on in enforce mode, recorded in shadow mode)',
      compute: (ctx) => _configured(ctx, 'guard') ? _records(ctx, 'guard').where((r) => r['verdict'] == 'deny').length : null,
    ),
    MetricDefinition(
      name: 'guard_confirmations',
      unit: 'count',
      description: 'Actions the guard was unsure about (between its two thresholds)',
      compute: (ctx) => _configured(ctx, 'guard') ? _records(ctx, 'guard').where((r) => r['verdict'] == 'confirm').length : null,
    ),
    MetricDefinition(
      name: 'decision_errors',
      unit: 'count',
      description: 'Decisions the decision model failed to answer (the loop fell back to its configured default)',
      compute: (ctx) => _hasBlock(ctx) ? _records(ctx, null).where((r) => r['verdict'] == 'error').length : null,
    ),
    MetricDefinition(
      name: 'decision_latency_ms',
      unit: 'ms',
      description: 'Time spent waiting for the decision model in the episode, every purpose',
      compute: (ctx) => _hasBlock(ctx) ? _records(ctx, null).fold<num>(0, (sum, r) => sum + ((r['latencyMs'] as num?) ?? 0)) : null,
    ),
  ],
);

/// Every decision record of [purpose] (all when null), in episode order.
List<JsonMap> _records(MetricContext ctx, String? purpose) => [
  for (final decision in ctx.decisions)
    for (final raw in asJsonMap(decision['extra'])[DecisionRecord.key] as List? ?? const [])
      if (purpose == null || asJsonMap(raw)['purpose'] == purpose) asJsonMap(raw),
];

JsonMap _block(MetricContext ctx) {
  final agent = asJsonMap(ctx.trace.firstOfType(TraceEventTypes.episodeStart)?.data['agent']);
  return asJsonMap(asJsonMap(asJsonMap(asJsonMap(agent['metadata'])['configBlocks'])['decisions'])['config']);
}

bool _hasBlock(MetricContext ctx) => _block(ctx).isNotEmpty;

bool _configured(MetricContext ctx, String feature) => _block(ctx)[feature] != null;
