import '../common/json.dart';
import '../task/task.dart';
import 'envelope.dart';
import 'environment.dart';

final class AgentManifest {
  const AgentManifest({required this.agentId, this.version = '0.0.0', this.description, this.metadata = const {}});

  final String agentId;
  final String version;
  final String? description;
  final JsonMap metadata;

  JsonMap toJson() => {'agentId': agentId, 'version': version, if (description != null) 'description': description, 'metadata': metadata};

  factory AgentManifest.fromJson(JsonMap json) => AgentManifest(
    agentId: json['agentId'] as String,
    version: json['version'] as String? ?? '0.0.0',
    description: json['description'] as String?,
    metadata: asJsonMap(json['metadata']),
  );
}

/// Budget consumption snapshot passed to the agent on every `next()` call.
final class BudgetStatus {
  const BudgetStatus({
    required this.stepsUsed,
    required this.maxSteps,
    required this.elapsedMs,
    required this.maxWallClockMs,
    required this.tokensUsed,
    this.maxTokens,
    this.turnsUsed = 0,
    this.maxTurns,
  });

  final int stepsUsed;
  final int maxSteps;
  final int elapsedMs;
  final int maxWallClockMs;
  final int tokensUsed;
  final int? maxTokens;

  /// Envelopes the agent has emitted, whether they act or only observe.
  /// [stepsUsed] counts acts only, and [tokensUsed] is dominated by the request
  /// prefix re-sent every turn.
  final int turnsUsed;
  final int? maxTurns;

  int get stepsRemaining => maxSteps - stepsUsed;
  int get wallClockRemainingMs => maxWallClockMs - elapsedMs;

  JsonMap toJson() => {
    'stepsUsed': stepsUsed,
    'maxSteps': maxSteps,
    'elapsedMs': elapsedMs,
    'maxWallClockMs': maxWallClockMs,
    'tokensUsed': tokensUsed,
    if (maxTokens != null) 'maxTokens': maxTokens,
    'turnsUsed': turnsUsed,
    if (maxTurns != null) 'maxTurns': maxTurns,
  };

  factory BudgetStatus.fromJson(JsonMap json) => BudgetStatus(
    stepsUsed: (json['stepsUsed'] as num).toInt(),
    maxSteps: (json['maxSteps'] as num).toInt(),
    elapsedMs: (json['elapsedMs'] as num).toInt(),
    maxWallClockMs: (json['maxWallClockMs'] as num).toInt(),
    tokensUsed: (json['tokensUsed'] as num?)?.toInt() ?? 0,
    maxTokens: (json['maxTokens'] as num?)?.toInt(),
    turnsUsed: (json['turnsUsed'] as num?)?.toInt() ?? 0,
    maxTurns: (json['maxTurns'] as num?)?.toInt(),
  );
}

enum TerminationReason {
  /// Agent signalled `meta.done`.
  done,

  /// Agent signalled `meta.abort`.
  abort,

  /// Step budget (`maxSteps`, counted over act-envelopes) exhausted.
  budgetSteps,

  /// Token budget exhausted (from self-reported telemetry). Read it together
  /// with `tokens_resent`: the budget counts prompt tokens per *request*, so
  /// the request prefix is spent again on every turn.
  budgetTokens,

  /// Turn budget (`maxTurns`, counted over every envelope the agent emits)
  /// exhausted. A token budget is mostly a statement about the app; a turn
  /// budget is one about the agent.
  budgetTurns,

  /// Wall-clock budget exhausted.
  timeout,

  /// The agent kept sending an envelope that kept returning the same answer.
  /// Not a budget: the episode stopped going anywhere rather than running out
  /// of room.
  noProgress,

  /// The user stopped the agent at a turn the task scheduled. Scored on what
  /// the app was left with, not as defeat.
  cancelled,

  /// Framework/environment fault — never attributed to the agent (§5.2).
  frameworkFault,
}

final class EpisodeOutcome {
  const EpisodeOutcome({required this.reason, this.message});

  final TerminationReason reason;
  final String? message;

  JsonMap toJson() => {'reason': reason.name, if (message != null) 'message': message};

  factory EpisodeOutcome.fromJson(JsonMap json) =>
      EpisodeOutcome(reason: TerminationReason.values.byName(json['reason'] as String), message: json['message'] as String?);
}

/// Agent port (spec §4.3). The agent is fully responsible for its own
/// information access: it picks its envelope keys, interprets payloads and
/// decides when to observe and when to act — but every access flows through
/// the engine (mediated exchange, §4.4).
abstract interface class BenchmarkAgent {
  AgentManifest get manifest;

  Future<void> startEpisode(TaskSpec task, EnvironmentDescriptor environment);

  /// Core of the loop: the agent receives the result of its previous
  /// envelope (null on the first call) plus the budget status and emits the
  /// next envelope. Termination via `meta.done`/`meta.abort` or budget.
  Future<Envelope> next(EnvelopeResult? lastResult, BudgetStatus budget);

  Future<void> endEpisode(EpisodeOutcome outcome);
}

/// Optional capability: the agent can pay its one-off startup cost up front.
///
/// Probed with `is` by the runner, which calls it once before the first
/// episode. Otherwise model loading is charged to the first episode's
/// `llm_latency_ms` and wall clock.
abstract interface class AgentWarmUp {
  Future<void> warmUp();
}

/// Optional: the agent can hear the user while it works ([SteeringMessage]).
/// Probed with `is` by the engine; an agent without it is never steered, and
/// the trace says so (`user.steer` with `delivered: false`).
abstract interface class SteerableAgent {
  /// [message] arrived from the user; it belongs in the agent's next decision.
  void steer(String message, {required String id});
}

/// Optional: the model the agent actually resolved to (a digest, a dated id),
/// since a tag like `qwen3:8b` can point at different weights over time.
/// Probed with `is` by the runner after warm-up.
abstract interface class AgentModelIdentity {
  Future<JsonMap> modelIdentity();
}
