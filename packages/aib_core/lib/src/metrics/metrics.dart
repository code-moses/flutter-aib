import 'dart:convert';

import '../aggregation/aggregator.dart';
import '../aggregation/stats.dart';
import '../common/json.dart';
import '../evaluation/assertions.dart';
import '../evaluation/verdict.dart';
import '../ports/agent.dart';
import '../ports/envelope.dart';
import '../task/task.dart';
import '../trace/trace.dart';
import 'feedback_metrics.dart';
import 'harm.dart';
import 'pricing.dart';
import 'simulator_metrics.dart';

/// Names an exchange for per-exchange views (trajectories, health tables).
/// The core names it by its key; a provider that knows an environment's
/// vocabulary can say more (`intents.invoke:data.count`).
typedef ExchangeLabel = String Function(Exchange exchange);

/// Whether an exchange talks to the person rather than to the app.
typedef ExchangePredicate = bool Function(Exchange exchange);

/// Input of every metric computation: trace + task + verdict. All metrics
/// are computed per episode from the trace (P6) and aggregated later.
final class MetricContext {
  MetricContext({required this.trace, this.task, this.verdict, this.assertions = const {}, ExchangeLabel? label, this.userInteraction})
    : label = label ?? _keyLabel;

  final EpisodeTrace trace;
  final TaskSpec? task;
  final Verdict? verdict;

  /// Assertion kinds registered by providers, beyond the built-in ones.
  final Map<String, AssertionPredicate> assertions;

  final ExchangeLabel label;

  /// Provider-supplied test for user interactions, see [isUserInteraction].
  final ExchangePredicate? userInteraction;

  static String _keyLabel(Exchange exchange) => exchange.key;

  late final List<Exchange> exchanges = trace.exchanges();

  late final List<Exchange> actions = exchanges.where((x) => x.kind == 'act' && !x.isMeta).toList();

  late final List<Exchange> observations = exchanges.where((x) => x.kind == 'observe' && !x.isMeta).toList();

  /// Keys the environment declared as waiting on a person
  /// ([EnvelopeSpec.blocksOnUser]) — the only way the core knows that an
  /// envelope asks the user rather than operating the app.
  late final Set<String> _blocksOnUser = {
    for (final spec in asJsonMap(trace.firstOfType(TraceEventTypes.envDescriptor)?.data)['envelopes'] as List? ?? const [])
      if (asJsonMap(spec)['blocksOnUser'] == true) '${asJsonMap(spec)['key']}',
  };

  /// Whether [exchange] addresses the person in front of the app.
  bool isUserInteraction(Exchange exchange) => _blocksOnUser.contains(exchange.key) || (userInteraction?.call(exchange) ?? false);

  /// Actions that operate on the *app*. Asking the user is declared `act` so it
  /// costs a step, but it changes no app state, and `path_efficiency`'s
  /// `optimalSteps` counts app actions only.
  late final List<Exchange> appActions = actions.where((x) => !isUserInteraction(x)).toList();

  /// Index into [exchanges] of the first app action, or -1.
  late final int firstAppAction = exchanges.indexWhere((x) => x.kind == 'act' && !x.isMeta && !isUserInteraction(x));

  /// Every decision an envelope carried, in order.
  late final List<JsonMap> decisions = [
    for (final exchange in exchanges)
      if (exchange.envelope.data['decision'] case final Map decision) decision.cast<String, Object?>(),
  ];

  /// Everything a decision note recorded, as `key=value` pairs. The routing
  /// and window annotations ride here (`route=intents`, `elided=3`).
  static Map<String, String> noteFields(Exchange exchange) {
    final decision = exchange.envelope.data['decision'];
    if (decision is! Map) return const {};
    final note = decision['note'];
    if (note is! String) return const {};
    return {
      for (final part in note.split(' '))
        if (part.indexOf('=') case final at when at > 0) part.substring(0, at): part.substring(at + 1),
    };
  }
}

/// A metric returns a value or null when it is not applicable to the episode
/// (e.g. state-diff metrics without fingerprint support — ADR 0002).
typedef MetricComputer = num? Function(MetricContext context);

final class MetricDefinition {
  const MetricDefinition({required this.name, required this.unit, required this.description, required this.compute, this.rateName});

  final String name;
  final String unit;
  final String description;
  final MetricComputer compute;

  /// For a 0/1 metric: the name its mean is reported under, with a Wilson
  /// (per task) or clustered (suite, tag) interval.
  final String? rateName;
}

/// A non-numeric per-episode value (a trajectory, a key sequence) that
/// group-level metrics read from [EpisodeRecord.features].
final class FeatureDefinition {
  const FeatureDefinition({required this.name, required this.compute});

  final String name;
  final Object? Function(MetricContext context) compute;
}

/// A metric over a group of episodes: one task's repetitions, or all of an
/// agent's episodes (`*`). Calibration, consistency and anything that needs
/// more than one episode lives here.
final class AggregateMetricDefinition {
  const AggregateMetricDefinition({required this.name, required this.unit, required this.description, required this.compute});

  final String name;
  final String unit;
  final String description;

  /// Null when not applicable to the group.
  final num? Function(List<EpisodeRecord> group) compute;
}

/// Metrics a caller switches on by name (`aib evaluate --metrics <name>`),
/// contributed by whoever emits the facts they read.
final class MetricProvider {
  const MetricProvider({
    required this.name,
    required this.description,
    this.metrics = const [],
    this.features = const [],
    this.aggregates = const [],
    this.assertions = const {},
    this.label,
    this.userInteraction,
  });

  final String name;
  final String description;
  final List<MetricDefinition> metrics;
  final List<FeatureDefinition> features;
  final List<AggregateMetricDefinition> aggregates;

  /// Assertion kinds for `traceAssertion`, `policies:` and
  /// `refusalRequires:` that need this provider's vocabulary.
  final Map<String, AssertionPredicate> assertions;

  /// A better name for an exchange than its key; the last provider that
  /// gives one wins.
  final ExchangeLabel? label;

  /// Exchanges that talk to the user, beyond keys the environment declared
  /// `blocksOnUser` — so traces recorded before that flag stay readable.
  final ExchangePredicate? userInteraction;
}

/// Metric registry (P7). [MetricsRegistry.builtin] carries the catalog of
/// spec §6.1 (effectiveness) and §6.2 (efficiency) plus the self-reported
/// resource counters of §6.3 that fall out of the same telemetry.
final class MetricsRegistry {
  MetricsRegistry();

  final Map<String, MetricDefinition> _metrics = {};
  final Map<String, FeatureDefinition> _features = {};
  final Map<String, AggregateMetricDefinition> _aggregates = {};
  final Map<String, AssertionPredicate> _assertions = {};
  final List<String> _providers = [];
  final List<ExchangePredicate> _userInteraction = [];
  ExchangeLabel? _label;

  void register(MetricDefinition definition) {
    _metrics[definition.name] = definition;
  }

