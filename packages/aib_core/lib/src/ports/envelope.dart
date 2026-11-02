import '../common/json.dart';

/// Declared by the agent per envelope (spec §4.3): the core needs the
/// distinction only for efficiency metrics (`action_count` counts `act`).
/// Declarations are verified via state diffs where the environment supports
/// fingerprinting (`kind_integrity_violations`).
enum EnvelopeKind { observe, act }

/// One call to a model other than the one that produced the decision, priced by
/// its own model (see [AgentDecision.sideCallsKey]).
final class SideCall {
  const SideCall({required this.purpose, required this.model, this.tokensPrompt = 0, this.tokensCompletion = 0, this.latencyMs = 0, this.calls = 1});

  /// What it was for (`route`, `embed`, `guard`). Free-form: the framework
  /// prices side calls without knowing what an agent uses them for.
  final String purpose;

  /// The model that answered, as the provider reported it — the key the
  /// price table is read with.
  final String model;

  final int tokensPrompt;
  final int tokensCompletion;
  final int latencyMs;
  final int calls;

  int get tokensTotal => tokensPrompt + tokensCompletion;

  JsonMap toJson() => {
    'purpose': purpose,
    'model': model,
    if (tokensPrompt > 0) 'tokensPrompt': tokensPrompt,
    if (tokensCompletion > 0) 'tokensCompletion': tokensCompletion,
    if (latencyMs > 0) 'latencyMs': latencyMs,
    if (calls != 1) 'calls': calls,
  };

  factory SideCall.fromJson(JsonMap json) => SideCall(
    purpose: json['purpose'] as String? ?? '',
    model: json['model'] as String? ?? '',
    tokensPrompt: (json['tokensPrompt'] as num?)?.toInt() ?? 0,
    tokensCompletion: (json['tokensCompletion'] as num?)?.toInt() ?? 0,
    latencyMs: (json['latencyMs'] as num?)?.toInt() ?? 0,
    calls: (json['calls'] as num?)?.toInt() ?? 1,
  );
}

final class AgentDecision {
  const AgentDecision({
    this.model,
    this.tokensPrompt = 0,
    this.tokensCompletion = 0,
    this.tokensCachedPrompt = 0,
    this.tokensCacheWrite = 0,
    this.tokensReasoning = 0,
    this.llmLatencyMs = 0,
    this.llmFirstTokenMs,
    this.llmCalls = 0,
    this.note,
    this.extra,
  });

  final String? model;
  final int tokensPrompt;
  final int tokensCompletion;

  /// Subset of [tokensPrompt] the provider served from its cache, and subset of
  /// [tokensCompletion] spent on hidden reasoning. Both are billed at their own
  /// rate, so `cost_usd` needs them separately.
  final int tokensCachedPrompt;

  /// Prompt tokens the provider wrote into its cache on this call. Included
  /// in [tokensPrompt], not additional to it — a provider reports them apart
  /// and a client that leaves them out of the total under-reports what it
  /// spent.
  final int tokensCacheWrite;
  final int tokensReasoning;

  final int llmLatencyMs;

  /// Time to the first generated token of this turn, where the provider reports
  /// it.
  final int? llmFirstTokenMs;

  final int llmCalls;
  final String? note;

  /// Structured facts the agent states about this decision — what it did,
  /// never what that was worth (metrics are computed by the framework).
  /// Reserved keys: [prefetchKey], [countersKey], [rolesKey], [sideCallsKey],
  /// [authoredByKey].
  final JsonMap? extra;

  /// `true` on an envelope the agent emitted without being asked to by its
  /// model (a bootstrap or prefetch); the no-progress guard ignores it.
  static const prefetchKey = 'prefetch';

  /// Numeric facts under this key are aggregated as `agent.<name>` metrics.
  static const countersKey = 'counters';

  /// Per-role spend under this key: `{role: {calls, tokensPrompt,
  /// tokensCompletion}}`.
  ///
  /// For agents with sub-agents. [tokensPrompt] and [tokensCompletion] stay the
  /// *whole* of what the turn cost; this only says how it divides. Any role
  /// other than [mainRole] counts as auxiliary.
  static const rolesKey = 'roles';

