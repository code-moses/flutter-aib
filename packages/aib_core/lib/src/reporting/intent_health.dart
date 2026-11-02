import '../aggregation/stats.dart';
import '../common/json.dart';
import '../ports/envelope.dart';
import '../trace/trace.dart';

/// How one envelope key — or whatever a provider's label names finer, such as
/// the intent behind a generic invoke key — fared across a run.
final class IntentHealthRow {
  IntentHealthRow(this.name);

  final String name;
  int calls = 0;
  int failed = 0;
  int badParams = 0;
  int uninformative = 0;
  int suppressed = 0;
  final Set<String> episodes = {};
  final List<num> resultBytes = [];
}

/// Per-intent failure, schema and repetition rates over a run's traces —
/// where an app integration loses turns, by capability rather than by task.
///
/// [label] names an exchange; by default its key.
List<IntentHealthRow> intentHealth(List<EpisodeTrace> traces, {String Function(Exchange exchange)? label}) {
  final rows = <String, IntentHealthRow>{};
  for (final trace in traces) {
    for (final x in trace.exchanges()) {
      if (x.isMeta) continue;
      final name = label?.call(x) ?? x.key;
      final row = rows.putIfAbsent(name, () => IntentHealthRow(name));
      final result = x.result?.data ?? const <String, Object?>{};
      row
        ..calls += 1
        ..episodes.add(trace.meta.episodeId);
      if (x.status == 'failed') row.failed++;
      if (asJsonMap(result['error'])['code'] == EnvelopeError.badParams) {
        row.badParams++;
      }
      if (((result['answerIndex'] as num?) ?? 0) > 0 && ((result['repeatIndex'] as num?) ?? 0) == 0) {
        row.uninformative++;
      }
      if (result['suppressed'] == true) row.suppressed++;
      if (result['payloadBytes'] case final num bytes) {
        row.resultBytes.add(bytes);
      }
    }
  }
  return rows.values.toList()..sort((a, b) => b.calls.compareTo(a.calls));
}

String intentHealthMarkdown(List<IntentHealthRow> rows, {required int episodes}) {
  String pct(int n, int of) => of == 0 ? '—' : '${(100 * n / of).round()}%';
  final buffer = StringBuffer()
    ..writeln(
      '| intent / key | calls | episodes | failed | bad params '
      '| same answer | suppressed | median result bytes |',
    )
    ..writeln('|---|---|---|---|---|---|---|---|');
  for (final r in rows) {
    buffer.writeln(
      '| `${r.name}` | ${r.calls} | ${pct(r.episodes.length, episodes)} '
      '| ${pct(r.failed, r.calls)} | ${pct(r.badParams, r.calls)} '
      '| ${pct(r.uninformative, r.calls)} | ${pct(r.suppressed, r.calls)} '
      '| ${r.resultBytes.isEmpty ? '—' : Stats.median(r.resultBytes).round()} |',
    );
  }
  return buffer.toString();
}
