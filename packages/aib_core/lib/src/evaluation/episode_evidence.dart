import 'dart:convert';

import '../common/json.dart';
import '../trace/trace.dart';

/// What an episode actually did, small enough to put in a judge prompt, so a
/// claim can be checked against the record rather than against plausibility.
///
/// Results are kept whole while the digest fits [maxBytes], then trimmed
/// longest first: a fixed per-result cut hides the support for claims the agent
/// made correctly.
///
/// A long episode keeps its opening and its ending rather than its middle,
/// because a summary's claims are about what it found and how it finished. What
/// the user said after the opening instruction is part of the record, in order:
/// a closing statement can answer a follow-up, a simulated turn or a steering
/// message.
JsonMap episodeEvidence(EpisodeTrace trace, {int maxActions = 24, int maxBytes = 16000}) {
  final exchanges = {for (final exchange in trace.exchanges()) exchange.envelope.data['seq']: exchange};
  final actions = <JsonMap>[];
  for (final event in trace.events) {
    if (_userMessage(event) case final said?) {
      actions.add(said);
      continue;
    }
    if (event.type != TraceEventTypes.agentEnvelope) continue;
    final exchange = exchanges[event.data['seq']];
    if (exchange == null || exchange.isMeta) continue;
    final payload = asJsonMap(exchange.envelope.data['payload']);
    actions.add({
      // The whole payload rather than a guess at which field names the
      // operation: the core does not know an environment's envelope shapes
      // (ADR 0002), and the judge can read an intent name inside it.
      'did': exchange.key,
      if (payload.isNotEmpty) 'with': jsonEncode(payload),
      'result': exchange.status ?? 'unknown',
      if (exchange.result?.data['payload'] case final result?) 'returned': jsonEncode(result),
      if (exchange.result?.data['error'] case final error?) 'error': jsonEncode(error),
      if (exchange.hasStateChange) 'changedTheApp': true,
    });
  }

  // User messages are never omitted: they say what the closing statement
  // answers. Only the agent's own actions are cut from the middle.
  final calls = actions.where((a) => !a.containsKey('user')).length;
  final head = maxActions ~/ 3;
  // One slot goes to the marker, so maxActions - 1 real actions are kept.
  final tail = maxActions - head - 1;
  final List<JsonMap> kept;
  if (calls <= maxActions) {
    kept = actions;
  } else {
    kept = [];
    var call = 0;
    var markerPlaced = false;
    for (final action in actions) {
      if (action.containsKey('user')) {
        kept.add(action);
        continue;
      }
      final keep = call < head || call >= calls - tail;
      call++;
      if (keep) {
        kept.add(action);
      } else if (!markerPlaced) {
        markerPlaced = true;
        kept.add({'did': '… ${calls - head - tail} more, omitted'});
      }
    }
  }

  final finalState = trace.firstOfType(TraceEventTypes.finalState);
  final evidence = {
    'actions': kept,
    'endedBecause': trace.endReason ?? 'unknown',
    'anyChangeToTheApp': actions.any((a) => a['changedTheApp'] == true),
    if (finalState?.data['results'] case final results? when results is List && results.isNotEmpty) 'finalState': jsonEncode(results),
  };
  _trimToBudget(kept, evidence, maxBytes);
  return evidence;
}

/// A user message as a record entry, or null when [event] is not one.
///
/// `user.steer` that was not delivered (an agent that cannot hear mid-task)
/// is left out: the agent never got it, so nothing it said answers it.
JsonMap? _userMessage(TraceEvent event) => switch (event.type) {
  TraceEventTypes.userTurn => {
    'user': event.data['instruction'] ?? '',
    'when': 'after the agent said it was done',
    if (event.data['after'] case final String said when said.isNotEmpty) 'agentHadSaid': said,
  },
  TraceEventTypes.userSteer when event.data['delivered'] == true => {'user': event.data['message'] ?? '', 'when': 'while the agent was working'},
  _ => null,
};

/// Shrinks the longest recorded value until the whole digest fits, so what is
/// lost is the bulk of one large listing rather than the tail of every result.
///
/// Every pass must make the chosen value strictly shorter, or the loop never
/// ends. When the largest value can no longer shrink, none can, and the digest
/// stays a little over budget.
void _trimToBudget(List<JsonMap> actions, JsonMap evidence, int maxBytes) {
  const floor = 200;
  const keys = ['returned', 'with', 'error', 'finalState', 'agentHadSaid'];
  // Bounded as well as provably terminating: this runs inside evaluation, and
  // a digest is never worth a hang.
  for (var pass = 0; pass < 1000; pass++) {
    if (jsonEncode(evidence).length <= maxBytes) return;
    JsonMap? worst;
    String? worstKey;
    var worstLength = 0;
    for (final action in [...actions, evidence]) {
      for (final key in keys) {
        final value = action[key];
        if (value is String && value.length > worstLength) {
          worst = action;
          worstKey = key;
          worstLength = value.length;
        }
      }
    }
    if (worst == null || worstKey == null) return;
    final value = worst[worstKey]! as String;
    final keep = value.length * 2 ~/ 3 < floor ? floor : value.length * 2 ~/ 3;
    // +1 for the ellipsis: without this the cut can be a no-op.
    if (keep + 1 >= value.length) return;
    worst[worstKey] = '${value.substring(0, keep)}…';
  }
}