  void registerProvider(MetricProvider provider) {
    _providers.add(provider.name);
    for (final metric in provider.metrics) {
      register(metric);
    }
    for (final feature in provider.features) {
      _features[feature.name] = feature;
    }
    for (final aggregate in provider.aggregates) {
      _aggregates[aggregate.name] = aggregate;
    }
    _assertions.addAll(provider.assertions);
    if (provider.label case final label?) _label = label;
    if (provider.userInteraction case final predicate?) {
      _userInteraction.add(predicate);
    }
  }

  /// Assertion kinds providers registered.
  Map<String, AssertionPredicate> get assertions => Map.unmodifiable(_assertions);

  /// Metric name -> reported rate name, for every 0/1 metric that has one.
  Map<String, String> get rates => {for (final metric in _metrics.values) metric.name: ?metric.rateName};

  /// The context every metric of this registry is computed in: its
  /// providers' assertion kinds, exchange labels and user predicates.
  MetricContext contextFor(EpisodeTrace trace, {TaskSpec? task, Verdict? verdict}) => MetricContext(
    trace: trace,
    task: task,
    verdict: verdict,
    assertions: assertions,
    label: _label,
    userInteraction: _userInteraction.isEmpty ? null : (x) => _userInteraction.any((predicate) => predicate(x)),
  );

  List<String> get names => _metrics.keys.toList()..sort();

  /// Providers switched on, in order — recorded with the verdicts.
  List<String> get providers => List.unmodifiable(_providers);

  List<AggregateMetricDefinition> get aggregates => List.unmodifiable(_aggregates.values);

  MetricDefinition? operator [](String name) => _metrics[name];

  Map<String, num?> computeAll(MetricContext context) => {
    for (final metric in _metrics.values) metric.name: metric.compute(context),
    ...agentCounters(context),
  };

  Map<String, Object?> computeFeatures(MetricContext context) => {for (final feature in _features.values) feature.name: feature.compute(context)};

  /// [pricing] enables `cost_usd` (§6.3). Without a pinned price table the
  /// metric is simply absent rather than silently zero — an unpriced run
  /// must not look free.
  factory MetricsRegistry.builtin({PriceTable? pricing, List<MetricProvider> providers = const []}) {
    final registry = MetricsRegistry();
    for (final metric in builtinMetrics) {
      registry.register(metric);
    }
    if (pricing != null && !pricing.isEmpty) {
      registry.register(costMetric(pricing));
      for (final metric in sideCallMetrics(pricing)) {
        registry.register(metric);
      }
    }
    for (final provider in providers) {
      registry.registerProvider(provider);
    }
    return registry;
  }
}

/// Numeric facts an agent put under `extra.counters`, summed over the episode
/// as `agent.<name>` — observability for an agent the framework does not
/// know, with no code. Descriptive only; judgement needs a [MetricProvider].
Map<String, num> agentCounters(MetricContext context) {
  final sums = <String, num>{};
  for (final exchange in context.exchanges) {
    final decision = exchange.envelope.data['decision'];
    if (decision is! Map) continue;
    final counters = asJsonMap(asJsonMap(decision['extra'])[AgentDecision.countersKey]);
    for (final entry in counters.entries) {
      if (entry.value is num) {
        sums.update('agent.${entry.key}', (v) => v + (entry.value as num), ifAbsent: () => entry.value as num);
      }
    }
  }
  return sums;
}

/// A9: reported prompt tokens over `requestChars / 4`, over the decisions that
/// carry both. Null where the agent reports no request size.
num? _tokenReportRatio(MetricContext ctx) {
  var tokens = 0;
  var chars = 0;
  for (final d in ctx.decisions) {
    final sent = (asJsonMap(d['extra'])['requestChars'] as num?)?.toInt() ?? 0;
    if (sent > 0) {
      chars += sent;
      tokens += (d['tokensPrompt'] as num?)?.toInt() ?? 0;
    }
  }
  return chars == 0 ? null : tokens / (chars / 4);
}

/// `cost_usd` = self-reported tokens × pinned prices, summed per envelope so
/// that episodes mixing models are costed correctly (§6.3).
MetricDefinition costMetric(PriceTable pricing) => MetricDefinition(
  name: 'cost_usd',
  unit: pricing.currency.toLowerCase(),
  description:
      'Self-reported tokens priced with the run\'s pinned price table'
      '${pricing.asOf == null ? '' : ' (as of ${pricing.asOf})'}',
  compute: (ctx) {
    var total = 0.0;
    var priced = false;
    for (final exchange in ctx.exchanges) {
      final decision = exchange.envelope.data['decision'];
      if (decision is! Map) continue;
      final d = decision.cast<String, Object?>();
      final price = pricing[d['model'] as String?];
      if (price == null) continue;
      priced = true;
      total += price.cost(
        promptTokens: _asInt(d['tokensPrompt']),
        completionTokens: _asInt(d['tokensCompletion']),
        cachedPromptTokens: _asInt(d['tokensCachedPrompt']),
        cacheWriteTokens: _asInt(d['tokensCacheWrite']),
        reasoningTokens: _asInt(d['tokensReasoning']),
      );
    }
    // Calls to another model this episode paid for, priced by *their* model: a
    // hosted decider in front of a local episode must not be charged at the
    // local rate.
    for (final call in _sideCalls(ctx)) {
      final price = pricing[call.model];
      if (price == null) continue;
      priced = true;
      total += price.cost(promptTokens: call.tokensPrompt, completionTokens: call.tokensCompletion);
    }
    // No known model in the whole episode -> unknown, not free.
    return priced ? total : null;
  },
);

List<SideCall> _sideCalls(MetricContext ctx) => [
  for (final decision in ctx.decisions)
    for (final raw in asJsonMap(decision['extra'])[AgentDecision.sideCallsKey] as List? ?? const []) SideCall.fromJson(asJsonMap(raw)),
];

/// What the episode spent on models other than the one doing the work
/// (`side_call_*`). Null when it made none, so an agent without side calls
/// is absent from the column rather than reported as zero.
List<MetricDefinition> sideCallMetrics(PriceTable pricing) => [
  MetricDefinition(
    name: 'side_call_count',
    unit: 'count',
    description: 'Calls to a model other than the one running the episode',
    compute: (ctx) {
      final calls = _sideCalls(ctx);
      return calls.isEmpty ? null : calls.fold<int>(0, (sum, call) => sum + call.calls);
    },
  ),
  MetricDefinition(
    name: 'side_call_tokens',
    unit: 'tokens',
    description:
        'Tokens spent on those calls — outside tokens_total, which is the '
        'agent\'s own context',
    compute: (ctx) {
      final calls = _sideCalls(ctx);
      return calls.isEmpty ? null : calls.fold<int>(0, (sum, call) => sum + call.tokensTotal);
    },
  ),
  MetricDefinition(
    name: 'side_call_cost_usd',
    unit: pricing.currency.toLowerCase(),
    description: 'The part of cost_usd those calls account for',
    compute: (ctx) {
      final calls = _sideCalls(ctx);
      if (calls.isEmpty) return null;
      var total = 0.0;
      var priced = false;
      for (final call in calls) {
        final price = pricing[call.model];
        if (price == null) continue;
        priced = true;
        total += price.cost(promptTokens: call.tokensPrompt, completionTokens: call.tokensCompletion);
      }
      return priced ? total : null;
    },
  ),
  MetricDefinition(
    name: 'side_call_latency_ms',
    unit: 'ms',
    description: 'Wall clock those calls added before or between steps',
    compute: (ctx) {
      final calls = _sideCalls(ctx);
      return calls.isEmpty ? null : calls.fold<int>(0, (sum, call) => sum + call.latencyMs);
    },
  ),
];

