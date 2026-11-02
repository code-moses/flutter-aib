import 'dart:convert';

import '../common/json.dart';
import '../ports/envelope.dart';
import '../ports/environment.dart';

/// Event vocabulary of the episode trace. Everything the engine observes on
/// the mediated channel lands here (P4: measurement on the wire, P6:
/// evaluation is a separate pass over these events).
abstract final class TraceEventTypes {
  static const episodeStart = 'episode.start';
  static const envReset = 'env.reset';
  static const envDescriptor = 'env.descriptor';

  /// Agent -> engine envelope. Data: seq, key, kind, payloadBytes, payload,
  /// decision (self-reported telemetry).
  static const agentEnvelope = 'agent.envelope';

  /// Engine -> agent result of the corresponding envelope. Data: seq, status,
  /// payloadBytes, payload, handleMs, error, and — when the same envelope had
  /// already produced this exact result — repeatIndex and suppressed. The
  /// payload recorded is always what the environment returned, even when the
  /// agent was handed the shorter `no_progress` notice instead.
  static const envResult = 'env.result';

  /// State fingerprint after reset (seq = -1) or after handling envelope seq.
  static const stateFingerprint = 'state.fingerprint';

  /// Milestone probe after reset (seq = -1) or after handling envelope seq —
  /// only emitted for tasks declaring `groundTruth.milestones`. Data: seq,
  /// results (StateQueryResult list), probeMs, error.
  static const stateProbe = 'state.probe';

  /// Emitted once when the no-progress guard ends an episode. Data: seq, key,
  /// repeats, suppressedRepeats.
  static const noProgress = 'engine.no_progress';

  static const finalState = 'final.state';

  /// `mustNotChange` queries, answered right after the reset.
  static const stateBaseline = 'state.baseline';

  /// A follow-up the user gave after the agent said it was done.
  static const userTurn = 'user.turn';

  /// The user spoke mid-episode (`steering:`). Data: seq, id, message,
  /// afterActions, delivered.
  static const userSteer = 'user.steer';

  /// What the simulated user said and whether it stayed in role. Data: seq plus
  /// the simulator's record (role, text, valid, issues).
  static const userSimulated = 'user.simulated';

  /// What the user did about a shipped assistant's turn (L3). Data: kind
  /// (`undo`, `edit`, `reask`, `stop`, `abandon`) plus details.
  static const userFeedback = 'user.feedback';

  /// What a ResourceSampler reported after reset (seq = -1) or after handling
  /// envelope seq (J1). Data: seq plus the sampler's numbers.
  static const resourceSample = 'resource.sample';

  /// A field observer hit its event cap. Data: dropped.
  static const traceTruncated = 'trace.truncated';
  static const episodeEnd = 'episode.end';
  static const engineError = 'engine.error';
}

/// The `runId` of a trace a shipped assistant recorded, rather than a run.
const fieldRunId = 'field';

final class TraceEvent {
  const TraceEvent({required this.seq, required this.tUs, required this.type, required this.data});

  /// Global event sequence number within the episode.
  final int seq;

  /// Microseconds since episode start (monotonic clock).
  final int tUs;

  final String type;
  final JsonMap data;

  JsonMap toJson() => {'seq': seq, 'tUs': tUs, 'type': type, 'data': data};

  factory TraceEvent.fromJson(JsonMap json) =>
      TraceEvent(seq: (json['seq'] as num).toInt(), tUs: (json['tUs'] as num).toInt(), type: json['type'] as String, data: asJsonMap(json['data']));
}

final class EpisodeMeta {
  const EpisodeMeta({
    required this.runId,
    required this.episodeId,
    required this.taskId,
    required this.agentId,
    required this.environmentId,
    required this.repetition,
    required this.startedAt,
  });

  final String runId;
  final String episodeId;
  final String taskId;
  final String agentId;
  final String environmentId;
  final int repetition;
  final DateTime startedAt;

  JsonMap toJson() => {
    'runId': runId,
    'episodeId': episodeId,
    'taskId': taskId,
    'agentId': agentId,
    'environmentId': environmentId,
    'repetition': repetition,
    'startedAt': startedAt.toIso8601String(),
  };

  factory EpisodeMeta.fromJson(JsonMap json) => EpisodeMeta(
    runId: json['runId'] as String,
    episodeId: json['episodeId'] as String,
    taskId: json['taskId'] as String,
    agentId: json['agentId'] as String,
    environmentId: json['environmentId'] as String? ?? 'unknown',
    repetition: (json['repetition'] as num?)?.toInt() ?? 0,
    startedAt: DateTime.parse(json['startedAt'] as String),
  );
}

/// One exchange = envelope event + its result event (+ fingerprints).
final class Exchange {
  const Exchange({required this.envelope, this.result, this.fingerprintBefore, this.fingerprintAfter});

