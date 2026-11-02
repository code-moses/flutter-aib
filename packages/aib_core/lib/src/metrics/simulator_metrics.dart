import '../trace/trace.dart';
import 'metrics.dart';

/// The simulated user: how much it said, and whether it stayed a user.
final userSimulatorMetrics = <MetricDefinition>[
  MetricDefinition(
    name: 'simulated_follow_up_count',
    unit: 'count',
    description:
        'Messages the simulated user added after meta.done. Null without a '
        'simulated user',
    compute: (ctx) => ctx.trace.events.any(_isSimulated)
        ? ctx.trace.events.where((e) => e.type == TraceEventTypes.userTurn && e.data['simulated'] == true).length
        : null,
  ),
  MetricDefinition(
    name: 'simulation_valid',
    unit: 'bool',
    description:
        'Every simulated reply stayed in role: not empty, not the assistant '
        'speaking, no ground truth the user cannot know, an answer of the type '
        'asked. A 0 marks a conversation to regenerate rather than score. Null '
        'without a simulated user',
    compute: (ctx) {
      final records = ctx.trace.events.where(_isSimulated).toList();
      if (records.isEmpty) return null;
      return records.every((e) => e.data['valid'] == true) ? 1 : 0;
    },
  ),
];

bool _isSimulated(TraceEvent event) => event.type == TraceEventTypes.userSimulated;
