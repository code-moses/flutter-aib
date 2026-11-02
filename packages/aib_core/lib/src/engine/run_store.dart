import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../common/json.dart';
import '../evaluation/judge_provenance.dart';
import '../evaluation/verdict.dart';
import '../trace/trace.dart';
import 'provenance.dart';
import 'run_manifest.dart';

/// Persistence layout of a run directory (spec §9):
///   run_manifest.json · traces/*.jsonl · verdicts.json · metrics.csv
final class RunStore {
  RunStore(this.directory);

  final Directory directory;

  static const manifestFile = 'run_manifest.json';
  static const tracesDir = 'traces';
  static const verdictsFile = 'verdicts.json';
  static const metricsFile = 'metrics.csv';

  static const _encoder = JsonEncoder.withIndent('  ');

  void writeManifest(RunManifest manifest) {
    directory.createSync(recursive: true);
    _writeAtomically(p.join(directory.path, manifestFile), _encoder.convert(manifest.toJson()));
  }

  /// Writes to a sibling file and renames it into place, so a run killed
  /// mid-write leaves the previous file or none — never half of one.
  static void _writeAtomically(String path, String content) {
    final file = File(path)..parent.createSync(recursive: true);
    final temporary = File('$path.tmp')..writeAsStringSync(content, flush: true);
    temporary.renameSync(file.path);
  }

  RunManifest readManifest() => RunManifest.fromJson(asJsonMap(jsonDecode(File(p.join(directory.path, manifestFile)).readAsStringSync())));

  /// Manifest of a previous run in this directory, or `null` if the directory
  /// is fresh or the manifest is unreadable (basis of resuming, §5.2).
  RunManifest? readManifestOrNull() {
    final file = File(p.join(directory.path, manifestFile));
    if (!file.existsSync()) return null;
    try {
      return readManifest();
    } catch (_) {
      return null;
    }
  }

  void writeTrace(EpisodeTrace trace) => _writeAtomically(traceFilePath(trace.meta.episodeId), TraceCodec.encode(trace));

  String traceFilePath(String episodeId) => p.join(directory.path, tracesDir, '$episodeId.jsonl');

  /// Persisted trace of a single episode, or `null` when it does not exist or
  /// is truncated (a run killed mid-write must not look finished).
  EpisodeTrace? readTraceOrNull(String episodeId) {
    final file = File(traceFilePath(episodeId));
    if (!file.existsSync()) return null;
    try {
      return TraceCodec.decode(file.readAsStringSync());
    } catch (_) {
      return null;
    }
  }

  /// Every readable trace. A file that does not decode — a run killed
  /// before atomic writes, a stray file — is reported to [onUnreadable] and
  /// skipped rather than failing the whole evaluation.
  List<EpisodeTrace> readTraces({void Function(String path, Object error)? onUnreadable}) {
    final dir = Directory(p.join(directory.path, tracesDir));
    if (!dir.existsSync()) return const [];
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl')).toList()..sort((a, b) => a.path.compareTo(b.path));
    final traces = <EpisodeTrace>[];
    for (final file in files) {
      try {
        traces.add(TraceCodec.decode(file.readAsStringSync()));
      } on FormatException catch (e) {
        onUnreadable?.call(file.path, e);
      } on TypeError catch (e) {
        onUnreadable?.call(file.path, e);
      }
    }
    return traces;
  }

  /// `verdicts.json` = `{judge?: …, verdicts: {episodeId: verdict}}`.
  /// [judge] records who produced any rubric scores;
  /// omitting it means the run contains no LLM-judged criteria.
  /// [scoredWith] is the framework revision that computed the verdicts.
  void writeVerdicts(
    Map<String, Verdict> verdictsByEpisode, {
    JudgeProvenance? judge,
    SourceRevision? scoredWith,
    List<String> metricProviders = const [],
  }) {
    _writeAtomically(
      p.join(directory.path, verdictsFile),
      _encoder.convert({
        if (judge != null) 'judge': judge.toJson(),
        if (scoredWith != null) 'scoredWith': scoredWith.toJson(),
        if (metricProviders.isNotEmpty) 'metricProviders': metricProviders,
        'verdicts': verdictsByEpisode.map((episodeId, verdict) => MapEntry(episodeId, verdict.toJson())),
      }),
    );
  }

  Map<String, Verdict> readVerdicts() {
    final verdicts = asJsonMap(_readVerdictsJson()?['verdicts']);
    return {for (final entry in verdicts.entries) entry.key: Verdict.fromJson(asJsonMap(entry.value))};
  }

  /// Judge that produced the rubric scores of this run, if any.
  JudgeProvenance? readJudgeProvenance() {
    final judge = _readVerdictsJson()?['judge'];
    return judge == null ? null : JudgeProvenance.fromJson(asJsonMap(judge));
  }

  JsonMap? _readVerdictsJson() {
    final file = File(p.join(directory.path, verdictsFile));
    if (!file.existsSync()) return null;
    return asJsonMap(jsonDecode(file.readAsStringSync()));
  }

  void writeMetricsCsv(String csv) {
    File(p.join(directory.path, metricsFile)).writeAsStringSync(csv);
  }
}
