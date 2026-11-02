import '../aggregation/aggregator.dart';
import '../evaluation/verdict.dart';
import 'reporting.dart';

/// `junit.xml` — one testcase per episode (task × repetition, per agent), so
/// a CI system shows a benchmark run the way it shows a test run.
///
/// A testsuite per agent; the testcase's class is the task's cluster (the
/// task, or the task in one rewording), its name the repetition. A success is
/// a pass, a partial or a failure is a `<failure>` whose message is the
/// verdict's reason, an evaluation error is an `<error>`. The time is the
/// episode's wall clock.
final class JunitReporter extends Reporter {
  @override
  String get format => 'junit';
  @override
  String get fileName => 'junit.xml';

  @override
  String render(RunReportData data) {
    final byAgent = <String, List<_Episode>>{};
    for (final record in data.records) {
      byAgent.putIfAbsent(record.agentId, () => []).add(_Episode(record));
    }
    final runId = data.manifest?.runId ?? (data.records.isEmpty ? 'run' : data.records.first.runId);
    final buffer = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
        '<testsuites name="${_x(runId)}" tests="${data.records.length}" '
        'failures="${_count(data, _failed)}" errors="${_count(data, _errored)}">',
      );
    for (final MapEntry(key: agent, value: episodes) in byAgent.entries) {
      final seconds = episodes.fold<double>(0, (sum, e) => sum + e.seconds);
      buffer.writeln(
        '  <testsuite name="${_x(agent)}" tests="${episodes.length}" '
        'failures="${episodes.where((e) => _failed(e.record.verdict)).length}" '
        'errors="${episodes.where((e) => _errored(e.record.verdict)).length}" '
        'time="${seconds.toStringAsFixed(3)}">',
      );
      for (final episode in episodes) {
        final record = episode.record;
        final verdict = record.verdict;
        buffer.write(
          '    <testcase classname="${_x('$agent.${record.cluster}')}" '
          'name="${_x('rep${record.repetition}')}" time="${episode.seconds.toStringAsFixed(3)}"',
        );
        if (verdict.type == .success) {
          buffer.writeln('/>');
          continue;
        }
        final tag = _errored(verdict) ? 'error' : 'failure';
        final message = [
          verdict.type.name,
          if (verdict.type == .partial) 'score ${verdict.score.toStringAsFixed(2)}',
          ?verdict.label,
          ?verdict.reason,
        ].join(': ');
        buffer
          ..writeln('>')
          ..writeln('      <$tag type="${verdict.type.name}" message="${_x(message)}">${_x(record.episodeId)}</$tag>')
          ..writeln('    </testcase>');
      }
      buffer.writeln('  </testsuite>');
    }
    buffer.writeln('</testsuites>');
    return buffer.toString();
  }

  static bool _failed(Verdict verdict) => verdict.type == .failure || verdict.type == .partial;
  static bool _errored(Verdict verdict) => verdict.type == .error;
  static int _count(RunReportData data, bool Function(Verdict) test) => data.records.where((r) => test(r.verdict)).length;

  static String _x(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;')
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');
}

/// An episode with its wall clock in seconds.
final class _Episode {
  _Episode(this.record) : seconds = ((record.metrics['wall_clock_ms'] ?? 0) / 1000).toDouble();

  final EpisodeRecord record;
  final double seconds;
}
