import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

EpisodeRecord _record({required num? confidence, required bool right}) => EpisodeRecord(
  runId: 'r',
  episodeId: 'e${confidence}_$right',
  taskId: 't',
  agentId: 'a',
  repetition: 1,
  verdict: right ? const Verdict(type: .success, score: 1) : const Verdict(type: .failure, score: 0),
  metrics: {'stated_confidence': ?confidence},
);

num? _aggregate(String name, List<EpisodeRecord> group) => calibrationMetrics.aggregates.firstWhere((a) => a.name == name).compute(group);

void main() {
  test('an agent that states nothing is not scored on it', () {
    final group = [_record(confidence: null, right: true), _record(confidence: null, right: false)];
    expect(_aggregate('brier_score', group), isNull);
    expect(_aggregate('calibration_error', group), isNull);
    expect(_aggregate('confidence_separation', group), isNull);
  });

  test('perfect confidence scores 0 on Brier', () {
    final group = [_record(confidence: 1, right: true), _record(confidence: 0, right: false)];
    expect(_aggregate('brier_score', group), 0);
    expect(_aggregate('calibration_error', group), 0);
  });

  test('answering 0.5 every time is 0.25, the uninformative baseline', () {
    final group = [_record(confidence: 0.5, right: true), _record(confidence: 0.5, right: false)];
    expect(_aggregate('brier_score', group), closeTo(0.25, 1e-9));
  });

  test('confidently wrong is the worst Brier there is', () {
    expect(_aggregate('brier_score', [_record(confidence: 1, right: false)]), 1);
  });

  test('separation is zero when the number carries no information', () {
    // Well calibrated on average and useless per episode: the two cases are
    // told apart by separation and by nothing else here.
    final group = [_record(confidence: 0.5, right: true), _record(confidence: 0.5, right: false)];
    expect(_aggregate('confidence_separation', group), 0);
  });

  test('separation is positive when it does', () {
    final group = [_record(confidence: 0.9, right: true), _record(confidence: 0.2, right: false)];
    expect(_aggregate('confidence_separation', group), closeTo(0.7, 1e-9));
  });

  test('separation needs both outcomes to exist', () {
    expect(_aggregate('confidence_separation', [_record(confidence: 0.9, right: true)]), isNull);
  });

  test('a confidence outside 0..1 is not a confidence', () {
    final trace = _traceWith({'summary': 'x', 'confidence': 1.5});
    expect(statedConfidence(trace), isNull);
    expect(statedConfidence(_traceWith({'summary': 'x', 'confidence': 0.4})), 0.4);
    expect(statedConfidence(_traceWith({'summary': 'x'})), isNull);
  });
}

EpisodeTrace _traceWith(JsonMap payload) => EpisodeTrace(
  meta: EpisodeMeta(runId: 'r', episodeId: 'e', taskId: 't', agentId: 'a', environmentId: 'env', repetition: 1, startedAt: DateTime.utc(2026)),
  events: [
    TraceEvent(seq: 0, tUs: 0, type: TraceEventTypes.agentEnvelope, data: {'key': 'meta.done', 'kind': 'act', 'payload': payload}),
  ],
);
