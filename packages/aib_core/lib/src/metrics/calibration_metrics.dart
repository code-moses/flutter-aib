import '../aggregation/aggregator.dart';
import '../common/json.dart';
import '../trace/trace.dart';
import 'metrics.dart';

/// Key an agent puts on its terminal envelope to state how sure it is.
const confidenceKey = 'confidence';

/// The confidence an episode stated when it finished, or null.
///
/// Read from the `meta.done` / `meta.abort` payload, so an agent opts in by
/// writing one number and the framework needs no agent change.
num? statedConfidence(EpisodeTrace trace) {
  for (final event in trace.events.reversed) {
    if (event.type != TraceEventTypes.agentEnvelope) continue;
    final key = event.data['key'];
    if (key != 'meta.done' && key != 'meta.abort') continue;
    final value = asJsonMap(event.data['payload'])[confidenceKey];
    if (value is num && value >= 0 && value <= 1) return value;
    return null;
  }
  return null;
}

/// Whether the episode was right, for scoring a stated confidence against.
bool _wasRight(EpisodeRecord record) => record.verdict.type == .success;

/// Is the agent's certainty worth anything? An agent that says 0.9 and is right
/// nine times in ten can be trusted to act.
///
/// Every metric here is null until an agent states a confidence; no reference
/// agent does.
final calibrationMetrics = MetricProvider(
  name: 'calibration',
  description: 'Stated confidence against being right: Brier, ECE, resolution',
  metrics: [
    MetricDefinition(
      name: 'stated_confidence',
      unit: 'ratio',
      description:
          'What the agent said its chance of being right was, on meta.done or '
          'meta.abort. Null for an agent that states none',
      compute: (ctx) => statedConfidence(ctx.trace),
    ),
  ],
  aggregates: [
    AggregateMetricDefinition(
      name: 'brier_score',
      unit: 'score',
      description:
          'Mean squared error of the stated confidence against the outcome, '
          'over episodes that stated one. 0 is perfect, 0.25 is answering 0.5 '
          'every time, 1 is confidently wrong throughout — lower is better, '
          'unlike every other score here',
      compute: (group) {
        final pairs = _pairs(group);
        if (pairs.isEmpty) return null;
        var sum = 0.0;
        for (final (confidence, right) in pairs) {
          final error = confidence - (right ? 1 : 0);
          sum += error * error;
        }
        return sum / pairs.length;
      },
    ),
    AggregateMetricDefinition(
      name: 'calibration_error',
      unit: 'ratio',
      description:
          'Expected calibration error over 5 equal-width bins: how far the '
          'stated confidence sits from the share actually right, weighted by '
          'how many episodes fall in each bin',
      compute: (group) {
        final pairs = _pairs(group);
        if (pairs.isEmpty) return null;
        const bins = 5;
        var error = 0.0;
        for (var bin = 0; bin < bins; bin++) {
          final low = bin / bins;
          final high = (bin + 1) / bins;
          final inBin = [
            for (final pair in pairs)
              if (pair.$1 >= low && (pair.$1 < high || (bin == bins - 1 && pair.$1 <= high))) pair,
          ];
          if (inBin.isEmpty) continue;
          final meanConfidence = inBin.map((p) => p.$1).reduce((a, b) => a + b) / inBin.length;
          final shareRight = inBin.where((p) => p.$2).length / inBin.length;
          error += inBin.length / pairs.length * (meanConfidence - shareRight).abs();
        }
        return error;
      },
    ),
    AggregateMetricDefinition(
      name: 'confidence_separation',
      unit: 'ratio',
      description:
          'Mean stated confidence when right minus when wrong. Positive means '
          'the number carries information, near zero means it carries none '
          'however well calibrated it looks; null unless both outcomes occur',
      compute: (group) {
        final pairs = _pairs(group);
        final right = [
          for (final p in pairs)
            if (p.$2) p.$1,
        ];
        final wrong = [
          for (final p in pairs)
            if (!p.$2) p.$1,
        ];
        if (right.isEmpty || wrong.isEmpty) return null;
        return right.reduce((a, b) => a + b) / right.length - wrong.reduce((a, b) => a + b) / wrong.length;
      },
    ),
  ],
);

List<(double, bool)> _pairs(List<EpisodeRecord> group) => [
  for (final record in group)
    if (record.metrics['stated_confidence'] case final num confidence) (confidence.toDouble(), _wasRight(record)),
];