  final TraceEvent envelope;
  final TraceEvent? result;
  final String? fingerprintBefore;
  final String? fingerprintAfter;

  String get key => envelope.data['key'] as String;
  String get kind => envelope.data['kind'] as String? ?? 'act';
  bool get isMeta => key.startsWith(Envelope.metaPrefix);
  String? get status => result?.data['status'] as String?;

  bool get hasStateChange => fingerprintBefore != null && fingerprintAfter != null && fingerprintBefore != fingerprintAfter;
}

/// One milestone probe: the state as seen right after exchange [seq]
/// (`seq == -1` = directly after `reset`, i.e. the initial state).
final class StateProbe {
  const StateProbe({required this.seq, required this.results, this.error});

  final int seq;
  final List<StateQueryResult> results;

  /// Set when the environment could not answer the probe at all; the episode
  /// continues regardless (probing is instrumentation, not agent behaviour).
  final String? error;

  StateQueryResult? resultFor(String query) => results.resultFor(query);
}

final class EpisodeTrace {
  const EpisodeTrace({required this.meta, required this.events});

  final EpisodeMeta meta;
  final List<TraceEvent> events;

  Iterable<TraceEvent> byType(String type) => events.where((e) => e.type == type);

  /// Termination reason recorded by the engine, `null` if the episode never
  /// reached `episode.end` (crash, kill, partially written file).
  String? get endReason => firstOfType(TraceEventTypes.episodeEnd)?.data['reason'] as String?;

  /// A trace is complete when the engine got to write `episode.end`.
  bool get isComplete => endReason != null;

  /// Milestone probes in exchange order — the essential-state timeline the
  /// `stateSequence` oracle walks (empty unless the task declares milestones).
  List<StateProbe> probes() => [
    for (final event in byType(TraceEventTypes.stateProbe))
      StateProbe(
        seq: (event.data['seq'] as num?)?.toInt() ?? -1,
        results: (event.data['results'] as List? ?? const []).map((e) => StateQueryResult.fromJson(asJsonMap(e))).toList(),
        error: event.data['error'] as String?,
      ),
  ];

  TraceEvent? firstOfType(String type) {
    for (final event in events) {
      if (event.type == type) return event;
    }
    return null;
  }

  /// Pairs envelope/result events by their exchange `seq` and attaches the
  /// closest state fingerprints before/after. Basis of the metric layer.
  List<Exchange> exchanges() {
    final resultsBySeq = <int, TraceEvent>{};
    final fingerprints = <(int, String)>[]; // (exchangeSeq, fingerprint)
    for (final event in events) {
      final exchangeSeq = (event.data['seq'] as num?)?.toInt();
      if (event.type == TraceEventTypes.envResult && exchangeSeq != null) {
        resultsBySeq[exchangeSeq] = event;
      } else if (event.type == TraceEventTypes.stateFingerprint && exchangeSeq != null && event.data['fingerprint'] is String) {
        fingerprints.add((exchangeSeq, event.data['fingerprint'] as String));
      }
    }
    String? fingerprintAt(int beforeSeq) {
      String? latest;
      for (final (seq, fp) in fingerprints) {
        if (seq <= beforeSeq) latest = fp;
      }
      return latest;
    }

    final result = <Exchange>[];
    for (final event in byType(TraceEventTypes.agentEnvelope)) {
      final exchangeSeq = (event.data['seq'] as num).toInt();
      result.add(
        Exchange(
          envelope: event,
          result: resultsBySeq[exchangeSeq],
          fingerprintBefore: fingerprintAt(exchangeSeq - 1),
          fingerprintAfter: fingerprintAt(exchangeSeq),
        ),
      );
    }
    return result;
  }
}

/// JSONL persistence: first line is the episode meta record, then one event
/// per line (spec §9: `traces/*.jsonl`).
final class TraceCodec {
  static String encode(EpisodeTrace trace) {
    final buffer = StringBuffer()..writeln(jsonEncode({'type': 'episode.meta', 'data': trace.meta.toJson()}));
    for (final event in trace.events) {
      buffer.writeln(jsonEncode(event.toJson()));
    }
    return buffer.toString();
  }

  static EpisodeTrace decode(String jsonl) {
    final lines = const LineSplitter().convert(jsonl).where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) {
      throw const FormatException('Empty trace file');
    }
    final head = asJsonMap(jsonDecode(lines.first));
    if (head['type'] != 'episode.meta') {
      throw const FormatException('Trace must start with an episode.meta line');
    }
    return EpisodeTrace(
      meta: EpisodeMeta.fromJson(asJsonMap(head['data'])),
      events: lines.skip(1).map((l) => TraceEvent.fromJson(asJsonMap(jsonDecode(l)))).toList(),
    );
  }
}
