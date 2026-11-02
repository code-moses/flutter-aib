import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:test/test.dart';

/// P4 — robustness & recovery (§6.4) and `cost_usd` (§6.3).
///
/// AgentBench names long-term reasoning and instruction following as the
/// main obstacles, SPA-Bench names memory and error recovery. None of that
/// is visible in success/tokens/time — these metrics make it visible, and
/// all of them are derived from the trace, so they apply to old runs too.

const _fixture = FixtureRef(
  id: 'seed',
  data: {
    'db': {
      'todos': [
        {'title': 'A', 'completed': false},
      ],
    },
  },
);

TaskSpec _task({int maxSteps = 10}) => TaskSpec(
  id: 't',
  title: 't',
  instruction: 'complete A',
  budget: Budget(maxSteps: maxSteps, maxWallClockSeconds: 30),
  fixture: _fixture,
  groundTruth: const GroundTruth(
    finalState: [
      FinalStateExpectation(query: "db.todos.where(title == 'A')", expectCount: 1, expectFields: {'completed': true}),
    ],
  ),
  successCriteria: const [SuccessCriterion(type: CriterionTypes.finalStateMatch)],
);

Envelope _set(bool completed, {AgentDecision? decision}) => Envelope(
  key: 'state.update',
  kind: .act,
  payload: {
    'path': 'db.todos',
    'where': {'title': 'A'},
    'set': {'completed': completed},
  },
  decision: decision,
);

/// Key the MockEnvironment is configured to fail.
final _broken = Envelope(
  key: 'state.insert',
  kind: .act,
  payload: {
    'path': 'db.todos',
    'item': {'title': 'B'},
  },
);

Future<EpisodeRecord> _run(List<Envelope> script, {Map<String, String> failKeys = const {}, TaskSpec? task, PriceTable? pricing}) async {
  final spec = task ?? _task();
  final result = await BenchmarkEngine().runEpisode(
    task: spec,
    agent: ScriptedAgent(scripts: {spec.id: script}),
    environment: MockEnvironment(failKeys: failKeys),
    meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: spec.id, agentId: 'a', environmentId: 'mock', repetition: 1, startedAt: DateTime.utc(2026)),
  );
  return RunEvaluation(metrics: MetricsRegistry.builtin(pricing: pricing)).evaluateEpisode(result.trace, spec);
}

