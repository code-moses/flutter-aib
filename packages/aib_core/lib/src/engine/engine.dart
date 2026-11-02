import 'dart:async';

import '../common/json.dart';
import '../ports/agent.dart';
import '../ports/envelope.dart';
import '../ports/environment.dart';
import '../task/task.dart';
import '../trace/trace.dart';
import '../ports/user_simulator.dart';
import '../trace/trace_observer.dart';

final class EpisodeRunResult {
  const EpisodeRunResult({required this.trace, required this.outcome, this.finalState});

  final EpisodeTrace trace;
  final EpisodeOutcome outcome;
  final FinalStateSnapshot? finalState;
}

/// The engine is the single clock source of an episode (spec §3.3): agent and
/// environment never talk to each other directly; every exchange flows
/// through [runEpisode] and is recorded as trace events. Only this makes the
/// measurement complete and tamper-proof (P4).
final class BenchmarkEngine {
  BenchmarkEngine({
    this.captureFinalStateTimeout = const Duration(seconds: 30),
    this.milestoneProbeTimeout = const Duration(seconds: 10),
    this.userWaitTimeout = const Duration(minutes: 10),
    this.observer,
    this.userSimulator,
  });

  final Duration captureFinalStateTimeout;

  /// Milestone probes are instrumentation, not agent behaviour: a probe that
  /// exceeds this budget is recorded as an error and the episode continues.
  final Duration milestoneProbeTimeout;

  /// Ceiling for envelopes whose spec declares [EnvelopeSpec.blocksOnUser]. The
  /// wall-clock budget bounds the agent's work, not how long a person takes to
  /// answer.
  final Duration userWaitTimeout;

  /// Live event sink (field traces, OTel spans). Null in the benchmark,
  /// where the trace file is written at the end anyway.
  final TraceObserver? observer;

  /// Follows up after `meta.done` for tasks that declare `userSimulator`. Its
  /// time is taken out of the wall clock, like a person's.
  final UserSimulator? userSimulator;