bool _endedWith(MetricContext ctx, TerminationReason reason) => ctx.trace.endReason == reason.name;

/// Terminated by a budget rather than by the agent's own decision.
bool _budgetExhausted(MetricContext ctx) => const [
  TerminationReason.budgetSteps,
  TerminationReason.budgetTokens,
  TerminationReason.budgetTurns,
  TerminationReason.timeout,
].any((reason) => _endedWith(ctx, reason));

/// Stopped by the harness rather than by the agent — a budget, or the
/// no-progress guard. What `overdue_termination` means by "never said so": the
/// agent did not end the episode itself, whichever rule did it for them.
bool _harnessTerminated(MetricContext ctx) => _budgetExhausted(ctx) || _endedWith(ctx, TerminationReason.noProgress);

int? _wallClockMs(MetricContext ctx) {
  final end = ctx.trace.firstOfType(TraceEventTypes.episodeEnd);
  return (end?.data['wallClockMs'] as num?)?.toInt();
}

/// The per-call records an agent put in a decision's `extra.llm`.
List<JsonMap> _llmCalls(JsonMap decision) => switch (asJsonMap(decision['extra'])['llm']) {
  final List calls => [for (final call in calls) asJsonMap(call)],
  _ => const [],
};

int _sumDecisions(MetricContext ctx, int Function(JsonMap) pick) => ctx.decisions.fold(0, (sum, decision) => sum + pick(decision));

/// The largest single prompt of the episode, or 0 when nothing reported one.
int _peakPrompt(MetricContext ctx) => ctx.decisions.fold(0, (peak, d) {
  final prompt = _asInt(d['tokensPrompt']);
  return prompt > peak ? prompt : peak;
});

int _asInt(Object? v) => (v as num?)?.toInt() ?? 0;

/// Splits an episode's prompt tokens into what grew and what was re-sent.
///
/// The part of one request's prompt already in the previous one is `min(prompt,
/// previousPrompt)`. When the agent prunes its observation window the shrunken
/// request counts as wholly re-sent, so [_tokensNew] never overstates.
(int resent, int fresh) _promptSplit(MetricContext ctx) {
  var resent = 0;
  var fresh = 0;
  var previous = 0;
  var any = false;
  for (final exchange in ctx.exchanges) {
    final decision = exchange.envelope.data['decision'];
    if (decision is! Map) continue;
    final prompt = _asInt(decision['tokensPrompt']);
    // A bootstrap envelope costs no LLM call and is not a turn's prompt.
    if (prompt == 0) continue;
    any = true;
    final carried = prompt < previous ? prompt : previous;
    resent += carried;
    fresh += prompt - carried;
    previous = prompt;
  }
  return any ? (resent, fresh) : (-1, -1);
}

double? _tokensResent(MetricContext ctx) {
  final (resent, _) = _promptSplit(ctx);
  return resent < 0 ? null : resent.toDouble();
}

double? _tokensNew(MetricContext ctx) {
  final (_, fresh) = _promptSplit(ctx);
  if (fresh < 0) return null;
  return (fresh + _sumDecisions(ctx, (d) => _asInt(d['tokensCompletion']))).toDouble();
}

/// Strategy names the router recorded, in envelope order.
List<String> _routes(MetricContext ctx) => [for (final exchange in ctx.exchanges) ?MetricContext.noteFields(exchange)['route']];

/// The `LlmErrorKind` an abort was classified with, or null when the episode
/// did not abort on a provider failure.
String? _abortLlmKind(MetricContext ctx) {
  if (!_endedWith(ctx, TerminationReason.abort)) return null;
  final message = ctx.trace.firstOfType(TraceEventTypes.episodeEnd)?.data['message'];
  if (message is! String || !message.startsWith('llm_error:')) return null;
  final rest = message.substring('llm_error:'.length);
  final end = rest.indexOf(':');
  return end < 0 ? rest.trim() : rest.substring(0, end).trim();
}

num? _abortKind(MetricContext ctx, String kind, {String? alsoMatch}) {
  if (!_endedWith(ctx, TerminationReason.abort)) return null;
  final actual = _abortLlmKind(ctx);
  return (actual == kind || (alsoMatch != null && actual == alsoMatch)) ? 1 : 0;
}

/// Identity of an attempt: same key + same payload = the same thing tried
/// again (basis of `retry_count`).
String _signature(Exchange exchange) => '${exchange.key}#${jsonFingerprint(exchange.envelope.data['payload'])}';

int? _descriptorUs(MetricContext ctx) => ctx.trace.firstOfType(TraceEventTypes.envDescriptor)?.tUs;

