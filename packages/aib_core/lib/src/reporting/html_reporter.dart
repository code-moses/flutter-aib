import 'dart:convert';

import '../aggregation/aggregator.dart';
import 'reporting.dart';

/// Self-contained `report.html` (spec §9): comparison tables with CI error
/// ranges, per-task matrix and a cost↔success (Pareto) plot as inline SVG.
/// No external assets — the file is archivable alongside the run.
final class HtmlReporter extends Reporter {
  @override
  String get format => 'html';
  @override
  String get fileName => 'report.html';

  @override
  String render(RunReportData data) {
    final agents = data.records.map((r) => r.agentId).toSet().toList()..sort();
    final tasks = data.records.map((r) => r.taskId).toSet().toList()..sort();

    AggregateRow? row(String agentId, String taskId, String metric) {
      for (final r in data.aggregates) {
        if (r.agentId == agentId && r.taskId == taskId && r.metric == metric) {
          return r;
        }
      }
      return null;
    }

    String fmt(double? v, [int digits = 2]) => v == null || v.isNaN ? '—' : v.toStringAsFixed(digits);
    String esc(String s) => const HtmlEscape().convert(s);

    final buffer = StringBuffer('''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>AIB Report</title>
<style>
  body { font: 14px/1.5 -apple-system, "Segoe UI", sans-serif; margin: 2rem auto; max-width: 64rem; color: #1a202c; }
  h1, h2 { font-weight: 600; }
  table { border-collapse: collapse; margin: 1rem 0; width: 100%; }
  th, td { border: 1px solid #cbd5e0; padding: .35rem .6rem; text-align: right; }
  th:first-child, td:first-child { text-align: left; }
  th { background: #edf2f7; }
  .meta { color: #4a5568; font-size: .85rem; }
  .bar { background: #3182ce; height: .7rem; display: inline-block; vertical-align: middle; }
  .ci { color: #718096; font-size: .85rem; }
  .warn { background: #fffaf0; border-left: 3px solid #dd6b20; padding: .5rem .8rem; }
</style>
</head>
<body>
<h1>AIB Report</h1>
''');

    final manifest = data.manifest;
    if (manifest != null) {
      buffer.writeln(
        '<p class="meta">Run <code>${esc(manifest.runId)}</code>'
        ' · ${manifest.createdAt}'
        ' · Suite <code>${esc(manifest.suiteName)}</code>'
        ' (hash <code>${esc(shortHash(manifest.suiteHash))}</code>)'
        ' · Environment <code>${esc(manifest.environmentId)}</code>'
        ' · Repetitions ${manifest.repetitions} · Seed ${manifest.seed}'
        ' · Framework ${esc(manifest.frameworkVersion)}</p>',
      );
    }

    // Judge provenance (P6)
    final judge = data.judge;
    if (judge != null) {
      final overlap = data.judgeAgentOverlap;
      buffer
        ..writeln('<h2>Judge</h2>')
        ..writeln(
          '<p class="meta">Judge <code>${esc(judge.judgeId)}</code>'
          ' · k=${judge.k}'
          '${judge.pinnedModel == null ? '' : ' · pinned to <code>'
                    '${esc(judge.pinnedModel!)}</code>'}'
          '${judge.rubrics.isEmpty ? '' : ' · rubrics '
                    '${judge.rubrics.entries.map((e) => '<code>${esc(e.key)}'
                        '@${esc(shortHash(e.value))}</code>').join(', ')}'}</p>',
        )
        ..writeln(
          '<table><tr><th>Agent</th><th>Model</th></tr>'
          '${data.agentModels.entries.map((e) => '<tr><td>${esc(e.key)}'
              '</td><td>${esc(e.value)}</td></tr>').join()}</table>',
        );
      if (overlap.isNotEmpty) {
        buffer.writeln(
          '<p class="warn">⚠️ The judge model is also the '
          'backbone of ${esc(overlap.join(', '))} — rubric scores for '
          'these agents are not independent of the model under '
          'evaluation.</p>',
        );
      }
    }

    // Agent overview
    buffer
      ..writeln('<h2>Agent overview</h2>')
      ..writeln(
        '<table><tr><th>Agent</th><th>weighted_score</th>'
        '<th>success_rate (95% CI)</th><th>wall_clock_ms (median)</th>'
        '<th>tokens_total (median)</th><th>infrastructure_error_rate</th></tr>',
      );
    for (final agent in agents) {
      final success = row(agent, '*', 'success_rate');
      final score = row(agent, '*', 'weighted_score');
      buffer.writeln(
        '<tr><td>${esc(agent)}</td>'
        '<td><span class="bar" style="width:${((score?.mean ?? 0) * 80).round()}px"></span> '
        '${fmt(score?.mean)}</td>'
        '<td>${fmt(success?.mean)} <span class="ci">[${fmt(success?.ciLow)}, '
        '${fmt(success?.ciHigh)}]</span></td>'
        '<td>${fmt(row(agent, '*', 'wall_clock_ms')?.median, 0)}</td>'
        '<td>${fmt(row(agent, '*', 'tokens_total')?.median, 0)}</td>'
        '<td>${fmt(row(agent, '*', 'infrastructure_error_rate')?.mean)}</td></tr>',
      );
    }
    buffer.writeln('</table>');

    // Reliability: pass^k decay (τ-bench)
    final kMax = data.aggregates
        .where((r) => r.taskId == '*' && r.metric.startsWith('pass_'))
        .map((r) => int.parse(r.metric.substring(5)))
        .fold(0, (a, b) => a > b ? a : b);
    if (kMax > 0) {
      buffer
        ..writeln('<h2>Reliability — pass^k</h2>')
        ..writeln(
          '<p class="meta">Probability that all k repetitions of a '
          'task succeed, averaged over tasks. pass^1 is the success rate; '
          'the decay towards pass^$kMax is the agent\'s consistency.</p>',
        )
        ..writeln(
          '<table><tr><th>Agent</th>'
          '${[for (var k = 1; k <= kMax; k++) '<th>pass^$k</th>'].join()}</tr>',
        );
      for (final agent in agents) {
        buffer.writeln(
          '<tr><td>${esc(agent)}</td>'
          '${[for (var k = 1; k <= kMax; k++) '<td>${fmt(row(agent, '*', 'pass_$k')?.mean)}</td>'].join()}</tr>',
        );
      }
      buffer.writeln('</table>');
    }

    // Score matrix
    buffer
      ..writeln('<h2>weighted_score per agent × task</h2>')
      ..writeln(
        '<table><tr><th>Task</th>'
        '${agents.map((a) => '<th>${esc(a)}</th>').join()}</tr>',
      );
    for (final task in tasks) {
      buffer.writeln(
        '<tr><td>${esc(task)}</td>'
        '${agents.map((a) => '<td>${fmt(row(a, task, 'weighted_score')?.mean)}</td>').join()}</tr>',
      );
    }
    buffer.writeln('</table>');

    // Pareto: cost vs success
    buffer
      ..writeln('<h2>Cost ↔ success (Pareto)</h2>')
      ..writeln(_paretoSvg(agents, row, esc));

    buffer.writeln('</body></html>');
    return buffer.toString();
  }

  /// Scatter of tokens_total (median, x) vs weighted_score (mean, y).
  String _paretoSvg(List<String> agents, AggregateRow? Function(String, String, String) row, String Function(String) esc) {
    const width = 520.0, height = 260.0, pad = 45.0;
    final points = <(String, double, double)>[
      for (final agent in agents)
        if (row(agent, '*', 'tokens_total') != null && row(agent, '*', 'weighted_score') != null)
          (agent, row(agent, '*', 'tokens_total')!.median, row(agent, '*', 'weighted_score')!.mean),
    ];
    if (points.isEmpty) return '<p class="meta">no data</p>';
    final maxTokens = points.map((p) => p.$2).reduce((a, b) => a > b ? a : b);
    final scaleX = maxTokens == 0 ? 0 : (width - 2 * pad) / maxTokens;

    final svg =
        StringBuffer(
            '<svg width="$width" height="$height" role="img" '
            'style="border:1px solid #cbd5e0">',
          )
          ..writeln(
            '<line x1="$pad" y1="${height - pad}" x2="${width - pad}" '
            'y2="${height - pad}" stroke="#4a5568"/>',
          )
          ..writeln(
            '<line x1="$pad" y1="$pad" x2="$pad" y2="${height - pad}" '
            'stroke="#4a5568"/>',
          )
          ..writeln(
            '<text x="${width / 2}" y="${height - 8}" font-size="11" '
            'text-anchor="middle" fill="#4a5568">tokens_total (median)</text>',
          )
          ..writeln(
            '<text x="14" y="${height / 2}" font-size="11" '
            'text-anchor="middle" fill="#4a5568" '
            'transform="rotate(-90 14 ${height / 2})">weighted_score</text>',
          );
    for (final (agent, tokens, score) in points) {
      final x = pad + tokens * scaleX;
      final y = (height - pad) - score * (height - 2 * pad);
      svg
        ..writeln('<circle cx="$x" cy="$y" r="5" fill="#3182ce"/>')
        ..writeln(
          '<text x="${x + 8}" y="${y + 4}" font-size="11">'
          '${esc(agent)}</text>',
        );
    }
    svg.writeln('</svg>');
    return svg.toString();
  }
}