void main() {
  group('retry_count', () {
    test('counts repeats of something that already failed', () async {
      final record = await _run([_broken, _broken, _broken], failKeys: const {'state.insert': 'nope'});
      expect(record.metrics['failed_envelope_count'], 3);
      expect(record.metrics['retry_count'], 2, reason: 'the first attempt is not a retry');
    });

    test('a different payload is a new attempt, not a retry', () async {
      final record = await _run(
        [
          _broken,
          Envelope(
            key: 'state.insert',
            kind: .act,
            payload: {
              'path': 'db.todos',
              'item': {'title': 'C'},
            },
          ),
        ],
        failKeys: const {'state.insert': 'nope'},
      );
      expect(record.metrics['retry_count'], 0);
    });

    test('repeating something that succeeded is redundancy, not a retry', () async {
      final record = await _run([_set(true), _set(true)]);
      expect(record.metrics['retry_count'], 0);
      expect(record.metrics['redundant_action_ratio'], 0.5, reason: 'the second update changes nothing — that metric sees it');
    });
  });

  group('recovery', () {
    test('a failure followed by success is a recovery', () async {
      final record = await _run([_broken, _set(true)], failKeys: const {'state.insert': 'nope'});
      expect(record.verdict.type, VerdictType.success);
      expect(record.metrics['recovered'], 1);
      expect(record.metrics['recovery_time_ms'], isNotNull);
      expect(record.metrics['recovery_time_ms'], greaterThanOrEqualTo(0));
    });

    test('a failure the agent never gets past is not a recovery', () async {
      final record = await _run([_broken, _broken], failKeys: const {'state.insert': 'nope'});
      expect(record.metrics['recovered'], 0);
      expect(record.metrics['recovery_time_ms'], isNull, reason: 'no state-changing action ever followed the failure');
    });

    test('episodes without a failure report null, not a perfect score', () async {
      final record = await _run([_set(true)]);
      expect(
        record.metrics['recovered'],
        isNull,
        reason:
            'there was nothing to recover from — averaging a 1 in here '
            'would inflate recovery_success_rate',
      );
      expect(record.metrics['failed_envelope_count'], 0);
    });

    test('recovery_success_rate averages only over episodes that failed', () {
      EpisodeRecord record(String id, {num? recovered}) => EpisodeRecord(
        runId: 'r',
        episodeId: id,
        taskId: 't',
        agentId: 'a',
        repetition: 1,
        verdict: Verdict.success(),
        metrics: {'recovered': recovered},
      );
      final rows = Aggregator().aggregate([
        record('e1', recovered: 1),
        record('e2', recovered: 0),
        record('e3'), // never failed
      ]);
      final rate = rows.firstWhere((r) => r.taskId == '*' && r.metric == 'recovery_success_rate');
      expect(rate.n, 2);
      expect(rate.mean, 0.5);
    });
  });

  group('self_correction_count', () {
    test('an action returning the app to an earlier state counts', () async {
      final record = await _run([_set(true), _set(false)]);
      expect(record.metrics['self_correction_count'], 1, reason: 'the second action undid the first');
    });

    test('moving forward only is not a self-correction', () async {
      final record = await _run([_set(true)]);
      expect(record.metrics['self_correction_count'], 0);
    });

    test('a no-op action is redundant, not a correction', () async {
      final record = await _run([_set(true), Envelope(key: 'state.noop', kind: .act)]);
      expect(record.metrics['self_correction_count'], 0);
      expect(record.metrics['redundant_action_ratio'], 0.5);
    });

    test('is null when the environment cannot fingerprint', () {
      // A trace without any state.fingerprint events.
      final trace = EpisodeTrace(
        meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'a', environmentId: 'x', repetition: 1, startedAt: DateTime.utc(2026)),
        events: const [
          TraceEvent(
            seq: 0,
            tUs: 0,
            type: TraceEventTypes.agentEnvelope,
            data: {'seq': 0, 'key': 'k', 'kind': 'act', 'payload': <String, Object?>{}},
          ),
          TraceEvent(seq: 1, tUs: 1, type: TraceEventTypes.episodeEnd, data: {'reason': 'done', 'wallClockMs': 1}),
        ],
      );
      expect(MetricsRegistry.builtin()['self_correction_count']!.compute(MetricContext(trace: trace)), isNull);
    });
  });

  group('what an episode re-sent', () {
    /// The split that separates "ran out of room to think" from "paid nine times for
    /// the same prefix".
    Envelope observe(int prompt, int completion) => Envelope(
      key: 'state.query',
      kind: .observe,
      payload: const {'path': 'db.todos'},
      decision: AgentDecision(model: 'm', tokensPrompt: prompt, tokensCompletion: completion),
    );

    test('a growing conversation is mostly the part that did not grow', () async {
      final record = await _run([observe(1000, 10), observe(1200, 10), observe(1500, 10), _set(true)]);
      // Turn 1 is all new. Turn 2 carries 1000 of its 1200 from turn 1, turn
      // 3 carries 1200 of its 1500. Re-sent: 1000 + 1200 = 2200.
      expect(record.metrics['tokens_resent'], 2200);
      // New prompt content 1000 + 200 + 300, plus every completion token.
      expect(record.metrics['tokens_new'], 1500 + 30);
      // Five, not four: the closing meta.done is a turn like any other — it
      // took an LLM call to decide on it.
      expect(record.metrics['turns'], 5);
    });

    test('a pruned window is counted as re-sent, never as new twice', () async {
      // The observation window drops an old exchange and the prompt shrinks.
      // Calling the shorter request wholly re-sent understates novelty; the
      // alternative would invent it.
      final record = await _run([observe(1000, 0), observe(1500, 0), observe(900, 0), _set(true)]);
      expect(record.metrics['tokens_resent'], 1000 + 900);
      expect(record.metrics['tokens_new'], 1000 + 500);
    });

    test('an episode with no LLM telemetry reports neither', () async {
      final record = await _run([_set(true)]);
      expect(record.metrics['tokens_resent'], isNull);
      expect(record.metrics['tokens_new'], isNull);
    });
  });

  group('cost_usd', () {
    const pricing = PriceTable(
      currency: 'USD',
      asOf: '2026-08-01',
      models: {'claude-sonnet-4-6': ModelPrice(promptPerMTok: 3, completionPerMTok: 15)},
    );

    AgentDecision decision(String model) => AgentDecision(model: model, tokensPrompt: 1000000, tokensCompletion: 100000);

    test('prices prompt and completion tokens separately', () async {
      final record = await _run([_set(true, decision: decision('claude-sonnet-4-6'))], pricing: pricing);
      // 1M prompt × $3 + 0.1M completion × $15 = 3.0 + 1.5
      expect(record.metrics['cost_usd'], closeTo(4.5, 1e-9));
    });

    test('matches versioned model ids by prefix', () async {
      final record = await _run([_set(true, decision: decision('claude-sonnet-4-6-20260214'))], pricing: pricing);
      expect(record.metrics['cost_usd'], closeTo(4.5, 1e-9));
    });

    test('a cached turn is priced by tier, and the write is not free', () async {
      const cachingPrices = PriceTable(
        currency: 'USD',
        asOf: '2026-09-07',
        models: {'claude-sonnet-5': ModelPrice(promptPerMTok: 2, completionPerMTok: 10, cachedPromptPerMTok: 0.2, cacheWritePerMTok: 2.5)},
      );
      final record = await _run([
        _set(
          true,
          decision: const AgentDecision(
            model: 'claude-sonnet-5',
            // 1M prompt = 800k read from cache, 100k written into it, 100k fresh.
            tokensPrompt: 1000000,
            tokensCachedPrompt: 800000,
            tokensCacheWrite: 100000,
            tokensCompletion: 100000,
          ),
        ),
      ], pricing: cachingPrices);

      // 0.1M × $2 + 0.8M × $0.20 + 0.1M × $2.50 + 0.1M × $10
      expect(record.metrics['cost_usd'], closeTo(0.2 + 0.16 + 0.25 + 1.0, 1e-9));
      // Priced at the flat rate the same turn would be $2.00 + $1.00. The
      // saving is real and so is the write: dropping it would have said $1.35.
    });

    test('a table without the cache tiers bills them at the flat rate', () async {
      // What every table written before the tiers existed means. It
      // over-states rather than under-states, which is the safe direction.
      final record = await _run([
        _set(
          true,
          decision: const AgentDecision(
            model: 'claude-sonnet-4-6',
            tokensPrompt: 1000000,
            tokensCachedPrompt: 800000,
            tokensCacheWrite: 100000,
            tokensCompletion: 100000,
          ),
        ),
      ], pricing: pricing);
      expect(record.metrics['cost_usd'], closeTo(4.5, 1e-9));
    });

    test('an unpriced model yields null, not free', () async {
      final record = await _run([_set(true, decision: decision('some-unknown-model'))], pricing: pricing);
      expect(record.metrics['cost_usd'], isNull);
    });

    test('without a pinned table the metric does not exist at all', () async {
      final record = await _run([_set(true, decision: decision('claude-sonnet-4-6'))]);
      expect(record.metrics.containsKey('cost_usd'), isFalse, reason: 'an unpriced run must not look like a free one');
    });

    test('the price table round-trips through the run manifest', () {
      final manifest = RunManifest(
        runId: 'r',
        createdAt: DateTime.utc(2026),
        suiteName: 's',
        suiteHash: 'h',
        agents: const {},
        environmentId: 'mock',
        repetitions: 1,
        seed: 42,
        taskOrder: const [],
        platform: const {},
        extra: {RunManifest.pricingKey: pricing.toJson()},
      );
      final restored = RunManifest.fromJson(manifest.toJson()).pricing!;
      expect(restored.asOf, '2026-08-01');
      expect(restored['claude-sonnet-4-6']!.promptPerMTok, 3);
      expect(RunManifest.fromJson(RunManifest.fromJson(manifest.toJson()).toJson()).pricing, isNotNull);
    });
  });

  group('cross-run readings (§6.4)', () {
    List<EpisodeRecord> run(String agentId, List<double> scores) => [
      for (var i = 0; i < scores.length; i++)
        EpisodeRecord(
          runId: 'r',
          episodeId: 'e$i',
          taskId: 't',
          agentId: agentId,
          repetition: i + 1,
          verdict: Verdict(type: .success, score: scores[i]),
          metrics: {'weighted_score': scores[i]},
        ),
    ];

    test('semantics_degradation_delta is the good-vs-bad Δ with its CI', () {
      final rows = RunComparator(metrics: const ['weighted_score']).compare(run('semantics', [1, 1, 1, 1]), run('semantics', [0, 0, 0.5, 0]));
      final delta = RunComparator.semanticsDegradation(rows, 'semantics')!;
      expect(delta.meanA, 1.0);
      expect(delta.meanB, closeTo(0.125, 1e-9));
      expect(delta.diff, closeTo(-0.875, 1e-9));
      expect(delta.significant, isTrue);
    });

    test('cross_model_variance spreads one agent over N runs', () {
      final variance = RunComparator.crossRunVariance([
        run('semantics', [1, 1]),
        run('semantics', [0.5, 0.5]),
        run('semantics', [0, 0]),
      ], 'semantics')!;
      expect(variance.runs, 3);
      expect(variance.min, 0);
      expect(variance.max, 1);
      expect(variance.stdDev, closeTo(0.5, 1e-9));
    });

    test('a single run has no variance to report', () {
      expect(
        RunComparator.crossRunVariance([
          run('semantics', [1]),
        ], 'semantics'),
        isNull,
      );
    });
  });
}