final List<MetricDefinition> builtinMetrics = [
  // ---- Effectiveness (§6.1) — per-episode indicators; the aggregator
  //      turns success/failure/abort into *_rate with Wilson CIs. ----
  MetricDefinition(
    name: 'success',
    rateName: 'success_rate',
    unit: 'bool',
    description: 'Verdict is success (aggregated to success_rate)',
    compute: (ctx) => ctx.verdict == null ? null : (ctx.verdict!.type == .success ? 1 : 0),
  ),
  MetricDefinition(
    name: 'weighted_score',
    unit: 'score',
    description: 'success=1, partial=credit, failure=0',
    compute: (ctx) => ctx.verdict == null || ctx.verdict!.type == .error ? null : ctx.verdict!.score,
  ),
  MetricDefinition(
    name: 'failure',
    rateName: 'failure_rate',
    unit: 'bool',
    description: 'Verdict is failure (aggregated to failure_rate)',
    compute: (ctx) => ctx.verdict == null ? null : (ctx.verdict!.type == .failure ? 1 : 0),
  ),
  MetricDefinition(
    name: 'abort',
    rateName: 'abort_rate',
    unit: 'bool',
    description: 'Episode terminated via meta.abort (-> abort_rate)',
    compute: (ctx) {
      final end = ctx.trace.firstOfType(TraceEventTypes.episodeEnd);
      if (end == null) return null;
      return end.data['reason'] == 'abort' ? 1 : 0;
    },
  ),
  MetricDefinition(
    name: 'infrastructure_error',
    rateName: 'infrastructure_error_rate',
    unit: 'bool',
    description: 'Framework fault — never attributed to the agent (§5.2)',
    compute: (ctx) {
      final end = ctx.trace.firstOfType(TraceEventTypes.episodeEnd);
      if (end == null) return 1;
      return end.data['reason'] == 'frameworkFault' ? 1 : 0;
    },
  ),
  // Termination quality (§6.1): separates "misjudged the state" from "ran out
  // of room".
  MetricDefinition(
    name: 'premature_termination',
    rateName: 'premature_termination_rate',
    unit: 'bool',
    description:
        'Agent declared meta.done but the task was not solved — it believed '
        'it was finished and was wrong',
    compute: (ctx) {
      final verdict = ctx.verdict;
      if (verdict == null || verdict.type == .error) return null;
      return _endedWith(ctx, TerminationReason.done) && verdict.type != .success ? 1 : 0;
    },
  ),
  MetricDefinition(
    name: 'overdue_termination',
    rateName: 'overdue_termination_rate',
    unit: 'bool',
    description:
        'Task was solved, but the agent never said so and ran into a budget '
        'or timeout — the opposite failure of premature_termination',
    compute: (ctx) {
      final verdict = ctx.verdict;
      if (verdict == null || verdict.type == .error) return null;
      return _harnessTerminated(ctx) && verdict.type == .success ? 1 : 0;
    },
  ),
  MetricDefinition(
    name: 'budget_exhaustion',
    rateName: 'budget_exhaustion_rate',
    unit: 'bool',
    description:
        'Episode ended on a step, token or wall-clock budget rather than by '
        'the agent\'s own decision (-> budget_exhaustion_rate)',
    compute: (ctx) {
      if (ctx.trace.firstOfType(TraceEventTypes.episodeEnd) == null) {
        return null;
      }
      return _budgetExhausted(ctx) ? 1 : 0;
    },
  ),
  MetricDefinition(
    name: 'no_progress',
    unit: 'bool',
    description:
        'Episode ended because the same envelope kept returning the same '
        'result — the agent was in a loop, not out of room',
    compute: (ctx) {
      if (ctx.trace.firstOfType(TraceEventTypes.episodeEnd) == null) {
        return null;
      }
      return _endedWith(ctx, TerminationReason.noProgress) ? 1 : 0;
    },
  ),
  MetricDefinition(
    name: 'suppressed_repeats',
    unit: 'count',
    description:
        'Results the engine replaced with a no-progress notice because the '
        'agent had already been given that exact answer for that exact '
        'envelope',
    compute: (ctx) {
      var suppressed = 0;
      for (final exchange in ctx.exchanges) {
        if (exchange.result?.data['suppressed'] == true) suppressed++;
      }
      return suppressed;
    },
  ),

  MetricDefinition(
    name: 'milestone_coverage',
    unit: 'ratio',
    description:
        'Essential states reached / declared (§5.2 stateSequence). Null for '
        'tasks without milestones; independent of the scoring criteria, so '
        'it also reports coverage for tasks scored by finalStateMatch.',
    compute: (ctx) {
      final milestones = ctx.task?.groundTruth.milestones ?? const [];
      if (milestones.isEmpty) return null;
      final probes = ctx.trace.probes();
      if (probes.isEmpty) return null;
      var reached = 0;
      for (final milestone in milestones) {
        final hit = probes.any((probe) => probe.error == null && milestone.expectation.mismatch(probe.resultFor(milestone.query)) == null);
        if (hit) reached++;
      }
      return reached / milestones.length;
    },
  ),
  MetricDefinition(
    name: 'unsupported_envelope_count',
    unit: 'count',
    description:
        'Envelopes answered with status unsupported (agent requested a '
        'capability the environment does not have)',
    compute: (ctx) => ctx.exchanges.where((x) => x.status == 'unsupported').length,
  ),
  MetricDefinition(
    name: 'kind_integrity_violations',
    unit: 'count',
    description:
        'observe-declared envelopes with a verifiable state change '
        '(state-diff; requires fingerprint support)',
    compute: (ctx) {
      if (ctx.exchanges.every((x) => x.fingerprintAfter == null)) return null;
      return ctx.observations.where((x) => x.hasStateChange).length;
    },
  ),

  // Efficiency (§6.2)
  MetricDefinition(
    name: 'wall_clock_ms',
    unit: 'ms',
    description: 'End of reset -> verdict-ready end state (monotonic clock)',
    compute: _wallClockMs,
  ),
  MetricDefinition(
    name: 'success_within_target',
    rateName: 'success_within_target_rate',
    unit: 'bool',
    description:
        'Verdict is success and the episode took no longer than the task\'s '
        'budget.targetSeconds (wall clock). The pass a user who is waiting '
        'would count: solved in 60 s against a 10 s target is not one. Null '
        'for tasks without a target, or without a verdict',
    compute: (ctx) {
      final target = ctx.task?.budget.targetSeconds;
      final verdict = ctx.verdict;
      if (target == null || verdict == null) return null;
      final wallClock = _wallClockMs(ctx);
      if (wallClock == null) return null;
      return verdict.type == .success && wallClock <= target * 1000 ? 1 : 0;
    },
  ),
  MetricDefinition(
    name: 'llm_latency_ms',
    unit: 'ms',
    description: 'Sum of self-reported LLM latencies',
    compute: (ctx) => _sumDecisions(ctx, (d) => _asInt(d['llmLatencyMs'])),
  ),
  MetricDefinition(
    name: 'framework_overhead_ms',
    unit: 'ms',
    description:
        'wall_clock − llm_latency − environment handling time (sanity check '
        'that the framework does not dominate the measurement, §10)',
    compute: (ctx) {
      final wallClock = _wallClockMs(ctx);
      if (wallClock == null) return null;
      var handleMs = 0;
      for (final exchange in ctx.exchanges) {
        handleMs += _asInt(exchange.result?.data['handleMs']);
      }
      return wallClock - _sumDecisions(ctx, (d) => _asInt(d['llmLatencyMs'])) - handleMs;
    },
  ),
  MetricDefinition(
    name: 'action_count',
    unit: 'count',
    description: 'act-envelopes until termination (meta.* excluded)',
    compute: (ctx) => ctx.actions.length,
  ),
  MetricDefinition(
    name: 'observation_count',
    unit: 'count',
    description: 'observe-envelopes until termination',
    compute: (ctx) => ctx.observations.length,
  ),
  MetricDefinition(
    name: 'observation_bytes',
    unit: 'bytes',
    description:
        'Result payload volume of observe-envelopes (proxy for the context '
        'load of the strategy)',
    compute: (ctx) {
      var bytes = 0;
      for (final exchange in ctx.observations) {
        bytes += _asInt(exchange.result?.data['payloadBytes']);
      }
      return bytes;
    },
  ),
  MetricDefinition(
    name: 'redundant_action_ratio',
    unit: 'ratio',
    description:
        'app act-envelopes without a state-fingerprint change / their count; '
        'user interactions excluded, they change no app state by definition. '
        'Only as fine as the fingerprint: a store-only fingerprint counts '
        'navigation and scrolling as redundant (requires fingerprint support)',
    compute: (ctx) {
      if (ctx.appActions.isEmpty) return null;
      if (ctx.appActions.every((x) => x.fingerprintAfter == null)) return null;
      final redundant = ctx.appActions.where((x) => x.fingerprintAfter != null && !x.hasStateChange).length;
      return redundant / ctx.appActions.length;
    },
  ),
  MetricDefinition(
    name: 'path_efficiency',
    unit: 'ratio',
    description:
        'Minimal known action count (task optimalSteps) / app actions taken '
        '(user.* excluded)',
    compute: (ctx) {
      final optimal = ctx.task?.optimalSteps;
      if (optimal == null || ctx.appActions.isEmpty) return null;
      return optimal / ctx.appActions.length;
    },
  ),

  // Robustness and recovery (§6.4), derived from the persisted trace alone.
  MetricDefinition(
    name: 'failed_envelope_count',
    unit: 'count',
    description:
        'Envelopes the environment answered with status failed '
        '(denominator of the recovery metrics)',
    compute: (ctx) => ctx.exchanges.where((x) => x.status == 'failed').length,
  ),
  MetricDefinition(
    name: 'injected_fault_count',
    unit: 'count',
    description:
        'Failures a FaultInjectingEnvironment put on the channel (G2); '
        'failed_envelope_count minus this is what the app itself refused',
    compute: (ctx) => ctx.exchanges.where((x) {
      return switch (x.result?.data['error']) {
        {'details': {'injected': true}} => true,
        _ => false,
      };
    }).length,
  ),
  MetricDefinition(
    name: 'retry_count',
    unit: 'count',
    description:
        'Envelopes repeating a (key, payload) pair that already failed — '
        'the agent tried the same thing again',
    compute: (ctx) {
      final failed = <String>{};
      var retries = 0;
      for (final exchange in ctx.exchanges) {
        final signature = _signature(exchange);
        if (failed.contains(signature)) retries++;
        if (exchange.status == 'failed') failed.add(signature);
      }
      return retries;
    },
  ),
  MetricDefinition(
    name: 'recovered',
    rateName: 'recovery_success_rate',
    unit: 'bool',
    description:
        'Episode hit at least one failed envelope and still ended in success '
        '(-> recovery_success_rate). Null without any failure — there was '
        'nothing to recover from',
    compute: (ctx) {
      if (ctx.verdict == null || ctx.verdict!.type == .error) {
        return null;
      }
      if (!ctx.exchanges.any((x) => x.status == 'failed')) return null;
      return ctx.verdict!.type == .success ? 1 : 0;
    },
  ),
  MetricDefinition(
    name: 'recovery_time_ms',
    unit: 'ms',
    description:
        'First failed envelope -> next envelope that actually changed the app '
        'state; how long the agent needed to get moving again',
    compute: (ctx) {
      final exchanges = ctx.exchanges;
      final failureIndex = exchanges.indexWhere((x) => x.status == 'failed');
      if (failureIndex < 0) return null;
      final failedAtUs = (exchanges[failureIndex].result ?? exchanges[failureIndex].envelope).tUs;
      for (var i = failureIndex + 1; i < exchanges.length; i++) {
        final exchange = exchanges[i];
        if (exchange.kind == 'act' && !exchange.isMeta && exchange.hasStateChange) {
          final recoveredAtUs = (exchange.result ?? exchange.envelope).tUs;
          return (recoveredAtUs - failedAtUs) / 1000;
        }
      }
      return null; // never recovered, or the environment has no fingerprint
    },
  ),
  MetricDefinition(
    name: 'self_correction_count',
    unit: 'count',
    description:
        'Actions that returned the app to a state it had already been in — '
        'the agent undid one of its own changes (requires fingerprints)',
    compute: (ctx) {
      if (ctx.exchanges.every((x) => x.fingerprintAfter == null)) return null;
      final seen = <String>{};
      var corrections = 0;
      for (final exchange in ctx.exchanges) {
        final before = exchange.fingerprintBefore;
        if (before != null) seen.add(before);
        if (exchange.kind == 'act' && !exchange.isMeta && exchange.hasStateChange && seen.contains(exchange.fingerprintAfter)) {
          corrections++;
        }
        final after = exchange.fingerprintAfter;
        if (after != null) seen.add(after);
      }
      return corrections;
    },
  ),

  // Routing, derived from `AgentDecision.note` and envelope key prefixes.
  MetricDefinition(
    name: 'strategy_switch_count',
    unit: 'count',
    description:
        'Times the routed strategy changed between consecutive envelopes '
        '(null for agents that route nothing)',
    compute: (ctx) {
      final routes = _routes(ctx);
      if (routes.isEmpty) return null;
      var switches = 0;
      for (var i = 1; i < routes.length; i++) {
        if (routes[i] != routes[i - 1]) switches++;
      }
      return switches;
    },
  ),
  MetricDefinition(
    name: 'escalation_count',
    unit: 'count',
    description:
        'Cascade escalations: the router gave up on one strategy and moved '
        'to the next',
    compute: (ctx) {
      final routed = _routes(ctx);
      if (routed.isEmpty) return null;
      return ctx.exchanges.where((x) => MetricContext.noteFields(x)['reason']?.startsWith('escalation') ?? false).length;
    },
  ),
  MetricDefinition(
    name: 'escalation_recovered',
    unit: 'bool',
    description:
        'The episode escalated and still succeeded — did falling back to '
        'another strategy actually rescue the task, or only cost budget? '
        'Null when nothing escalated',
    compute: (ctx) {
      if (ctx.verdict == null) return null;
      final escalated = ctx.exchanges.any((x) => MetricContext.noteFields(x)['reason']?.startsWith('escalation') ?? false);
      if (!escalated) return null;
      return ctx.verdict!.type == .success ? 1 : 0;
    },
  ),

  // Clarification.
  MetricDefinition(
    name: 'user_wait_ms',
    unit: 'ms',
    description:
        'Time the episode spent waiting for a human. Excluded from '
        'wall_clock_ms, reported separately so the cost of asking is visible '
        'rather than hidden',
    compute: (ctx) {
      var total = 0;
      var any = false;
      for (final exchange in ctx.exchanges) {
        final waited = exchange.result?.data['userWaitMs'];
        if (waited is num) {
          any = true;
          total += waited.toInt();
        }
      }
      return any ? total : null;
    },
  ),

  // Context load.
  MetricDefinition(
    name: 'tokens_resent',
    unit: 'tokens',
    description:
        'Of the prompt tokens an episode spent, how many were the same '
        'context sent again. A request carries the whole conversation, so the '
        'system prompt, the tool definitions and the catalog are re-sent on '
        'every turn; this is what that cost, and it is the difference between '
        'an episode that ran out of room to think and one that paid nine '
        'times for the same prefix. Computed as the prompt total minus what '
        'grew: sum over turns of min(prompt, previous prompt)',
    compute: _tokensResent,
  ),
  MetricDefinition(
    name: 'tokens_new',
    unit: 'tokens',
    description:
        'Prompt tokens that were not already in the previous request, plus '
        'every completion token — what the episode actually added to the '
        'conversation, as opposed to what it re-sent. Falls when a context '
        'window is pruned and the pruned turn is not counted as new again, '
        'which understates it slightly and never overstates it',
    compute: _tokensNew,
  ),
  MetricDefinition(
    name: 'turns',
    unit: 'count',
    description:
        'Envelopes the agent emitted, acting or observing, prefetches and '
        'meta.* included — how many times it went round the loop. Neither '
        'steps (acts only, by design) nor tokens (dominated by the re-sent '
        'prefix) answers that. Not the `maxTurns` budget, which counts '
        'decisions and leaves prefetches out',
    compute: (ctx) => ctx.exchanges.length.toDouble(),
  ),
  MetricDefinition(
    name: 'truncated_result_count',
    unit: 'count',
    description:
        'Results the environment had to cut down to fit its payload cap. '
        'Above zero, the agent was working from partial information',
    compute: (ctx) => ctx.exchanges.where((x) => asJsonMap(x.result?.data['payload'])['truncated'] == true).length,
  ),
  MetricDefinition(
    name: 'elided_result_count',
    unit: 'count',
    description:
        'Tool results the agent replaced with a stub to stay inside its '
        'context window (observation window). Null for agents without one',
    compute: (ctx) {
      var maximum = 0;
      var any = false;
      for (final exchange in ctx.exchanges) {
        final elided = MetricContext.noteFields(exchange)['elided'];
        if (elided == null) continue;
        any = true;
        maximum = maximum > (int.tryParse(elided) ?? 0) ? maximum : (int.tryParse(elided) ?? 0);
      }
      return any ? maximum : null;
    },
  ),
  MetricDefinition(
    name: 'invalid_tool_call_count',
    unit: 'count',
    description:
        'Calls the environment rejected as schema violations '
        '(EnvelopeError.badParams). '
        'A model failing to match a schema is not the same thing as an app '
        'that failed, and before this they were the same number',
    compute: (ctx) =>
        ctx.exchanges.where((x) => x.result?.data['error'] is Map && asJsonMap(x.result!.data['error'])['code'] == EnvelopeError.badParams).length,
  ),

  // Abort classification: a context overflow is a framework limitation, an
  // agent judging the task impossible is a finding.
  MetricDefinition(
    name: 'abort_context_length',
    unit: 'bool',
    description:
        'Aborted because the conversation outgrew the model\'s context '
        'window (null unless the episode aborted)',
    compute: (ctx) => _abortKind(ctx, 'contextLength'),
  ),
  MetricDefinition(
    name: 'abort_rate_limit',
    unit: 'bool',
    description: 'Aborted because the provider rate-limited us',
    compute: (ctx) => _abortKind(ctx, 'rateLimit'),
  ),
  MetricDefinition(
    name: 'abort_transport',
    unit: 'bool',
    description: 'Aborted on a network or provider-side failure',
    compute: (ctx) => _abortKind(ctx, 'transport', alsoMatch: 'server'),
  ),
  MetricDefinition(
    name: 'abort_agent_decision',
    unit: 'bool',
    description:
        'Aborted because the agent itself judged the task impossible — the '
        'only abort flavour that says something about the strategy',
    compute: (ctx) {
      if (!_endedWith(ctx, TerminationReason.abort)) return null;
      return _abortLlmKind(ctx) == null ? 1 : 0;
    },
  ),

  // Context, discovery and the app's share (backlog C1–C6)
  MetricDefinition(
    name: 'uninformative_result_count',
    unit: 'count',
    description:
        'Results identical to an earlier answer of the same key to a '
        'different request — the app listing everything because nothing '
        'matched. An environment property as much as an agent one',
    compute: (ctx) =>
        ctx.exchanges.where((x) => ((x.result?.data['answerIndex'] as num?) ?? 0) > 0 && ((x.result?.data['repeatIndex'] as num?) ?? 0) == 0).length,
  ),
  MetricDefinition(
    name: 'turns_to_first_act',
    unit: 'count',
    description:
        'Envelopes emitted before the first app action; null when the '
        'episode never acts on the app',
    compute: (ctx) => ctx.firstAppAction < 0 ? null : ctx.firstAppAction.toDouble(),
  ),
  MetricDefinition(
    name: 'discovery_turn_count',
    unit: 'count',
    description:
        'Observations before the first app action — what the agent read '
        'before it could do anything; null when it never acts',
    compute: (ctx) => ctx.firstAppAction < 0 ? null : ctx.exchanges.take(ctx.firstAppAction).where((x) => x.kind == 'observe').length,
  ),
  MetricDefinition(
    name: 'peak_prompt_tokens',
    unit: 'tokens',
    description:
        'The largest single request of the episode — what a model window '
        'must hold, where tokens_prompt is only the sum',
    compute: (ctx) {
      final peak = _peakPrompt(ctx);
      return peak == 0 ? null : peak;
    },
  ),
  MetricDefinition(
    name: 'cache_hit_ratio',
    unit: 'ratio',
    description:
        'Of the prompt tokens an episode spent, the share the provider served '
        'from its cache. Read it next to tokens_resent, which is the same '
        'prefix counted in tokens rather than in money: caching changes what '
        'the re-sent context costs and never how much of the window it takes, '
        'so a high ratio and a high tokens_resent together mean the episode '
        'was cheap and still cramped. For a local model the money is nil but '
        'the time is not: a cached prefix is not prefilled again. Null where '
        'no client reported caching at all (older Ollama servers, runs '
        'recorded before the field existed) — not zero, which would read as '
        'a cache that missed',
    compute: (ctx) {
      var prompt = 0;
      var cached = 0;
      var reported = false;
      for (final d in ctx.decisions) {
        prompt += _asInt(d['tokensPrompt']);
        if (d.containsKey('tokensCachedPrompt')) reported = true;
        cached += _asInt(d['tokensCachedPrompt']);
      }
      if (!reported || prompt == 0) return null;
      return cached / prompt;
    },
  ),
  MetricDefinition(
    name: 'reasoning_token_share',
    unit: 'ratio',
    description:
        'Of the completion tokens an episode spent, the share that went to '
        'hidden reasoning rather than to the tool calls and the answer. A '
        'reasoning model that spends its budget thinking and a model that '
        'spends it acting look identical in tokens_completion. Null where no '
        'client reported reasoning tokens',
    compute: (ctx) {
      var completion = 0;
      var reasoning = 0;
      var reported = false;
      for (final d in ctx.decisions) {
        completion += _asInt(d['tokensCompletion']);
        if (d.containsKey('tokensReasoning')) reported = true;
        reasoning += _asInt(d['tokensReasoning']);
      }
      if (!reported || completion == 0) return null;
      return reasoning / completion;
    },
  ),
  MetricDefinition(
    name: 'context_utilization',
    unit: 'ratio',
    description:
        'peak_prompt_tokens / the context window the agent declared '
        '(manifest metadata contextWindow); null when it declared none',
    compute: (ctx) {
      final agent = asJsonMap(ctx.trace.firstOfType(TraceEventTypes.episodeStart)?.data['agent']);
      final window = asJsonMap(agent['metadata'])['contextWindow'];
      if (window is! num || window <= 0) return null;
      final peak = _peakPrompt(ctx);
      return peak == 0 ? null : peak / window;
    },
  ),
  MetricDefinition(
    name: 'time_to_first_act_ms',
    unit: 'ms',
    description:
        'From the end of the reset to the result of the first app action — '
        'how long a user waits before anything happens (includes user '
        'waits); null when the episode never acts',
    compute: (ctx) {
      final start = _descriptorUs(ctx);
      if (start == null || ctx.firstAppAction < 0) return null;
      final first = ctx.exchanges[ctx.firstAppAction];
      return ((first.result ?? first.envelope).tUs - start) / 1000;
    },
  ),
  MetricDefinition(
    name: 'llm_call_latency_p95',
    unit: 'ms',
    description:
        '95th percentile of per-call LLM latency (self-reported; a decision '
        'with several calls counts its mean)',
    compute: (ctx) {
      final latencies = <num>[];
      for (final d in ctx.decisions) {
        final calls = _asInt(d['llmCalls']);
        if (calls > 0) latencies.add(_asInt(d['llmLatencyMs']) / calls);
      }
      return latencies.isEmpty ? null : Stats.percentile(latencies, 95);
    },
  ),
  MetricDefinition(
    name: 'unwarranted_abort',
    rateName: 'unwarranted_abort_rate',
    unit: 'bool',
    description:
        'The agent aborted on its own judgement where refusing is not the '
        'answer (-> unwarranted_abort_rate). Over-refusal; also flags tasks '
        'that cannot be done as written',
    compute: (ctx) {
      if (ctx.verdict == null || ctx.verdict!.type == .error) {
        return null;
      }
      final agentAbort = _endedWith(ctx, TerminationReason.abort) && _abortLlmKind(ctx) == null;
      return agentAbort && !(ctx.task?.abortIsAnAnswer ?? false) ? 1 : 0;
    },
  ),

  // Resources (§6.3, self-reported telemetry)
  MetricDefinition(
    name: 'tokens_prompt',
    unit: 'tokens',
    description: 'Prompt tokens (self-reported provider usage)',
    compute: (ctx) => _sumDecisions(ctx, (d) => _asInt(d['tokensPrompt'])),
  ),
  MetricDefinition(
    name: 'tokens_completion',
    unit: 'tokens',
    description: 'Completion tokens (self-reported provider usage)',
    compute: (ctx) => _sumDecisions(ctx, (d) => _asInt(d['tokensCompletion'])),
  ),
  MetricDefinition(
    name: 'tokens_total',
    unit: 'tokens',
    description: 'Prompt + completion tokens (self-reported)',
    compute: (ctx) => _sumDecisions(ctx, (d) => _asInt(d['tokensPrompt']) + _asInt(d['tokensCompletion'])),
  ),
  MetricDefinition(
    name: 'turns_answered',
    unit: 'count',
    description:
        'Follow-ups the agent answered with a done of its own, of those the '
        'task asked (null for a single-turn task). A follow-up counts once a '
        'later meta.done closes it; simulated follow-ups are not included',
    compute: (ctx) {
      final wanted = ctx.task?.turns.length ?? 0;
      if (wanted == 0) return null;
      var answered = 0;
      var open = false;
      for (final event in ctx.trace.events) {
        if (event.type == TraceEventTypes.userTurn) {
          open = event.data['simulated'] != true;
        } else if (open && event.type == TraceEventTypes.agentEnvelope && event.data['key'] == Envelope.metaDone) {
          answered++;
          open = false;
        }
      }
      return answered;
    },
  ),
  MetricDefinition(
    name: 'steering_delivered_share',
    unit: 'ratio',
    description:
        'Of the steering messages the task declares, the share the agent '
        'actually heard: due before the episode ended, and the agent can be '
        'steered. A message that never became due is one the agent finished '
        'or gave up before. Null for a task without steering',
    compute: (ctx) {
      final declared = ctx.task?.steering.length ?? 0;
      if (declared == 0) return null;
      final delivered = ctx.trace.events.where((e) => e.type == TraceEventTypes.userSteer && e.data['delivered'] == true).length;
      return delivered / declared;
    },
  ),
  MetricDefinition(
    name: 'facts_seen_share',
    unit: 'ratio',
    description:
        'Of the facts the task says its answer turns on (requiredFacts), the '
        'share that ever appeared in an observation. It separates an agent '
        'that never had the fact from one that had it and did not use it — '
        'the difference between an app that hides something and an agent that '
        'ignores it, which no other metric here tells apart. Null for tasks '
        'that declare none',
    compute: (ctx) {
      final facts = ctx.task?.requiredFacts ?? const [];
      if (facts.isEmpty) return null;
      final seen = _factsFirstSeen(ctx, facts);
      return seen.values.where((turn) => turn != null).length / facts.length;
    },
  ),
  MetricDefinition(
    name: 'turns_to_all_facts',
    unit: 'count',
    description:
        'The turn by which every required fact had appeared in an '
        'observation — how long the episode spent gathering what it needed. '
        'Null when the task declares no facts, or when one never appeared',
    compute: (ctx) {
      final facts = ctx.task?.requiredFacts ?? const [];
      if (facts.isEmpty) return null;
      final seen = _factsFirstSeen(ctx, facts);
      if (seen.values.any((turn) => turn == null)) return null;
      return seen.values.cast<int>().reduce((a, b) => a > b ? a : b);
    },
  ),
  MetricDefinition(
    name: 'ttft_ms_median',
    unit: 'ms',
    description:
        'Median time to the first generated token over the episode\'s LLM '
        'calls (provider-reported, decision llmFirstTokenMs). What the user '
        'waits before anything happens, as opposed to llm_call_latency_p95, '
        'which is how long the whole answer took. On a local model it is '
        'mostly loading and reading the prompt, so it grows as the re-sent '
        'prefix grows. Null where the provider reports no timing',
    compute: (ctx) {
      final values = <num>[];
      for (final d in ctx.decisions) {
        if (d['llmFirstTokenMs'] case final num ms) values.add(ms);
      }
      return values.isEmpty ? null : Stats.median(values);
    },
  ),
  MetricDefinition(
    name: 'first_call_ttft_ms',
    unit: 'ms',
    description:
        'Time to the first token of the episode\'s first LLM call: what the '
        'user waits before the agent does anything at all. On a local model '
        'it is the prefill of everything before the task line, so it is the '
        'number a warm, shared prefix should shrink. Per call where the agent '
        'records extra.llm, else the first calling decision\'s '
        'llmFirstTokenMs. Null where the provider reports no timing',
    compute: (ctx) {
      for (final d in ctx.decisions) {
        if (_llmCalls(d) case [final first, ...]) return first['firstTokenMs'] as num?;
        if (_asInt(d['llmCalls']) > 0) return d['llmFirstTokenMs'] as num?;
      }
      return null;
    },
  ),
  MetricDefinition(
    name: 'tool_surface_changes',
    unit: 'count',
    description:
        'How often the tool definitions sent to the model changed between one '
        'LLM call and the next. Runtimes that render tools at the top of the '
        'prompt (Ollama for gemma4 and qwen3) prefill the whole conversation '
        'again after each change, 6.5 s against 0.02 s on gemma4:e4b. Null '
        'for agents that record no toolSurface fingerprint',
    compute: (ctx) {
      String? previous;
      var changes = 0;
      var reported = false;
      for (final d in ctx.decisions) {
        for (final call in _llmCalls(d)) {
          if (call['toolSurface'] case final String surface) {
            if (reported && surface != previous) changes++;
            previous = surface;
            reported = true;
          }
        }
      }
      return reported ? changes : null;
    },
  ),
  MetricDefinition(
    name: 'tokens_per_second',
    unit: 'tokens/s',
    description:
        'Completion tokens over the time spent generating them — call time '
        'less time to first token where the provider reports it. On a device '
        'this decides whether a long answer is usable at all. Null without '
        'latency',
    compute: (ctx) {
      var tokens = 0;
      var ms = 0;
      for (final d in ctx.decisions) {
        tokens += (d['tokensCompletion'] as num?)?.toInt() ?? 0;
        ms += ((d['llmLatencyMs'] as num?)?.toInt() ?? 0) - ((d['llmFirstTokenMs'] as num?)?.toInt() ?? 0);
      }
      return tokens == 0 || ms <= 0 ? null : tokens * 1000 / ms;
    },
  ),
  MetricDefinition(
    name: 'memory_peak_bytes',
    unit: 'bytes',
    description:
        'Largest rssBytes a ResourceSampler reported during the episode (J1). '
        'Null where the environment samples nothing',
    compute: (ctx) {
      num? peak;
      for (final e in ctx.trace.byType(TraceEventTypes.resourceSample)) {
        if (e.data['rssBytes'] case final num value) {
          if (peak == null || value > peak) peak = value;
        }
      }
      return peak;
    },
  ),
  MetricDefinition(
    name: 'energy_mj',
    unit: 'mJ',
    description:
        'energyMj at the last sample minus at the first, where the OS keeps a '
        'cumulative counter (J1). Null with fewer than two readings',
    compute: (ctx) {
      final readings = [
        for (final e in ctx.trace.byType(TraceEventTypes.resourceSample))
          if (e.data['energyMj'] case final num value) value,
      ];
      return readings.length < 2 ? null : readings.last - readings.first;
    },
  ),
  MetricDefinition(
    name: 'token_report_ratio',
    unit: 'ratio',
    description:
        'Reported prompt tokens over a characters/4 estimate of what the '
        'agent sent (decision extra.requestChars) (A9). An estimate, not a '
        'tokenizer — JSON and German run nearer three characters a token. It '
        'catches a client under-reporting by a factor, a zero or one call of '
        'several, which the token budget otherwise takes on trust. Null where '
        'the agent reports no request size',
    compute: _tokenReportRatio,
  ),
  MetricDefinition(
    name: 'token_report_discrepancy',
    unit: 'bool',
    description:
        'token_report_ratio outside 0.5–2: the self-reported prompt tokens '
        'that end episodes on budgetTokens do not match what was sent',
    compute: (ctx) {
      final ratio = _tokenReportRatio(ctx);
      return ratio == null ? null : (ratio < 0.5 || ratio > 2 ? 1 : 0);
    },
  ),
  MetricDefinition(
    name: 'auxiliary_token_share',
    unit: 'ratio',
    description:
        'Of the tokens an episode spent, the share that went to roles other '
        'than the main loop — a summariser, a grounding explorer, a checker '
        '(agent-reported in decision extra.roles). A single-loop agent and one '
        'that spends half its budget on sub-agents look identical in '
        'tokens_total, and history compression buys its saving there. Null '
        'for agents that report no roles',
    compute: (ctx) {
      var auxiliary = 0;
      var total = 0;
      var reported = false;
      for (final exchange in ctx.exchanges) {
        final roles = asJsonMap(asJsonMap(asJsonMap(exchange.envelope.data['decision'])['extra'])[AgentDecision.rolesKey]);
        if (roles.isEmpty) continue;
        reported = true;
        for (final entry in roles.entries) {
          final spend = asJsonMap(entry.value);
          final tokens = _asInt(spend['tokensPrompt']) + _asInt(spend['tokensCompletion']);
          total += tokens;
          if (entry.key != AgentDecision.mainRole) auxiliary += tokens;
        }
      }
      if (!reported || total == 0) return null;
      return auxiliary / total;
    },
  ),
  MetricDefinition(
    name: 'auxiliary_calls',
    unit: 'count',
    description:
        'LLM calls an episode made outside its main loop (decision '
        'extra.roles). Null for agents that report no roles',
    compute: (ctx) {
      var calls = 0;
      var reported = false;
      for (final exchange in ctx.exchanges) {
        final roles = asJsonMap(asJsonMap(asJsonMap(exchange.envelope.data['decision'])['extra'])[AgentDecision.rolesKey]);
        if (roles.isEmpty) continue;
        reported = true;
        for (final entry in roles.entries) {
          if (entry.key == AgentDecision.mainRole) continue;
          calls += _asInt(asJsonMap(entry.value)['calls']);
        }
      }
      return reported ? calls : null;
    },
  ),
  MetricDefinition(
    name: 'tool_surface_size',
    unit: 'count',
    description:
        'Mean number of tools offered per LLM request (agent-reported in '
        'decision extra; null for agents that do not report it)',
    compute: (ctx) {
      final counts = [
        for (final exchange in ctx.exchanges)
          if (asJsonMap(asJsonMap(exchange.envelope.data['decision'])['extra'])['tools'] case final num tools) tools,
      ];
      if (counts.isEmpty) return null;
      return counts.reduce((a, b) => a + b) / counts.length;
    },
  ),
  MetricDefinition(
    name: 'llm_roundtrips',
    unit: 'count',
    description: 'Number of LLM calls per episode (self-reported)',
    compute: (ctx) => _sumDecisions(ctx, (d) => _asInt(d['llmCalls'])),
  ),
  ...harmMetrics,
  ...userSimulatorMetrics,
  ...userFeedbackMetrics,
];

/// For each fact, the 1-based turn whose result first contained it, or null.
///
/// Matched as a substring of the encoded result, because a fact is a value and
/// the shape that carries it is the app's business: an id in a hit, in a row
/// or in a form's values is the same fact arriving.
Map<String, int?> _factsFirstSeen(MetricContext context, List<String> facts) {
  final firstSeen = {
    for (final fact in facts) fact: <int?>[null][0],
  };
  var turn = 0;
  for (final exchange in context.exchanges) {
    turn++;
    final result = exchange.result?.data['payload'];
    if (result == null) continue;
    final encoded = jsonEncode(result);
    for (final fact in facts) {
      if (firstSeen[fact] == null && encoded.contains(fact)) {
        firstSeen[fact] = turn;
      }
    }
  }
  return firstSeen;
}
