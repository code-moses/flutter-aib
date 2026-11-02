import '../trace/trace.dart';
import 'metrics.dart';

/// What the user did about a shipped assistant's turn (L3), from
/// `user.feedback` events. 1 or 0 per turn, so a field run's mean is the
/// rate; null outside field traces, where nobody could react.
final userFeedbackMetrics = <MetricDefinition>[
  _feedback('user_correction', 'The user took the turn back', {'undo', 'edit'}),
  _feedback('user_reask', 'The user asked the same thing again', {'reask'}),
  _feedback('user_stopped', 'The user stopped the running turn', {'stop'}),
  _feedback('user_abandoned', 'The user left while the turn ran', {'abandon'}),
];

MetricDefinition _feedback(String name, String what, Set<String> kinds) => MetricDefinition(
  name: name,
  unit: 'bool',
  description:
      '$what. The mean over a field run is the rate. Null outside field '
      'traces',
  compute: (ctx) {
    if (ctx.trace.meta.runId != fieldRunId) return null;
    return ctx.trace.events.any((e) => e.type == TraceEventTypes.userFeedback && kinds.contains(e.data['kind'])) ? 1 : 0;
  },
);