  /// The role of the loop that emits envelopes; spend under any other name is
  /// auxiliary. Also assumed for an agent that reports no roles at all.
  static const mainRole = 'main';

  /// Calls to *another model* that this turn paid for, under this key as a list
  /// of [SideCall] (a model router's decider, an embedding pass, a guard).
  ///
  /// Separate from [rolesKey], which divides this decision's own tokens between
  /// loops of the same model. Side-call tokens stay out of
  /// [tokensPrompt]/[tokensCompletion], and so out of `tokens_total` and the
  /// token budget; `cost_usd` counts them.
  static const sideCallsKey = 'sideCalls';

  List<SideCall> get sideCalls => [for (final raw in extra?[sideCallsKey] as List? ?? const []) SideCall.fromJson(asJsonMap(raw))];

  bool get isPrefetch => extra?[prefetchKey] == true;

  /// Who wrote the envelope's text, under this key: [harnessAuthor] when the
  /// agent's own loop produced it because the model produced nothing usable.
  ///
  /// Such a `meta.abort` ends the episode like any other, but it is not a claim
  /// the agent made, so a rubric judging what the agent *said* must not judge
  /// it.
  static const authoredByKey = 'authoredBy';
  static const harnessAuthor = 'harness';

  /// The first word of the note the reference ToolLoopAgent wrote on its own
  /// aborts before [authoredByKey] existed (it joins notes with spaces), so
  /// traces recorded then are read the same way (P6). New agents set the key.
  static const legacyHarnessNotes = {'no_usable_response', 'llm_error'};

  bool get isHarnessAuthored => extra?[authoredByKey] == harnessAuthor || legacyHarnessNotes.contains(note?.split(' ').first);

  int get tokensTotal => tokensPrompt + tokensCompletion;

  JsonMap toJson() => {
    if (model != null) 'model': model,
    'tokensPrompt': tokensPrompt,
    'tokensCompletion': tokensCompletion,
    if (tokensCachedPrompt > 0) 'tokensCachedPrompt': tokensCachedPrompt,
    if (tokensCacheWrite > 0) 'tokensCacheWrite': tokensCacheWrite,
    if (tokensReasoning > 0) 'tokensReasoning': tokensReasoning,
    'llmLatencyMs': llmLatencyMs,
    if (llmFirstTokenMs != null) 'llmFirstTokenMs': llmFirstTokenMs,
    'llmCalls': llmCalls,
    if (note != null) 'note': note,
    if (extra != null && extra!.isNotEmpty) 'extra': extra,
  };

  factory AgentDecision.fromJson(JsonMap json) => AgentDecision(
    model: json['model'] as String?,
    tokensPrompt: (json['tokensPrompt'] as num?)?.toInt() ?? 0,
    tokensCompletion: (json['tokensCompletion'] as num?)?.toInt() ?? 0,
    tokensCachedPrompt: (json['tokensCachedPrompt'] as num?)?.toInt() ?? 0,
    tokensCacheWrite: (json['tokensCacheWrite'] as num?)?.toInt() ?? 0,
    tokensReasoning: (json['tokensReasoning'] as num?)?.toInt() ?? 0,
    llmLatencyMs: (json['llmLatencyMs'] as num?)?.toInt() ?? 0,
    llmFirstTokenMs: (json['llmFirstTokenMs'] as num?)?.toInt(),
    llmCalls: (json['llmCalls'] as num?)?.toInt() ?? 0,
    note: json['note'] as String?,
    extra: json['extra'] == null ? null : asJsonMap(json['extra']),
  );
}

/// The only content-bearing structure the core knows about agent↔environment
/// communication (spec §4.1). `key` is chosen freely by the agent — the core
/// prescribes no catalog; the single reserved namespace is `meta.*`.
final class Envelope {
  const Envelope({required this.key, required this.kind, this.payload = const {}, this.decision});

