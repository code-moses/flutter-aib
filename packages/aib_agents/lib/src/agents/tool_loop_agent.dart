import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:aib_core/ports.dart';
import 'package:aib_jev/aib_jev.dart';

import '../llm/constrained_tool_calls.dart';
import '../llm/embedding_client.dart';
import '../llm/llm_client.dart';
import '../routing/model_router.dart';
import 'agent_config.dart';
import 'compaction.dart';
import 'decisions.dart';

/// Shared base of all LLM reference agents (spec §7): same prompt skeleton,
/// same loop logic, same telemetry capture — subclasses differ *only* in
/// envelope keys, tool set and system prompt. That symmetry is what makes
/// the comparison between interaction strategies fair.
///
/// Loop contract with the engine (spec §4.3): every `next()` returns exactly
/// one envelope. Internally the agent maintains an LLM conversation:
///
///  1. First `next(null)`: emit the deterministic bootstrap observation
///     (no LLM call — saves tokens, makes episode openings comparable).
///  2. Each result is fed back — as a tool-result message if the envelope
///     came from a tool call, as a user message for the bootstrap.
///  3. When no queued tool calls remain, call the LLM. Tool calls map to
///     envelopes (one per `next()`); `done`/`abort` map to `meta.*`. A turn
///     with no tool call is nudged, and only taken as `meta.done` once the
///     retries are spent (ADR 0011).
///  4. A result after `meta.done` is the user's follow-up: it
///     answers the `done` call and continues the same conversation.
///
/// Self-reported telemetry ([AgentDecision]) aggregates all LLM calls made
/// within one `next()` step and rides on the emitted envelope (spec §4.3).
abstract base class ToolLoopAgent implements BenchmarkAgent, AgentWarmUp, AgentModelIdentity, SteerableAgent {
  ToolLoopAgent({required this.client, this.config = const AgentConfig(), this.configBlocks = const {}, this.embeddingClient, this.decisions}) {
    // A client that ignores the schema would run this arm unconstrained and
    // record it as constrained — a number nobody could attribute. Refused here,
    // at build time, not discovered as a strangely ordinary result.
    if (config.toolCalling == .constrained && !client.honoursResponseSchema) {
      throw ArgumentError(
        'agent.toolCalling: constrained needs a client that honours a response schema, and ${client.runtimeType} (${client.model}) does not — '
        'Ollama does; hosted providers enforce a tool\'s schema natively',
      );
    }
  }

  final LlmClient client;

  /// For retrieval; its model is pinned in the manifest like [client]'s.
  final EmbeddingClient? embeddingClient;

  /// A decision model in the loop (the `decisions:` block): the completion
  /// check before `done`, the guard before an act, and — for a preparing
  /// agent — relevance selection. Null for an agent that asks none.
  final AgentDecisions? decisions;

  /// The knobs that change what is measured (see [AgentConfig]); recorded in
  /// the manifest.
  final AgentConfig config;

  /// Called with each piece of assistant text as it is produced, when the
  /// client can stream and a caller asked to see it. A benchmark does not set
  /// it, and then nothing streams.
  void Function(String delta)? onTextDelta;

  /// Cancels the in-flight LLM call, if any, so closing the assistant does not
  /// leave a request running.
  void cancel([String reason = 'cancelled']) => _cancellation?.cancel(reason);

  CancellationToken? _cancellation;

  // Subclass surface (the *only* things that differ per strategy)

  String get agentId;

  /// Version of the frozen prompt, recorded in the manifest (spec §11 Phase 3).
  String get promptVersion;

  String get systemPrompt;

  /// Tools currently offered to the model (IntentAgent extends this after
  /// catalog discovery). `done`/`abort` are appended by the base class.
  List<LlmTool> get strategyTools;

  /// Deterministic first observation (before any LLM call); null = none.
  Envelope? bootstrapEnvelope();

  /// Envelopes emitted back to back before the first LLM call, each marked
  /// `prefetch`. Each result goes to [onPlanResult]. Defaults to
  /// [bootstrapEnvelope] alone.
  List<Envelope> bootstrapPlan() => [?bootstrapEnvelope()];

  /// How a plan result enters the conversation; a preparing agent digests it.
  ///
  /// Both the raw [result] and its [rendered] form: the rendering is what the
  /// model may read, while retrieval has to see everything the environment
  /// published.
  ///
  /// Awaited, because a preparer may call an embedding model here.
  FutureOr<void> onPlanResult(Envelope sent, EnvelopeResult result, String rendered) {
    _messages.add(LlmMessage.user('Initial observation:\n$rendered'));
  }

  /// Appends to the plan while it is still draining, so one step may be
  /// decided from an earlier step's result — the preparer picks the intents to
  /// describe out of the catalogue it has just read. Still before the first
  /// LLM call, so the addition costs a turn and no tokens.
  void enqueuePlan(Iterable<Envelope> envelopes) => _plan.addAll(envelopes);

  /// Planned envelopes not yet emitted; 0 means the next `next()` asks the
  /// model.
  int get plannedRemaining => _plan.length;

  /// Puts one message into the conversation (the preparer's briefing).
  void addUserMessage(String content) => _messages.add(LlmMessage.user(content));

  /// Maps a strategy tool call to an envelope; null = unknown tool.
  Envelope? mapToolCall(LlmToolCall call);

  /// Hook: inspect results (e.g. IntentAgent builds tools from the catalog).
  void onResult(Envelope sent, EnvelopeResult result) {}

  /// Whether this result stays in full however old it gets: one that is the
  /// only place a schema is written down. Stubbing it would leave the model
  /// calling an intent whose parameters it can no longer read.
  bool pinsResult(Envelope sent, EnvelopeResult result) => false;

  /// Subclass hook: annotation for the envelope about to be emitted,
  /// merged into `AgentDecision.note`. Read once per envelope.
  String? get pendingNote => null;

  /// Subclass hook: structured facts about the envelope about to be emitted,
  /// merged into `AgentDecision.extra`. Facts only — what the agent did,
  /// never what it was worth. Read once per envelope.
  JsonMap get pendingExtra => const {};

  /// Renders an envelope result for the model.
  String describeResult(Envelope sent, EnvelopeResult result) {
    if (result.status != .ok) {
      return jsonEncode({'status': result.status.name, 'error': ?result.error?.toJson()});
    }
    return jsonEncode(result.payload);
  }

  // Base implementation

  static const _doneTool = LlmTool(
    name: 'done',
    description:
        'Signal that the task is completed. Call this exactly once, '
        'after verifying the goal state was reached.',
    parameters: {
      'type': 'object',
      'properties': {
        'summary': {'type': 'string', 'description': 'What was achieved.'},
      },
    },
  );

  /// [_doneTool] with the instruction that decides the answer to a question: the
  /// summary is the answer. Without it a model that has read "27" in a result
  /// tends to close with "Task completed", which a rubric scores as no answer.
  static const _doneToolWithExample = LlmTool(
    name: 'done',
    description:
        'Signal that the task is completed. Call this exactly once, '
        'after verifying the goal state was reached.',
    parameters: {
      'type': 'object',
      'properties': {
        'summary': {
          'type': 'string',
          'description':
              'What was achieved. For a question, the answer itself with its '
              'concrete values, in the user\'s language — e.g. "Acme GmbH has 4 '
              'overdue invoices." — not "done".',
        },
      },
    },
  );

  /// Both nudges go out in the `user` role, the only role every provider keeps
  /// in place (Anthropic hoists system messages to the front of the prompt).
  /// The text says who is speaking, so a model does not read it as the person
  /// it is helping.
  static const _emptyTurnNudge =
      '[benchmark runner, not the user] That turn arrived empty — no text and '
      'no tool call — so nothing ran. Reply with exactly one call to one of '
      'the listed tools, using its exact name, or with done or abort.';

  static const _noToolCallNudge =
      '[benchmark runner, not the user] That turn contained no tool call, so '
      'nothing ran and the app is unchanged. Reply with exactly one call to '
      'one of the listed tools, using its exact name. If the task is '
      'finished, that call is done, with your answer in its summary.';

  static const _abortTool = LlmTool(
    name: 'abort',
    description:
        'Give up on the task. Only call this when the task is impossible '
        'with the available capabilities.',
    parameters: {
      'type': 'object',
      'properties': {
        'reason': {'type': 'string'},
      },
      'required': ['reason'],
    },
  );

  final List<LlmMessage> _messages = [];
  final Queue<LlmToolCall> _queuedCalls = Queue();
  (Envelope envelope, LlmToolCall? sourceCall)? _lastSent;
  final Queue<Envelope> _plan = Queue();
  var _lastRequestChars = 0;
  TaskSpec? _task;

  /// Agent-config sections the framework does not interpret (`preparation:`,
  /// `speech:`, …), hashed into the manifest like `router:`.
  final JsonMap configBlocks;

  /// Extra manifest entries a subclass wants recorded (the hybrid agent adds
  /// its router config hash here).
  JsonMap get manifestMetadata => const {};

  @override
  AgentManifest get manifest => AgentManifest(
    agentId: agentId,
    version: promptVersion,
    description: 'LLM reference agent ($agentId, prompt $promptVersion)',
    metadata: {
      'model': client.model,
      'temperature': config.supportsTemperature ? config.temperature : null,
      'promptVersion': promptVersion,
      // The three fields the release gate compares between the shipped agent
      // and the benchmarked one. Free-form metadata
      // was not comparable: there was nothing agreed to compare.
      'promptHash': configHash(systemPrompt),
      'agentConfigHash': configHash(config.identity),
      'agentConfig': config.toJson(),
      if (client case final LlmContextWindow window) 'contextWindow': window.contextTokens,
      if (embeddingClient case final embedding?) 'embeddingModel': embedding.model,
      if (decisions case final decisions?) 'decisionModel': decisions.client.model,
      if (configBlocks.isNotEmpty)
        'configBlocks': {
          for (final entry in configBlocks.entries) entry.key: {'hash': configHash(entry.value), 'config': entry.value},
        },
      ...manifestMetadata,
    },
  );

  @override
  Future<void> startEpisode(TaskSpec task, EnvironmentDescriptor environment) async {
    _task = task;
    _environment = environment;
    _firstRequestTools = null;
    _compactor?.reset();
    _cancellation = CancellationToken();
    _truncatedResults = 0;
    _lastTurnTokens = 0;
    _messages
      ..clear()
      ..add(LlmMessage.system(_systemMessageFor(environment)))
      ..add(LlmMessage.user(_episodeBriefing(task, environment)));
    _taskPending = taskLineLast;
    _steering.clear();
    _pinned.clear();
    _queuedCalls.clear();
    _lastSent = null;
    _pendingRecords.clear();
    _pendingSideCalls.clear();
    _completionRejections = 0;
    _confirmation = null;
    _decisionLanguage = decisions?.languageFor(task.instruction) ?? 'en';
    _plan
      ..clear()
      ..addAll(bootstrapPlan());
    // A routed client picks its model before the first call, on the
    // instruction alone; the decision rides on the episode's first decision.
    _routeDecision = switch (client) {
      final ModelRouter router => await router.beginEpisode(task.instruction, cancellation: _cancellation),
      _ => null,
    };
  }

  /// Not yet recorded in the trace; cleared once it is.
  RouteDecision? _routeDecision;

  /// Steering messages not yet in the conversation.
  final List<String> _steering = [];

  /// Says who is speaking: the user, not the runner, and mid-task.
  static const steeringHeading = '[the user, while you were working]';

  @override
  void steer(String message, {required String id}) => _steering.add(message);

  /// Under [ToolSurface.fixed] the conversation is laid out for a local
  /// server's prompt cache: the task line after the bootstrap observations, no
  /// budget line on plan results.
  bool get _cachedPrefix => config.toolSurface == .fixed;

  /// Whether the task line goes after the bootstrap observations (or a
  /// briefing) instead of first. Under [ToolSurface.fixed] always; a subclass
  /// with its own cache-friendly layout turns it on too.
  bool get taskLineLast => _cachedPrefix;

  /// The task line, owed to the conversation until the first model call. It
  /// goes after the briefing and the bootstrap observations, so everything
  /// before it is shared between tasks and a local server's prompt cache
  /// carries it over.
  bool _taskPending = false;

  /// Tool results the observation window must not stub ([pinsResult]).
  final Set<LlmMessage> _pinned = Set.identity();

  /// [systemPrompt] with the instance's own text after it (ADR 0018).
  ///
  /// After, never instead: the frozen prompt stays a byte-identical prefix, so
  /// [manifest]'s `promptHash` keeps naming it and a provider's prompt cache
  /// keeps hitting across instances up to this point.
  String systemPromptFor(EnvironmentDescriptor environment) {
    final instructions = environment.instructions;
    if (!config.environmentInstructions || instructions == null) return systemPrompt;
    return '$systemPrompt\n\n$instanceHeading\n$instructions';
  }

  /// Whether the environment's envelope listing goes into the system message
  /// instead of the first user message. For a layout whose tools differ per
  /// task: a runtime that renders the tools after the system message (Ollama)
  /// can then reuse the listing from one task to the next.
  bool get listingInSystem => false;

  /// The system message: [systemPromptFor], then the envelope listing when
  /// [listingInSystem].
  String _systemMessageFor(EnvironmentDescriptor environment) =>
      listingInSystem ? '${systemPromptFor(environment)}\n\n${_envelopeListing(environment)}' : systemPromptFor(environment);

  /// Marks where the frozen prompt ends and the app's text begins. Says who
  /// wrote what follows, so a model does not read it as the task.
  static const instanceHeading =
      '## About this app instance\n'
      'Published by the app for every task on this installation. It describes '
      'the instance, not the current task; tool results stay authoritative.';

  String _envelopeListing(EnvironmentDescriptor environment) => [
    'Environment "${environment.environmentId}" supports these '
        'envelope keys:',
    for (final spec in environment.envelopes)
      '- ${spec.key}'
          '${spec.kind == null ? '' : ' (${spec.kind!.name})'}'
          '${spec.description == null ? '' : ': ${spec.description}'}',
  ].join('\n');

  String _episodeBriefing(TaskSpec task, EnvironmentDescriptor environment) => [
    if (!taskLineLast) ...['Task: ${task.instruction}', ''],
    if (!listingInSystem) ...[_envelopeListing(environment), ''],
    'Budget: max ${task.budget.maxSteps} actions, '
        '${task.budget.maxWallClockSeconds}s wall clock'
        '${task.budget.maxTokens == null ? '' : ', ${task.budget.maxTokens} tokens'}.',
  ].join('\n');

  @override
  Future<Envelope> next(EnvelopeResult? lastResult, BudgetStatus budget) async {
    final step = _Step();
    if (_confirmation case final held? when lastResult != null) {
      _confirmation = null;
      _lastSent = null;
      if (_confirmed(lastResult)) {
        _lastSent = (held.action, held.call);
        return _withDecision(step, held.action, note: 'guard=confirmed');
      }
      _addDeclinedConfirmation(held.call, lastResult);
    } else if (lastResult != null) {
      await _feedBack(lastResult, budget);
    }

    if (_plan.isNotEmpty) {
      final planned = _plan.removeFirst();
      _lastSent = (planned, null);
      return _withDecision(step, planned, note: 'bootstrap', prefetch: true);
    }

    if (_taskPending) {
      _taskPending = false;
      _messages.add(LlmMessage.user('Task: ${_task?.instruction ?? ''}'));
    }

    // What the user said while the agent worked goes in before the model is
    // asked again, after every pending tool result, which providers need to
    // follow their calls directly.
    if (_steering.isNotEmpty && _queuedCalls.isEmpty) {
      for (final message in _steering) {
        _messages.add(LlmMessage.user('$steeringHeading\n$message'));
      }
      _steering.clear();
    }

    // Queued calls drain before the model is asked again: providers require all
    // tool results before the next assistant turn, and _emitCall has already
    // answered unknown tools with an error result.
    if (await _drainQueue() case final envelope?) return _withDecision(step, envelope);
    return _askModel(step);
  }

  /// The guard asked the user about an action and they did not confirm it.
  void _addDeclinedConfirmation(LlmToolCall call, EnvelopeResult answer) {
    _messages.add(
      LlmMessage.toolResult(
        callId: call.id,
        name: call.name,
        content: jsonEncode({
          'status': 'failed',
          'error':
              'The user was asked to confirm this action and did not — nothing ran. '
              'Do not repeat it unless the user asks for it again.',
          if (answer.status == .ok) 'answer': answer.payload['answer'],
        }),
      ),
    );
  }

  /// Puts the result of the previously emitted envelope into the conversation.
  Future<void> _feedBack(EnvelopeResult result, BudgetStatus budget) async {
    final last = _lastSent;
    if (last == null) return;
    final (sent, sourceCall) = last;
    if (sent.isDone) {
      _acceptFollowUp(sourceCall, result, budget);
      _lastSent = null;
      return;
    }
    onResult(sent, result);
    // Under the fixed surface a plan result has no budget line: its elapsed
    // seconds would make otherwise identical prefixes differ.
    final rendered = sourceCall == null && _cachedPrefix ? describeResult(sent, result) : '${describeResult(sent, result)}\n${_budgetLine(budget)}';
    if (sourceCall != null) {
      final message = LlmMessage.toolResult(callId: sourceCall.id, name: sourceCall.name, content: rendered);
      if (pinsResult(sent, result)) _pinned.add(message);
      _messages.add(message);
    } else {
      await onPlanResult(sent, result, rendered);
    }
    _lastSent = null;
  }

  /// The first queued call that maps to an envelope, or null when none does.
  Future<Envelope?> _drainQueue() async {
    while (_queuedCalls.isNotEmpty) {
      if (await _emitCall(_queuedCalls.removeFirst()) case final envelope?) return envelope;
    }
    return null;
  }

  /// LLM turns until a mappable tool call or a termination appears.
  Future<Envelope> _askModel(_Step step) async {
    var lastFailure = 'model kept calling unknown tools';
    // Where the previous unusable (assistant, nudge) pair starts, so it can be
    // dropped: keeping every one hands the model examples of the behaviour the
    // nudge asks it to stop.
    int? staleFrom;
    for (var attempt = 0; attempt <= config.maxUnknownToolRetries; attempt++) {
      LlmResponse response;
      final watch = Stopwatch()..start();
      try {
        response = await _complete();
      } on LlmClientException catch (e) {
        // Classified, not just quoted: "the context window overflowed" and "the
        // agent gave up" are opposite findings. The loop wrote this, not the
        // model, so no rubric judges it as a claim.
        return _withDecision(
          step,
          Envelope.abort(reason: 'llm_error:${e.kind.name}: ${e.message}'),
          note: 'llm_error reason=${e.kind.name}',
          byHarness: true,
        );
      } finally {
        step.latencyMs += watch.elapsedMilliseconds;
      }
      step.record(response, toolCount: _lastToolCount, requestChars: _lastRequestChars);
      final raw = response;
      if (config.toolCalling == .constrained) response = ConstrainedToolCalls.decode(response);
      final called = [for (final call in response.toolCalls) call.name];
      // One call per turn is the loop's contract. A provider that has no switch
      // for it or ignores it answers with several, and running them back to back
      // would act on state the model never saw.
      var dropped = 0;
      if (config.parallelToolCalls == false && response.toolCalls.length > 1) {
        dropped = response.toolCalls.length - 1;
        response = response.copyWith(toolCalls: [response.toolCalls.first]);
        _droppedParallel += dropped;
      }
      step.turns.add(_llmTurn(raw, called, dropped));
      var assistantAt = _messages.length;
      _messages.add(LlmMessage.assistant(response.text, toolCalls: response.toolCalls));

      if (response.toolCalls.isEmpty) {
        final String nudge;
        if (response.text.trim().isEmpty) {
          // Neither text nor a tool call: an empty turn, not a decision. Ollama,
          // for instance, drops tool calls whose name is not in the tool list.
          // Nudge and let the retry budget decide.
          lastFailure = 'model returned an empty response';
          nudge = _emptyTurnNudge;
        } else if (attempt < config.maxUnknownToolRetries) {
          // Text, no tool call. Not a decision either (ADR 0011): a reasoning
          // model narrates its plan in `content`, and taking that as `done`
          // would end the episode on its first thought.
          lastFailure = 'model answered with prose instead of a tool call';
          nudge = _noToolCallNudge;
        } else {
          // Prose every time it was asked for a tool. It is all there is, so it
          // is the answer, and the note says how it was arrived at.
          final done = Envelope.done(summary: response.text);
          _lastSent = (done, null);
          return _withDecision(step, done, note: 'text_termination attempts=${attempt + 1}');
        }

        if (staleFrom != null) {
          _messages.removeRange(staleFrom, assistantAt);
          assistantAt = staleFrom;
        }
        _messages.add(LlmMessage.user(nudge));
        staleFrom = assistantAt;
        continue;
      }
      // A usable turn: the history is coherent again and nothing is stale.
      staleFrom = null;
      _queuedCalls.addAll(response.toolCalls);
      if (await _drainQueue() case final envelope?) return _withDecision(step, envelope);
      // No call of this turn was usable; the loop told the model via tool results.
      lastFailure = 'model kept making unusable tool calls';
    }
    return _withDecision(
      step,
      Envelope.abort(reason: '$lastFailure (${config.maxUnknownToolRetries} retries)'),
      note: 'no_usable_response',
      byHarness: true,
    );
  }

  Envelope _withDecision(_Step step, Envelope envelope, {String? note, bool prefetch = false, bool byHarness = false}) => Envelope(
    key: envelope.key,
    kind: envelope.kind,
    payload: envelope.payload,
    decision: _decision(step, note: note, prefetch: prefetch, byHarness: byHarness),
  );

  AgentDecision _decision(_Step step, {String? note, bool prefetch = false, bool byHarness = false}) {
    final usage = step.usage;
    // Read by the next turn's budget line; the last turn is the best predictor
    // of the next one.
    if (usage.promptTokens + usage.completionTokens > 0) {
      _lastTurnTokens = usage.promptTokens + usage.completionTokens;
    }
    return AgentDecision(
      model: client.model,
      tokensPrompt: usage.promptTokens,
      tokensCompletion: usage.completionTokens,
      tokensCachedPrompt: usage.cachedPromptTokens,
      tokensCacheWrite: usage.cacheWriteTokens,
      tokensReasoning: usage.reasoningTokens,
      llmLatencyMs: step.latencyMs,
      llmFirstTokenMs: step.firstTokenMs,
      llmCalls: step.calls,
      note: _note(note),
      extra: {
        if (prefetch) AgentDecision.prefetchKey: true,
        if (byHarness) AgentDecision.authoredByKey: AgentDecision.harnessAuthor,
        ...pendingExtra,
        if (_takeRouteDecision() case final route?) 'modelRoute': route.toJson(),
        if (_takeSideCalls() case final calls when calls.isNotEmpty) AgentDecision.sideCallsKey: [for (final call in calls) call.toJson()],
        if (_takeRecords() case final records when records.isNotEmpty) DecisionRecord.key: [for (final record in records) record.toJson()],
        if (step.toolCount > 0) 'tools': step.toolCount,
        if (step.turns.isNotEmpty) 'llm': step.turns,
        // What was sent, to check the reported prompt tokens against.
        if (step.requestChars > 0) 'requestChars': step.requestChars,
        if (step.resolvedModel case final resolved? when resolved != client.model) 'resolvedModel': resolved,
      },
    );
  }

  /// The user spoke after `meta.done`: the engine's answer to it is
  /// `{user, turn}`. The `done` call gets its tool result — providers reject a
  /// tool call without one — and the follow-up enters as what it is, a user
  /// message, so the model reads a new request rather than an acknowledgement.
  void _acceptFollowUp(LlmToolCall? doneCall, EnvelopeResult result, BudgetStatus budget) {
    if (doneCall != null) {
      _messages.add(LlmMessage.toolResult(callId: doneCall.id, name: doneCall.name, content: jsonEncode({'status': 'received'})));
    }
    final said = result.payload['user'];
    _messages.add(
      LlmMessage.user(
        said is String && said.trim().isNotEmpty
            ? '$said\n${_budgetLine(budget)}'
            : '${describeResult(Envelope.done(), result)}\n'
                  '${_budgetLine(budget)}',
      ),
    );
  }

  /// What the previous turn cost, as the estimate for the next one.
  ///
  /// The mean understates it: the conversation is re-sent whole every turn,
  /// so each turn is dearer than the one before.
  int _lastTurnTokens = 0;

  /// The budget as the model is told it, after every result.
  ///
  /// Carries every budget that has a limit, and says so in words when the
  /// tokens left will not pay for [AgentConfig.finishWarningTurns] more turns:
  /// "finish now" is an instruction where "96000/120000" is trivia.
  String _budgetLine(BudgetStatus budget) {
    final maxTokens = budget.maxTokens;
    final maxTurns = budget.maxTurns;
    final parts = [
      '${budget.stepsUsed}/${budget.maxSteps} actions',
      '${(budget.elapsedMs / 1000).toStringAsFixed(0)}/${budget.maxWallClockMs ~/ 1000}s',
      if (maxTokens != null) '${budget.tokensUsed}/$maxTokens tokens',
      if (maxTurns != null) '${budget.turnsUsed}/$maxTurns turns',
    ];
    final line = '[budget: ${parts.join(', ')}]';
    final warnAfter = config.finishWarningTurns;
    if (maxTokens == null || warnAfter <= 0 || _lastTurnTokens <= 0) {
      return line;
    }
    final turnsAffordable = (maxTokens - budget.tokensUsed) ~/ _lastTurnTokens;
    if (turnsAffordable > warnAfter) return line;
    return '$line\n[benchmark runner, not the user] The token budget is nearly '
        'spent: about $turnsAffordable more turn(s) at the current rate, and '
        'the episode ends the moment it runs out. Stop working and answer now '
        '— call done with what you have established, or abort if the task '
        'cannot be done.';
  }

  /// Maps one tool call; unknown tools get an error tool-result so the
  /// model can self-correct (returns null in that case). So does a `done`
  /// the completion check sends back and an act the guard stops.
  Future<Envelope?> _emitCall(LlmToolCall call) async {
    if (call.name == _doneTool.name) {
      final summary = call.arguments['summary'] as String?;
      if (!await _completionHolds(summary)) {
        _messages.add(LlmMessage.toolResult(callId: call.id, name: call.name, content: _rejectedDone));
        return null;
      }
      final done = Envelope.done(summary: summary);
      // Kept, not cleared: the engine answers `meta.done` with the user's
      // follow-up when the task has one, and that answer belongs to this call.
      _lastSent = (done, call);
      return done;
    }
    if (call.name == _abortTool.name) {
      _lastSent = null;
      return Envelope.abort(reason: call.arguments['reason'] as String? ?? 'aborted');
    }
    // Arguments that were not JSON are the model's mistake: it hears so and
    // gets another turn. Parsed as `{}` they would run the tool with nothing,
    // and thrown they ended the episode as a framework fault.
    if (call.argumentsError case final raw?) {
      _messages.add(
        LlmMessage.toolResult(
          callId: call.id,
          name: call.name,
          content: jsonEncode({
            'status': 'failed',
            'error':
                'the arguments of "${call.name}" are not a JSON object — '
                'nothing ran. Received: '
                '${raw.length > 200 ? '${raw.substring(0, 200)}…' : raw}',
          }),
        ),
      );
      return null;
    }
    final envelope = mapToolCall(call);
    if (envelope == null) {
      _messages.add(
        LlmMessage.toolResult(
          callId: call.id,
          name: call.name,
          content: jsonEncode({'status': 'failed', 'error': 'unknown tool "${call.name}" — use only the provided tools'}),
        ),
      );
      return null;
    }
    final guarded = await _guard(envelope, call);
    if (guarded == null) return null;
    _lastSent = (guarded, call);
    return guarded;
  }

  // Decision model in the loop (`decisions:`)

  /// Recorded on the next envelope, whichever it is: a rejected `done` emits
  /// nothing, so its record rides on what the agent does next.
  final List<DecisionRecord> _pendingRecords = [];
  final List<SideCall> _pendingSideCalls = [];
  var _completionRejections = 0;
  var _decisionLanguage = 'en';

  /// An action the guard held back while the user is asked about it.
  ({Envelope action, LlmToolCall call})? _confirmation;

  /// For subclasses that ask the decision model themselves (the preparer's
  /// selection): the record and the spend ride on the next envelope, and the
  /// spend is priced at the decider's own model (`side_call_cost_usd`).
  void recordDecision(DecisionRecord record, {SideCall? sideCall}) {
    _pendingRecords.add(record);
    if (sideCall != null) _pendingSideCalls.add(sideCall);
  }

  /// The language this episode's questions are asked in.
  String get decisionLanguage => _decisionLanguage;

  List<SideCall> _takeSideCalls() {
    final route = _routeDecisionSideCall;
    _routeDecisionSideCall = null;
    final calls = [?route, ..._pendingSideCalls];
    _pendingSideCalls.clear();
    return calls;
  }

  List<DecisionRecord> _takeRecords() {
    final records = List.of(_pendingRecords);
    _pendingRecords.clear();
    return records;
  }

  static SideCall _spendOf(String purpose, JevSpend spend) => SideCall(
    purpose: purpose,
    model: spend.model,
    tokensPrompt: spend.inputTokens,
    tokensCompletion: spend.outputTokens,
    latencyMs: spend.latencyMs,
    calls: spend.requests,
  );

  static const _rejectedDone =
      '{"status":"rejected","error":"[benchmark runner, not the user] A completion '
      'check read the recent app state and judged the task not finished yet, so '
      'done was not accepted and nothing ended. Work out what is still missing '
      '(read the state again if you need to) and finish it, then call done. If '
      'it really is finished, call done again and say in the summary what shows it."}';

  /// Whether `done` may leave the loop. True without a check, past the
  /// rejection limit, and when the decision model fails — a checker that is
  /// down must not turn every finished task into a budget abort.
  Future<bool> _completionHolds(String? summary) async {
    final check = decisions?.completionCheckIn(_decisionLanguage);
    final limit = decisions?.config.completionCheck?.maxRejections ?? 0;
    final task = _task;
    if (check == null || task == null || _completionRejections >= limit) return true;
    final watch = Stopwatch()..start();
    try {
      final result = await check.check(
        goal: task.instruction,
        state: JevState.text(_decisionState(claim: summary)),
        cancellation: _cancellation,
      );
      final response = result.response;
      recordDecision(
        DecisionRecord(
          purpose: 'completion',
          verdict: result.done ? 'accept' : 'reject',
          noul: result.answer.noul,
          threshold: check.threshold,
          latencyMs: response.latencyMs > 0 ? response.latencyMs : watch.elapsedMilliseconds,
          model: response.model,
          language: result.language,
        ),
        sideCall: _spendOf('completion', JevSpend.of([response])),
      );
      if (!result.done) _completionRejections++;
      return result.done;
    } on Exception catch (e) {
      if (_cancellation?.isCancelled ?? false) rethrow;
      recordDecision(DecisionRecord(purpose: 'completion', verdict: 'error', latencyMs: watch.elapsedMilliseconds, error: '$e', enforced: false));
      return true;
    }
  }

  /// The envelope to emit for [envelope] after the guard: itself, a
  /// `user.ask` that holds it back for a confirmation, or null when it was
  /// stopped (the model then hears why through the call's tool result).
  Future<Envelope?> _guard(Envelope envelope, LlmToolCall call) async {
    final settings = decisions?.config.guard;
    final guard = decisions?.guardIn(_decisionLanguage);
    final task = _task;
    if (settings == null || guard == null || task == null || !settings.covers(envelope)) return envelope;

    final subject = envelope.key == GuardConfig.intentInvokeKey ? '${envelope.payload['intent']}' : envelope.key;
    final enforced = settings.mode == .enforce;
    final watch = Stopwatch()..start();
    final JevGuardVerdict verdict;
    try {
      final review = await guard.review(action: _describeAction(envelope), state: JevState.text(_decisionState()), cancellation: _cancellation);
      verdict = review.verdict;
      recordDecision(
        DecisionRecord(
          purpose: 'guard',
          verdict: verdict.name,
          noul: review.answer.noul,
          subject: subject,
          latencyMs: review.response.latencyMs > 0 ? review.response.latencyMs : watch.elapsedMilliseconds,
          model: review.response.model,
          language: review.language,
          enforced: enforced,
        ),
        sideCall: _spendOf('guard', JevSpend.of([review.response])),
      );
    } on Exception catch (e) {
      if (_cancellation?.isCancelled ?? false) rethrow;
      recordDecision(
        DecisionRecord(purpose: 'guard', verdict: 'error', subject: subject, latencyMs: watch.elapsedMilliseconds, error: '$e', enforced: enforced),
      );
      if (!enforced || settings.allowOnError) return envelope;
      _messages.add(LlmMessage.toolResult(callId: call.id, name: call.name, content: _guardUnavailable));
      return null;
    }

    if (!enforced) return envelope;
    final effective = verdict == .confirm
        ? switch (settings.onConfirm) {
            .proceed => JevGuardVerdict.allow,
            .deny => JevGuardVerdict.deny,
            .ask => JevGuardVerdict.confirm,
          }
        : verdict;
    switch (effective) {
      case .allow:
        return envelope;
      case .deny:
        _messages.add(LlmMessage.toolResult(callId: call.id, name: call.name, content: _guardDenied));
        return null;
      case .confirm:
        _confirmation = (action: envelope, call: call);
        final ask = Envelope(key: GuardConfig.userAskKey, kind: .act, payload: {'type': 'confirm', 'prompt': _confirmPrompt(envelope)});
        // Not a tool call: the answer comes back through [_confirmation].
        _lastSent = (ask, null);
        return ask;
    }
  }

  static const _guardDenied =
      '{"status":"failed","error":"[benchmark runner, not the user] An action guard '
      'stopped this call before it ran: it does not look like what the user asked '
      'for, or it would destroy something the user did not ask to change. Nothing '
      'changed. If the user did ask for it, confirm with them first; otherwise '
      'continue without it."}';

  static const _guardUnavailable =
      '{"status":"failed","error":"[benchmark runner, not the user] The action guard '
      'could not review this call, and this configuration does not run unreviewed '
      'actions. Nothing changed."}';

  String _confirmPrompt(Envelope envelope) {
    final action = _describeAction(envelope);
    return _decisionLanguage == 'de' ? 'Soll ich das wirklich ausführen? $action' : 'Should I go ahead with this? $action';
  }

  /// One line a person — or a decision model — can judge.
  static String _describeAction(Envelope envelope) {
    final (name, args) = envelope.key == GuardConfig.intentInvokeKey
        ? ('${envelope.payload['intent']}', envelope.payload['params'])
        : (envelope.key, envelope.payload);
    final json = args == null || (args is Map && args.isEmpty) ? '' : ' ${jsonEncode(args)}';
    final line = '$name$json';
    return line.length <= 600 ? line : '${line.substring(0, 600)}…';
  }

  /// A yes to a `user.ask {type: confirm}`: the bridge's answer value, in
  /// whichever shape the app gives it.
  static bool _confirmed(EnvelopeResult result) {
    if (result.status != .ok) return false;
    return switch (result.payload['answer']) {
      true => true,
      final String answer => const {'yes', 'y', 'ja', 'j', 'true', 'ok', 'confirm', 'confirmed'}.contains(answer.trim().toLowerCase()),
      _ => false,
    };
  }

  /// What a completion check or guard reads: the task, the latest results
  /// (newest kept first when the budget runs out), and the agent's claim.
  ///
  /// Results as the model saw them — rendered and trimmed by the strategy —
  /// because that is the evidence the agent had; a checker that read more
  /// than the agent could would be judging a different episode.
  String _decisionState({String? claim}) {
    final budget = decisions?.config.maxStateChars ?? 6000;
    final perResult = budget ~/ 2;
    final results = <String>[];
    var used = 0;
    for (final message in _messages.reversed) {
      if (message.role != .tool) continue;
      if (message.content.startsWith('{"status":"rejected"')) continue;
      final content = message.content.length <= perResult ? message.content : '${message.content.substring(0, perResult)}…';
      if (used + content.length > budget && results.isNotEmpty) break;
      results.add('[${message.toolName ?? 'result'}] $content');
      used += content.length;
    }
    if (results.isEmpty) {
      // Nothing called yet: the briefing or bootstrap observation is the
      // state the agent is in.
      for (final message in _messages.reversed) {
        if (message.role == .user) {
          results.add(message.content.length <= budget ? message.content : '${message.content.substring(0, budget)}…');
          break;
        }
      }
    }
    return [
      'Task: ${_task?.instruction ?? ''}',
      '',
      'Recent results, oldest first:',
      ...results.reversed,
      if (claim != null && claim.trim().isNotEmpty) ...['', 'The assistant reports: $claim'],
    ].join('\n');
  }

  int _lastToolCount = 0;

  /// Fingerprint of the tool definitions the last request sent. Ollama renders
  /// them at the top of the prompt, so any change re-prefills everything
  /// (`tool_surface_changes`); names alone would miss a changed schema.
  String? _lastToolSurface;
  List<LlmTool>? _lastTools;

  /// Every tool of the next request, in the order it is sent.
  List<LlmTool> get requestTools => orderTools([...strategyTools, config.examples.tools ? _doneToolWithExample : _doneTool, _abortTool]);

  /// The order tools are sent in. Ollama renders them right after the system
  /// prompt, so whatever is the same for every task should come first; a
  /// subclass with a cache-friendly layout reorders here.
  List<LlmTool> orderTools(List<LlmTool> tools) => tools;

  /// Whether [endEpisode] primes the shared prefix ([AgentConfig.warmPrefix]).
  bool get warmsPrefix => config.warmPrefix;

  /// The tools the next episode's first call will start with, as far as this
  /// episode can tell: the ones its own first call sent. A subclass whose
  /// first tools differ per task narrows this to the part that does not.
  List<LlmTool> get sharedPrefixTools => _firstRequestTools ?? requestTools;

  EnvironmentDescriptor? _environment;
  List<LlmTool>? _firstRequestTools;

  /// Primes a local server's prompt cache with the system prompt for [environment]
  /// and [tools], generating nothing (`LlmPrefixWarmUp`). Sent between episodes, so
  /// it is on no episode's clock.
  Future<void> warmPrefix(EnvironmentDescriptor environment, List<LlmTool> tools) async {
    if (client case final LlmPrefixWarmUp warmable) {
      await warmable.warmPrefix(
        LlmRequest(
          messages: [LlmMessage.system(_systemMessageFor(environment))],
          tools: tools,
          temperature: config.supportsTemperature ? config.temperature : null,
          maxTokens: config.maxCompletionTokens,
          parallelToolCalls: config.parallelToolCalls,
        ),
      );
    }
  }

  Future<LlmResponse> _complete() async {
    final tools = requestTools;
    _firstRequestTools ??= tools;
    _lastToolCount = tools.length;
    if (!_sameTools(tools, _lastTools)) {
      _lastTools = tools;
      _lastToolSurface = configHash([
        for (final tool in tools) {'name': tool.name, 'description': tool.description, 'parameters': tool.parameters},
      ]);
    }
    final request = LlmRequest(
      messages: List.unmodifiable(_windowed(await _compacted(_messages))),
      tools: tools,
      temperature: config.supportsTemperature ? config.temperature : null,
      maxTokens: config.maxCompletionTokens,
      parallelToolCalls: config.parallelToolCalls,
      responseSchema: config.toolCalling == .constrained ? ConstrainedToolCalls.schemaFor(tools) : null,
    );
    _lastRequestChars = _charsOf(request);
    final cancellation = _cancellation ??= CancellationToken();
    final sink = onTextDelta;
    final llm = client;
    // Streaming is an optimisation of the transport: the response is the one
    // `complete` would have returned and usage is read from the final chunk, so
    // the two paths stay comparable.
    if (sink != null && llm is LlmStreamingClient) {
      return llm.completeStreaming(request, onTextDelta: sink, cancellation: cancellation);
    }
    return llm.complete(request, cancellation: cancellation);
  }

  static bool _sameTools(List<LlmTool> a, List<LlmTool>? b) {
    if (b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  /// Characters of what a request sends: messages, tool calls, tool schemas.
  static int _charsOf(LlmRequest request) {
    var chars = 0;
    for (final message in request.messages) {
      chars += message.content.length;
      for (final call in message.toolCalls) {
        chars += call.name.length + jsonEncode(call.arguments).length;
      }
    }
    for (final tool in request.tools) {
      chars += tool.name.length + tool.description.length + jsonEncode(tool.parameters).length;
    }
    return chars;
  }

  /// Replaces tool results older than [AgentConfig.observationWindow] with a
  /// stub, so a long episode cannot walk into the context limit.
  ///
  /// The stub keeps the tool name and the size, so the model can tell "gone
  /// from memory" from "never looked". Applied to the request only; [_messages]
  /// keeps the full history.
  ///
  /// Stubs move in steps of [AgentConfig.observationStride]: sliding per turn
  /// would rewrite an early message on every request and invalidate a
  /// provider's prefix cache. The window stays the upper bound on full results.
  List<LlmMessage> _windowed(List<LlmMessage> messages) {
    final window = config.observationWindow;
    if (window == null) return messages;

    final toolResultIndices = [
      for (final (index, message) in messages.indexed)
        if (message.role == .tool && !_pinned.contains(message)) index,
    ];
    final excess = toolResultIndices.length - window;
    if (excess <= 0) return messages;

    final stride = config.observationStride ?? window;
    final staleCount = ((excess + stride - 1) ~/ stride) * stride;
    final stale = toolResultIndices.take(staleCount.clamp(0, toolResultIndices.length)).toSet();
    _truncatedResults = stale.length;
    return [
      for (final (index, message) in messages.indexed)
        if (stale.contains(index))
          message.withContent(
            '[older result for ${message.toolName ?? 'a tool'} '
            '(${message.content.length} chars) elided to stay within the '
            'context window — call it again if you still need it]',
          )
        else
          message,
    ];
  }

  int _truncatedResults = 0;

  late final Compactor? _compactor = switch (config.compaction) {
    null => null,
    final compaction => Compactor(compaction),
  };

  /// Compaction failures since the last decision, for its note.
  var _compactionFailures = 0;

  /// [messages] with the old turns folded into a summary when
  /// [AgentConfig.compaction] is on and a stride was crossed. The summary call
  /// is a side call of the decision it happened in, priced at the agent's own
  /// model. One that fails leaves the conversation as it is — the window then
  /// does what it always did — and says so in the note.
  Future<List<LlmMessage>> _compacted(List<LlmMessage> messages) async {
    final compactor = _compactor;
    if (compactor == null) return messages;
    try {
      return await compactor.apply(
            messages,
            pinned: _pinned,
            summarise: (request) async {
              final watch = Stopwatch()..start();
              final response = await client.complete(request.copyWith(dropTemperature: !config.supportsTemperature), cancellation: _cancellation);
              _pendingSideCalls.add(
                SideCall(
                  purpose: 'compaction',
                  model: response.model.isEmpty ? client.model : response.model,
                  tokensPrompt: response.usage.promptTokens,
                  tokensCompletion: response.usage.completionTokens,
                  latencyMs: watch.elapsedMilliseconds,
                ),
              );
              return response.text;
            },
          ) ??
          messages;
    } on LlmClientException {
      _compactionFailures++;
      return messages;
    }
  }

  /// Calls the model made in a turn beyond the first, dropped because the config
  /// asks for one at a time; read once into the decision's note.
  int _droppedParallel = 0;

  /// What one model call produced, recorded on the decision as `extra.llm[]`.
  ///
  /// The stop reason, the names it called and how much it wrote are always
  /// there, because they say *why* a turn was empty. The text itself is opt-in
  /// ([AgentConfig.captureModelOutput]): a shipped assistant does not log a
  /// conversation.
  JsonMap _llmTurn(LlmResponse raw, List<String> called, int dropped) => {
    'stopReason': ?raw.stopReason,
    // Read after decoding: under constrained decoding the runtime reports no
    // `tool_calls`, and the call is the JSON in `content`.
    'calls': called,
    if (config.toolCalling == .constrained) 'constrained': true,
    'contentChars': raw.text.length,
    'firstTokenMs': ?raw.firstTokenMs,
    'toolSurface': ?_lastToolSurface,
    'thinkingChars': raw.thinking?.length ?? 0,
    if (client case final LlmFallbackReport report)
      if (report.takeFallbacks() case final fallbacks when fallbacks.isNotEmpty) ...{'fallbacks': fallbacks, 'answeredBy': client.model},
    if (dropped > 0) 'droppedParallel': dropped,
    if (config.captureModelOutput) ...{'content': raw.text, if (raw.thinking != null) 'thinking': raw.thinking},
  };

  /// Joins the caller's note with the loop's own annotations. `elided=n` is
  /// what makes the observation window auditable: without it a shorter
  /// prompt would be indistinguishable from a shorter conversation.
  String? _note(String? note) {
    final dropped = _droppedParallel;
    _droppedParallel = 0;
    final failures = _compactionFailures;
    _compactionFailures = 0;
    final parts = [
      ?note,
      ?pendingNote,
      if (_truncatedResults > 0) 'elided=$_truncatedResults',
      if (_compactor case final compactor? when compactor.compactedTurns > 0) 'compacted=${compactor.compactedTurns}',
      if (failures > 0) 'compaction_failed=$failures',
      if (dropped > 0) 'parallel_dropped=$dropped',
    ];
    return parts.isEmpty ? null : parts.join(' ');
  }

  @override
  Future<void> endEpisode(EpisodeOutcome outcome) async {
    final environment = _environment;
    final warm = warmsPrefix && environment != null ? sharedPrefixTools : null;
    _task = null;
    _cancellation = null;
    _routeDecision = null;
    _confirmation = null;
    _environment = null;
    if (client case final ModelRouter router) router.endEpisode();
    if (warm != null) await warmPrefix(environment!, warm);
  }

  RouteDecision? _takeRouteDecision() {
    final decision = _routeDecision;
    _routeDecision = null;
    _routeDecisionSideCall = decision?.sideCall;
    return decision;
  }

  /// The route's spend, handed from [_takeRouteDecision] to [_takeSideCalls]
  /// within one decision.
  SideCall? _routeDecisionSideCall;

  /// Delegates to the client when it can warm up (Ollama, an on-device
  /// runtime); a no-op for hosted APIs, which have nothing to load.
  @override
  Future<void> warmUp() async {
    if (client case final LlmWarmUp warmable) await warmable.warmUp();
    if (decisions?.client case final JevWarmUp warmable) await warmable.warmUp();
  }

  @override
  Future<JsonMap> modelIdentity() async {
    final identity = await client.identify();
    final withEmbedding = switch (embeddingClient) {
      null => identity,
      final LlmModelIdentity pinned => {...identity, 'embedding': await pinned.modelIdentity()},
      final embedding => {
        ...identity,
        'embedding': {'model': embedding.model},
      },
    };
    return switch (decisions?.client) {
      null => withEmbedding,
      final JevServerInfo info => {
        ...withEmbedding,
        'decisions': {'model': (decisions!.client).model, 'health': await _health(info)},
      },
      final client => {
        ...withEmbedding,
        'decisions': {'model': client.model},
      },
    };
  }

  /// Best effort: a health probe that fails must not fail the run's
  /// identity record.
  static Future<JsonMap?> _health(JevServerInfo info) async {
    try {
      return await info.health();
    } on Exception {
      return null;
    }
  }

  /// Task currently being worked on (for subclasses).
  TaskSpec? get currentTask => _task;
}

/// The telemetry of one `next()` step: every LLM call it made.
final class _Step {
  var usage = const LlmUsage();
  var latencyMs = 0;
  var calls = 0;
  var toolCount = 0;
  var requestChars = 0;
  String? resolvedModel;

  /// The provider's own view of the wait before the first token, summed the way
  /// latency is.
  int? firstTokenMs;

  /// What each model call produced, for the decision's `llm`.
  final turns = <JsonMap>[];

  void record(LlmResponse response, {required int toolCount, required int requestChars}) {
    calls++;
    if (response.firstTokenMs case final ms?) {
      firstTokenMs = (firstTokenMs ?? 0) + ms;
    }
    usage += response.usage;
    this.toolCount = toolCount;
    this.requestChars += requestChars;
    if (response.model.isNotEmpty) resolvedModel = response.model;
  }
}