  Future<EpisodeRunResult> runEpisode({
    required TaskSpec task,
    required BenchmarkAgent agent,
    required BenchmarkEnvironment environment,
    required EpisodeMeta meta,
  }) async {
    final events = <TraceEvent>[];
    final episodeClock = Stopwatch()..start();
    var eventSeq = 0;

    void record(String type, JsonMap data) {
      final event = TraceEvent(seq: eventSeq++, tUs: episodeClock.elapsedMicroseconds, type: type, data: data);
      events.add(event);
      // Instrumentation must never end an episode.
      try {
        observer?.onEvent(meta, event);
      } catch (_) {}
    }

    record(TraceEventTypes.episodeStart, {
      'task': {'id': task.id, 'title': task.title, 'budget': task.budget.toJson()},
      'agent': agent.manifest.toJson(),
    });

    EpisodeOutcome outcome;
    var wallClockMs = 0;
    final fingerprinter = switch (environment) {
      final StateFingerprintProvider provider => provider,
      _ => null,
    };

    // Instrumentation like the probes: out of the wall clock, and a sample
    // that fails or says nothing is skipped rather than ending the episode.
    final sampler = switch (environment) {
      final ResourceSampler resourceSampler => resourceSampler,
      _ => null,
    };
    Future<void> recordResources(int exchangeSeq, [Stopwatch? pause]) async {
      if (sampler == null) return;
      pause?.stop();
      try {
        final sample = await sampler.sampleResources().timeout(milestoneProbeTimeout);
        if (sample.isNotEmpty) {
          record(TraceEventTypes.resourceSample, {...sample, 'seq': exchangeSeq});
        }
      } catch (_) {
      } finally {
        pause?.start();
      }
    }

    // Instrumentation like the probes: out of the wall clock, and a failure gives
    // null rather than ending the episode. Taken and recorded apart because
    // the repeat guard needs the value before the result event it annotates is
    // written.
    Future<String?> takeFingerprint([Stopwatch? pause]) async {
      if (fingerprinter == null) return null;
      pause?.stop();
      try {
        return await fingerprinter.stateFingerprint().timeout(milestoneProbeTimeout);
      } catch (_) {
        return null;
      } finally {
        pause?.start();
      }
    }

    void recordFingerprint(int exchangeSeq, String? fingerprint) {
      if (fingerprinter == null) return;
      record(TraceEventTypes.stateFingerprint, {
        'seq': exchangeSeq,
        if (fingerprint != null) 'fingerprint': fingerprint else 'error': 'fingerprint unavailable',
      });
    }

    // Essential-state probing (§5.2 oracle `stateSequence`): only for tasks
    // that declare milestones — zero cost otherwise. Probing is framework
    // instrumentation, so [pause] takes the probe out of the wall clock and
    // out of the agent's budget, and probe failures never end the episode.
    final milestoneQueries = task.groundTruth.milestoneQueries;
    Future<void> recordProbe(int exchangeSeq, [Stopwatch? pause]) async {
      if (milestoneQueries.isEmpty) return;
      pause?.stop();
      final probeWatch = Stopwatch()..start();
      try {
        final snapshot = await environment.captureFinalState(milestoneQueries).timeout(milestoneProbeTimeout);
        record(TraceEventTypes.stateProbe, {
          'seq': exchangeSeq,
          'probeMs': probeWatch.elapsedMilliseconds,
          'results': snapshot.results.map((r) => r.toJson()).toList(),
        });
      } catch (e) {
        record(TraceEventTypes.stateProbe, {
          'seq': exchangeSeq,
          'probeMs': probeWatch.elapsedMilliseconds,
          'results': const <JsonMap>[],
          'error': e.toString(),
        });
      } finally {
        pause?.start();
      }
    }

    // Setup: reset + discovery + episode start
    try {
      final resetWatch = Stopwatch()..start();
      await environment.reset(task.fixture);
      record(TraceEventTypes.envReset, {'fixture': task.fixture.id, 'resetMs': resetWatch.elapsedMilliseconds});
      recordFingerprint(-1, await takeFingerprint());
      await recordResources(-1);
      final untouchable = task.groundTruth.mustNotChangeQueries;
      if (untouchable.isNotEmpty) {
        final baseline = await environment.captureFinalState(untouchable).timeout(captureFinalStateTimeout);
        record(TraceEventTypes.stateBaseline, baseline.toJson());
      }
      // Initial state: a milestone already satisfied here was not reached by
      // the agent — the evaluator flags it instead of silently crediting it.
      await recordProbe(-1);

      final descriptor = await environment.describe();
      record(TraceEventTypes.envDescriptor, descriptor.toJson());

      await agent.startEpisode(task, descriptor);
      userSimulator?.beginEpisode(task);

      final (loopOutcome, loopWallClockMs) = await _interactionLoop(
        task: task,
        agent: agent,
        environment: environment,
        descriptor: descriptor,
        record: record,
        takeFingerprint: takeFingerprint,
        recordFingerprint: recordFingerprint,
        recordProbe: recordProbe,
        recordResources: recordResources,
      );
      outcome = loopOutcome;
      wallClockMs = loopWallClockMs;
    } catch (e, st) {
      record(TraceEventTypes.engineError, {'error': e.toString(), 'stackTrace': st.toString(), 'phase': 'setup_or_loop'});
      outcome = EpisodeOutcome(reason: .frameworkFault, message: e.toString());
    }

    // --- Final state (also on budget/timeout — evaluation may still find
    //     the goal state reached; see ADR 0003) --------------------------
    FinalStateSnapshot? finalState;
    if (outcome.reason != .frameworkFault || events.any((e) => e.type == TraceEventTypes.envDescriptor)) {
      try {
        finalState = await environment.captureFinalState(task.finalStateQueries).timeout(captureFinalStateTimeout);
        record(TraceEventTypes.finalState, finalState.toJson());
      } catch (e) {
        record(TraceEventTypes.engineError, {'error': e.toString(), 'phase': 'captureFinalState'});
        outcome = EpisodeOutcome(reason: .frameworkFault, message: 'captureFinalState failed: $e');
      }
    }

    record(TraceEventTypes.episodeEnd, {
      'reason': outcome.reason.name,
      if (outcome.message != null) 'message': outcome.message,
      'wallClockMs': wallClockMs,
    });

    try {
      await agent.endEpisode(outcome);
    } catch (e) {
      record(TraceEventTypes.engineError, {'error': e.toString(), 'phase': 'endEpisode'});
    }

    final trace = EpisodeTrace(meta: meta, events: events);
    try {
      observer?.onEpisodeEnd(meta, trace);
    } catch (_) {}

    return EpisodeRunResult(trace: trace, outcome: outcome, finalState: finalState);
  }