  final String key;
  final EnvelopeKind kind;
  final JsonMap payload; // opaque to the core
  final AgentDecision? decision;

  static const String metaPrefix = 'meta.';
  static const String metaDone = 'meta.done';
  static const String metaAbort = 'meta.abort';

  bool get isMeta => key.startsWith(metaPrefix);
  bool get isDone => key == metaDone;
  bool get isAbort => key == metaAbort;

  factory Envelope.done({String? summary, AgentDecision? decision}) =>
      Envelope(key: metaDone, kind: .act, payload: {'summary': ?summary}, decision: decision);

  factory Envelope.abort({required String reason, AgentDecision? decision}) =>
      Envelope(key: metaAbort, kind: .act, payload: {'reason': reason}, decision: decision);

  JsonMap toJson() => {'key': key, 'kind': kind.name, 'payload': payload, 'decision': ?decision?.toJson()};

  factory Envelope.fromJson(JsonMap json) => Envelope(
    key: json['key'] as String,
    kind: EnvelopeKind.values.byName(json['kind'] as String? ?? 'act'),
    payload: asJsonMap(json['payload']),
    decision: json['decision'] == null ? null : AgentDecision.fromJson(asJsonMap(json['decision'])),
  );
}

enum EnvelopeStatus { ok, unsupported, failed }

/// Structured error for `unsupported` / `failed` results (spec §4.1).
final class EnvelopeError {
  const EnvelopeError({required this.code, required this.message, this.details});

  final String code;
  final String message;
  final JsonMap? details;

  /// Reserved code: the payload did not match the key's declared
  /// `payloadSchema`. The request's fault, not the environment's — metrics
  /// count it apart from genuine failures (`invalid_tool_call_count`).
  static const badParams = 'bad_params';

  JsonMap toJson() => {'code': code, 'message': message, if (details != null) 'details': details};

  factory EnvelopeError.fromJson(JsonMap json) => EnvelopeError(
    code: json['code'] as String? ?? 'unknown',
    message: json['message'] as String? ?? '',
    details: json['details'] == null ? null : asJsonMap(json['details']),
  );
}

final class EnvelopeResult {
  const EnvelopeResult({required this.status, this.payload = const {}, this.error, this.userWaitMs});

  final EnvelopeStatus status;
  final JsonMap payload; // opaque to the core
  final EnvelopeError? error;

  /// Of the time spent handling this envelope, how much was spent waiting for a
  /// *human* (a clarification, a confirmation, a picker). The engine subtracts
  /// it from the episode wall clock, so asking does not cost more than
  /// guessing.
  ///
  /// Null means the environment does not distinguish; zero means nobody waited.
  final int? userWaitMs;

  /// Reserved: intent names or keys that answer this result's dead end, in
  /// `payload` (ok) or `error.details` (failed).
  static const suggestsKey = 'suggests';

  factory EnvelopeResult.ok([JsonMap payload = const {}]) => EnvelopeResult(status: .ok, payload: payload);

  factory EnvelopeResult.unsupported(String key) => EnvelopeResult(
    status: .unsupported,
    error: EnvelopeError(code: 'unsupported_key', message: 'Environment does not support envelope key "$key"'),
  );

  factory EnvelopeResult.failed(String code, String message, {JsonMap? details, int? userWaitMs}) => EnvelopeResult(
    status: .failed,
    error: EnvelopeError(code: code, message: message, details: details),
    userWaitMs: userWaitMs,
  );

  JsonMap toJson() => {'status': status.name, 'payload': payload, 'error': ?error?.toJson(), if (userWaitMs != null) 'userWaitMs': userWaitMs};

  factory EnvelopeResult.fromJson(JsonMap json) => EnvelopeResult(
    status: EnvelopeStatus.values.byName(json['status'] as String? ?? 'ok'),
    payload: asJsonMap(json['payload']),
    error: json['error'] == null ? null : EnvelopeError.fromJson(asJsonMap(json['error'])),
    userWaitMs: (json['userWaitMs'] as num?)?.toInt(),
  );
}
