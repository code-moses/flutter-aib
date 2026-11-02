import 'package:aib_core/transport.dart';

import 'answer.dart';
import 'request.dart';

/// A "System One" decision model: reads a state, answers typed questions with a
/// distribution instead of text. One port for every backend, so only the `jev:`
/// block of a config moves.
///
/// Not modelled on `LlmClient`: a decision model has no messages, no tools, no
/// sampling and nothing to stream.
abstract interface class JevClient {
  /// What the client was configured to ask. The model that actually answered
  /// comes back in [JevResponse.model] and is what provenance records.
  String get model;

  Future<JevResponse> decide(JevRequest request, {CancellationToken? cancellation});
}

/// A backend that can describe itself. Probed with `is`, like `LlmWarmUp` on
/// the LLM side: a hosted API has nothing to load and no health endpoint, a
/// local server has both.
abstract interface class JevServerInfo {
  /// Model ids this endpoint accepts.
  Future<List<String>> models();

  /// Ready, and which model is loaded; null where the backend has no health
  /// endpoint.
  Future<JsonMap?> health();
}

/// Loads whatever the backend needs before it answers at normal speed — a
/// model into Ollama's memory, weights off flash. Probed with `is`; call it
/// once before the first decision so the first episode is not charged for
/// the load (the budget is "model load, amortised: once per process").
abstract interface class JevWarmUp {
  Future<void> warmUp();
}

/// The three question shapes as single calls that return the answer's own
/// type — the surface for the cases that ask one thing.
///
/// Several questions about one state belong in one [JevRequest] instead: the
/// server evaluates the shared prefix once and only the suffixes again.
extension JevAsk on JevClient {
  /// Pick one of [options] (id → description, null for "the id says it").
  Future<JevChoiceAnswer> choose({
    required JevState state,
    required String instructions,
    required Map<String, String?> options,
    CancellationToken? cancellation,
  }) async {
    final response = await decide(
      JevRequest(
        state: state,
        questions: {'q': JevChoice(instructions: instructions, criteria: options)},
      ),
      cancellation: cancellation,
    );
    return response.answer<JevChoiceAnswer>('q');
  }

  /// Pick one value of an enum; the answer comes back typed.
  Future<({E value, JevChoiceAnswer answer})> chooseEnum<E extends Enum>({
    required JevState state,
    required JevEnumChoice<E> question,
    CancellationToken? cancellation,
  }) async {
    final response = await decide(
      JevRequest(state: state, questions: {'q': question}),
      cancellation: cancellation,
    );
    final answer = response.answer<JevChoiceAnswer>('q');
    return (value: question.decode(answer), answer: answer);
  }

  /// How true [statement] is, on [0.01, 0.99].
  Future<JevNoulAnswer> judge({
    required JevState state,
    required String statement,
    String? ifTrue,
    String? ifFalse,
    CancellationToken? cancellation,
  }) async {
    final response = await decide(
      JevRequest(
        state: state,
        questions: {'q': JevNoul(instructions: statement, ifTrue: ifTrue, ifFalse: ifFalse)},
      ),
      cancellation: cancellation,
    );
    return response.answer<JevNoulAnswer>('q');
  }

  /// Place the state on an ordered rubric, lowest level first.
  Future<JevScoreAnswer> rate({
    required JevState state,
    required String instructions,
    required List<String> levels,
    CancellationToken? cancellation,
  }) async {
    final response = await decide(
      JevRequest(
        state: state,
        questions: {'q': JevScore(instructions: instructions, levels: levels)},
      ),
      cancellation: cancellation,
    );
    return response.answer<JevScoreAnswer>('q');
  }

  /// One `noul` per candidate. Returns candidate id → truth.
  ///
  /// Sent as one request per [perRequest] candidates, because servers cap the
  /// branches of a call (simple-jev: 100 by default, 256 at the schema). Chunks
  /// go sequentially: a server that runs one model request at a time gains
  /// nothing from parallel calls.
  Future<Map<String, JevNoulAnswer>> judgeEach({
    required JevState state,
    required Map<String, String> candidates,
    int perRequest = 50,
    CancellationToken? cancellation,
  }) async => (await judgeEachWithResponses(state: state, candidates: candidates, perRequest: perRequest, cancellation: cancellation)).answers;

  /// [judgeEach], keeping the responses of every chunk — what a caller that
  /// has to account for the decider's spend (latency, tokens, the model that
  /// answered) needs next to the answers.
  ///
  /// [ifTrue] and [ifFalse] are the rubric's two ends, the same for every
  /// candidate.
  Future<({Map<String, JevNoulAnswer> answers, List<JevResponse> responses})> judgeEachWithResponses({
    required JevState state,
    required Map<String, String> candidates,
    int perRequest = 50,
    String? ifTrue,
    String? ifFalse,
    CancellationToken? cancellation,
  }) async {
    if (candidates.isEmpty) return (answers: const <String, JevNoulAnswer>{}, responses: const <JevResponse>[]);
    if (perRequest < 1) {
      throw ArgumentError.value(perRequest, 'perRequest', 'must be positive');
    }
    final ids = candidates.keys.toList();
    final answers = <String, JevNoulAnswer>{};
    final responses = <JevResponse>[];
    for (var start = 0; start < ids.length; start += perRequest) {
      final chunk = ids.skip(start).take(perRequest).toList();
      final response = await decide(
        JevRequest(
          state: state,
          questions: {for (final (i, id) in chunk.indexed) 'q$i': JevNoul(instructions: candidates[id]!, ifTrue: ifTrue, ifFalse: ifFalse)},
        ),
        cancellation: cancellation,
      );
      responses.add(response);
      for (final (i, id) in chunk.indexed) {
        answers[id] = response.answer<JevNoulAnswer>('q$i');
      }
    }
    return (answers: answers, responses: responses);
  }

  /// [judgeEach], keeping the candidates whose truth reaches [threshold],
  /// most true first — a filter over a catalogue or a result set.
  Future<List<String>> shortlist({
    required JevState state,
    required Map<String, String> candidates,
    double threshold = 0.5,
    int? topK,
    int perRequest = 50,
    CancellationToken? cancellation,
  }) async {
    final answers = await judgeEach(state: state, candidates: candidates, perRequest: perRequest, cancellation: cancellation);
    final kept = answers.entries.where((e) => e.value.noul >= threshold).toList()..sort((a, b) => b.value.noul.compareTo(a.value.noul));
    final ids = [for (final e in kept) e.key];
    return topK == null ? ids : ids.take(topK).toList();
  }
}