  /// Whether [task]'s final state holds right now; null without one, or
  /// when the environment cannot answer.
  Future<bool?> _goalMet(TaskSpec task, BenchmarkEnvironment environment) async {
    final expectations = task.groundTruth.finalState;
    if (expectations.isEmpty) return null;
    try {
      final snapshot = await environment.captureFinalState([for (final e in expectations) StateQuery(e.query)]).timeout(milestoneProbeTimeout);
      return expectations.every((e) => e.mismatch(snapshot.resultFor(e.query)) == null);
    } catch (_) {
      return null;
    }
  }

  Future<(EpisodeOutcome, int)> _interactionLoop({
    required TaskSpec task,
    required BenchmarkAgent agent,
    required BenchmarkEnvironment environment,
    required EnvironmentDescriptor descriptor,
    required void Function(String type, JsonMap data) record,
    required Future<String?> Function([Stopwatch? pause]) takeFingerprint,
    required void Function(int exchangeSeq, String? fingerprint) recordFingerprint,
    required Future<void> Function(int exchangeSeq, [Stopwatch? pause]) recordProbe,
    required Future<void> Function(int exchangeSeq, [Stopwatch? pause]) recordResources,
  }) async {
    final budget = task.budget;
    final maxWallClockMs = budget.maxWallClockSeconds * 1000;
    // Wall clock runs from end-of-reset to the verdict-ready end state
    // (metric definition §6.2); reset happened just before this call.
    final wallClock = Stopwatch()..start();

    final blocksOnUser = {
      for (final spec in descriptor.envelopes)
        if (spec.blocksOnUser) spec.key,
    };

    var stepsUsed = 0; // act-envelopes, meta.* excluded (ADR 0002)
    var tokensUsed = 0;
    var turnsUsed = 0;
    // The turn budget counts decisions, not envelopes: a prefetch is emitted
    // without the model being asked. `cancelAtTurn` keeps counting every
    // envelope, because a user pressing stop stops what happened.
    var decisionTurns = 0;
    var exchangeSeq = 0;
    // Time the episode spent waiting for a human, excluded from the wall
    // clock so that asking is not more "expensive" than guessing.
    var userWaitMs = 0;
    var turnsAnswered = 0;
    var followUps = 0;
    var steered = 0;
    EnvelopeResult? lastResult;

    // No-progress guard. An envelope that comes back byte-identical taught the
    // agent nothing, so the engine substitutes a short notice and ends the
    // episode once one signature has done it too often.
    //
    // For acts the state fingerprint is part of the identity, because an act's
    // result is usually a bare acknowledgement. An environment that cannot
    // fingerprint never has its acts suppressed: four scrolls down a list are
    // four scrolls, not a loop.
    final lastResultFingerprint = <String, String>{};
    final repeatCount = <String, int>{};
    // Same answer to a different question: an agent that varies its parameters
    // gets a fresh signature each time while the app hands back the identical
    // document. Counted in distinct signatures, so a literal repeat is not
    // counted twice.
    final answerSignatures = <String, Set<String>>{};
    var suppressedRepeats = 0;

    int elapsed() => wallClock.elapsedMilliseconds - userWaitMs;

    void recordSimulated(int seq) {
      for (final entry in userSimulator?.drain() ?? const <JsonMap>[]) {
        record(TraceEventTypes.userSimulated, {'seq': seq, ...entry});
      }
    }

    (EpisodeOutcome, int) finish(TerminationReason reason, [String? message]) {
      return (EpisodeOutcome(reason: reason, message: message), elapsed());
    }

    while (true) {
      final elapsedMs = elapsed();
      if (elapsedMs >= maxWallClockMs) {
        return finish(TerminationReason.timeout, 'wall clock budget of ${budget.maxWallClockSeconds}s exhausted');
      }
      if (stepsUsed >= budget.maxSteps) {
        return finish(TerminationReason.budgetSteps, 'step budget of ${budget.maxSteps} act-envelopes exhausted');
      }
      final maxTokens = budget.maxTokens;
      if (maxTokens != null && tokensUsed >= maxTokens) {
        return finish(TerminationReason.budgetTokens, 'token budget of $maxTokens exhausted (self-reported)');
      }
      final maxTurns = budget.maxTurns;
      if (maxTurns != null && decisionTurns >= maxTurns) {
        return finish(TerminationReason.budgetTurns, 'turn budget of $maxTurns envelopes exhausted');
      }
      final cancelAt = task.cancelAtTurn;
      if (cancelAt != null && turnsUsed >= cancelAt) {
        return finish(TerminationReason.cancelled, 'stopped by the user after $cancelAt envelope(s)');
      }

      final status = BudgetStatus(
        stepsUsed: stepsUsed,
        maxSteps: budget.maxSteps,
        elapsedMs: elapsedMs,
        maxWallClockMs: maxWallClockMs,
        tokensUsed: tokensUsed,
        maxTokens: maxTokens,
        turnsUsed: decisionTurns,
        maxTurns: maxTurns,
      );

      final remaining = Duration(milliseconds: maxWallClockMs - elapsedMs);
      final Envelope envelope;
      try {
        envelope = await agent.next(lastResult, status).timeout(remaining);
      } on TimeoutException {
        return finish(TerminationReason.timeout, 'agent.next exceeded remaining wall clock budget');
      }

      tokensUsed += envelope.decision?.tokensTotal ?? 0;
      turnsUsed++;
      if (envelope.decision?.isPrefetch != true) decisionTurns++;
      record(TraceEventTypes.agentEnvelope, {
        'seq': exchangeSeq,
        'key': envelope.key,
        'kind': envelope.kind.name,
        'payloadBytes': jsonSizeBytes(envelope.payload),
        'payload': envelope.payload,
        'decision': ?envelope.decision?.toJson(),
      });

      if (envelope.isDone) {
        // A follow-up continues the same episode: the app keeps what the
        // previous turn left, which is what makes "and now the other one"
        // answerable at all.
        if (turnsAnswered < task.turns.length) {
          final follow = task.turns[turnsAnswered++];
          record(TraceEventTypes.userTurn, {
            'seq': exchangeSeq,
            'id': follow.id,
            'instruction': follow.instruction,
            'after': envelope.payload['summary'],
          });
          lastResult = EnvelopeResult.ok({'user': follow.instruction, 'turn': follow.id});
          exchangeSeq++;
          continue;
        }
        final simulator = userSimulator;
        if (simulator != null && simulator.isActive && followUps < (task.userSimulator?.maxFollowUps ?? 0)) {
          wallClock.stop();
          final String? message;
          try {
            message = await simulator.followUp(envelope.payload['summary'] as String?, goalMet: await _goalMet(task, environment));
          } finally {
            wallClock.start();
          }
          recordSimulated(exchangeSeq);
          if (message != null) {
            followUps++;
            record(TraceEventTypes.userTurn, {
              'seq': exchangeSeq,
              'id': 'simulated-$followUps',
              'instruction': message,
              'after': envelope.payload['summary'],
              'simulated': true,
            });
            lastResult = EnvelopeResult.ok({'user': message, 'turn': 'simulated-$followUps'});
            exchangeSeq++;
            continue;
          }
        }
        return finish(TerminationReason.done, envelope.payload['summary'] as String?);
      }
      if (envelope.isAbort) {
        return finish(TerminationReason.abort, envelope.payload['reason'] as String? ?? 'aborted');
      }

      final handleWatch = Stopwatch()..start();
      final mayBlock = blocksOnUser.contains(envelope.key);
      final remainingHandleMs = maxWallClockMs - elapsed();
      final handleTimeout = mayBlock ? userWaitTimeout : Duration(milliseconds: remainingHandleMs < 1 ? 1 : remainingHandleMs);
      final EnvelopeResult result;
      try {
        result = await environment.handle(envelope).timeout(handleTimeout);
      } on TimeoutException {
        return finish(
          TerminationReason.timeout,
          mayBlock
              ? 'env.handle waited longer than ${userWaitTimeout.inSeconds}s '
                    'for a user answer'
              : 'env.handle exceeded remaining wall clock budget',
        );
      }
      // Only envelopes that declared they may block are allowed to discount
      // time; otherwise a slow handler could hide behind the field.
      final waited = mayBlock ? (result.userWaitMs ?? 0) : 0;
      userWaitMs += waited;
      final handleMs = handleWatch.elapsedMilliseconds - waited;

      final fingerprint = await takeFingerprint(wallClock);

      // A prefetch is not the agent's choice, so re-requesting what it
      // fetched is not a repeat.
      final prefetch = envelope.decision?.isPrefetch ?? false;
      final isAct = envelope.kind == .act;
      final guarded = !prefetch && (!isAct || fingerprint != null);
      final signature = '${envelope.key}#${jsonFingerprint(envelope.payload)}';
      // Timing is deliberately not part of it: two calls that differ only in
      // how long they took are the same answer.
      final resultFingerprint = jsonFingerprint({
        'status': result.status.name,
        'payload': result.payload,
        'error': result.error?.toJson(),
        if (isAct) 'state': fingerprint,
      });
      final repeats = guarded && lastResultFingerprint[signature] == resultFingerprint ? (repeatCount[signature] ?? 0) + 1 : 0;
      if (guarded) {
        lastResultFingerprint[signature] = resultFingerprint;
        repeatCount[signature] = repeats;
      }
      // Off means off: a task that polls for an external change needs the real
      // answer every time, not a notice that it looks like the last one.
      final maxRepeats = budget.maxIdenticalRepeats;
      final suppress = maxRepeats != null && repeats > 0;
      final answerKey = '${envelope.key}#$resultFingerprint';
      final askedWith = guarded ? (answerSignatures[answerKey] ??= <String>{}) : <String>{};
      final newQuestion = guarded && askedWith.add(signature);
      final distinctQuestions = askedWith.length;
      // Only when the signature guard has nothing to say: it already tells a
      // literal repeat what it is, and two notices for one call would be the
      // circle described twice.
      final sameAnswerDifferentQuestion = !suppress && newQuestion && maxRepeats != null && distinctQuestions > maxRepeats;

      // The trace keeps what the environment actually said, whatever the agent
      // was handed — it is the record of the run, not of the agent's view.
      record(TraceEventTypes.envResult, {
        'seq': exchangeSeq,
        'status': result.status.name,
        'payloadBytes': jsonSizeBytes(result.payload),
        'payload': result.payload,
        'handleMs': handleMs,
        if (waited > 0) 'userWaitMs': waited,
        'error': ?result.error?.toJson(),
        if (repeats > 0) 'repeatIndex': repeats,
        if (suppress) 'suppressed': true,
        if (newQuestion && distinctQuestions > 1) 'answerIndex': distinctQuestions - 1,
        if (sameAnswerDifferentQuestion) 'sameAnswer': true,
      });
      recordFingerprint(exchangeSeq, fingerprint);
      await recordProbe(exchangeSeq, wallClock);
      await recordResources(exchangeSeq, wallClock);
      recordSimulated(exchangeSeq);

      if (envelope.kind == .act && !envelope.isMeta) {
        stepsUsed++;
      }

      // The user speaks while the agent works: due once enough app actions
      // happened, heard with the next result.
      while (steered < task.steering.length && stepsUsed >= task.steering[steered].afterActions) {
        final steer = task.steering[steered++];
        final steerable = agent is SteerableAgent;
        if (agent case final SteerableAgent hearing) hearing.steer(steer.message, id: steer.id);
        record(TraceEventTypes.userSteer, {'seq': exchangeSeq, ...steer.toJson(), 'delivered': steerable});
      }

      if (maxRepeats != null && repeats > maxRepeats) {
        record(TraceEventTypes.noProgress, {'seq': exchangeSeq, 'key': envelope.key, 'repeats': repeats, 'suppressedRepeats': suppressedRepeats});
        return finish(
          TerminationReason.noProgress,
          '"${envelope.key}" returned the same result ${repeats + 1} times; '
          'the episode stopped making progress',
        );
      }

      if (suppress) {
        suppressedRepeats++;
        // Short on purpose. The agent already has this answer verbatim, so
        // repeating it costs context and adds nothing; what it is missing is
        // the fact that it is going in a circle.
        lastResult = EnvelopeResult.failed(
          'no_progress',
          'Identical to the answer "${envelope.key}" already gave you '
              '$repeats time(s) with these exact parameters. Repeating it will '
              'not change anything — do something different, or finish with '
              'meta.done or meta.abort.',
        );
      } else if (sameAnswerDifferentQuestion) {
        suppressedRepeats++;
        lastResult = EnvelopeResult.failed(
          'no_progress',
          '"${envelope.key}" has now returned this exact document for '
              '$distinctQuestions different parameter sets. Varying the '
              'parameters is not reaching anything new — this is all it has. '
              'Use it, try a different capability, or finish with meta.done or '
              'meta.abort.',
        );
      } else {
        lastResult = result;
      }
      exchangeSeq++;
    }
  }
}
