import 'dart:convert';
import 'dart:io';

import 'package:aib_cli/aib_cli.dart';
import 'package:aib_core/aib_core.dart';
import 'package:path/path.dart' as p;

import 'run_reader.dart' show Json, jsonObject, readHoldout;

/// Judge calibration sets for the Label view: the folder `aib labelsheet`
/// writes (`sample.json`, `labels.csv`, `labels.md`), read and written in
/// place, so `aib calibrate` and the UI work on the same files.
///
/// A set is any folder holding a `sample.json` that names `runs` and
/// `episodes`. Labels stay in `labels.csv` in the format `aib calibrate`
/// reads; notes go to `labels.notes.json` next to it, because a comma in a
/// note would break a CSV row the parser splits on commas.
final class Labelling {
  Labelling({required this.root, this.showHoldout = false, this.service = const AibService()});

  /// Where relative run paths in `sample.json` resolve: the checkout the set
  /// was built in.
  final String root;
  final bool showHoldout;
  final AibService service;

  static const sampleFile = 'sample.json';
  static const labelsFile = 'labels.csv';
  static const notesFile = 'labels.notes.json';

  static bool isSet(String dir) => File(p.join(dir, sampleFile)).existsSync();

  /// Every set at most [depth] levels below [library].
  List<Json> listSets(String library, {int depth = 3}) {
    final found = <String>[];
    void walk(Directory dir, int level) {
      if (isSet(dir.path)) found.add(dir.path);
      if (level >= depth) return;
      try {
        for (final e in dir.listSync(followLinks: false)) {
          if (e is Directory && !p.basename(e.path).startsWith('.') && !File(p.join(e.path, 'run_manifest.json')).existsSync()) walk(e, level + 1);
        }
      } on FileSystemException {
        // unreadable folder: nothing listed from it
      }
    }

    walk(Directory(library), 0);
    return [for (final dir in found..sort()) _summary(dir, library)];
  }

  Json _summary(String dir, String library) {
    final sample = _sample(dir);
    final labels = _labels(dir);
    final calibration = File(p.join(dir, 'calibration.json'));
    return {
      'path': dir,
      'name': p.relative(dir, from: library),
      'runs': sample['runs'],
      'episodes': (sample['episodes'] as List?)?.length ?? 0,
      'judges': sample['judges'],
      'seed': sample['seed'],
      'population': sample['population'],
      'answers': labels.length,
      'answered': labels.values.where((v) => v != '?').length,
      'calibratedAt': calibration.existsSync() ? calibration.lastModifiedSync().toIso8601String() : null,
    };
  }

  /// A new set over [runs]: the seeded, stratified sample `aib labelsheet`
  /// draws, written to [out].
  Json create({required List<String> runs, required String out, int? sample, int seed = 42}) {
    if (runs.isEmpty) throw const AibError('pick at least one judged run');
    final outcome = service.labelSheet([for (final r in runs) _abs(r)], out: _abs(out), sample: sample, seed: seed);
    return {
      'path': outcome.outDir,
      'episodes': outcome.sample.length,
      'criteria': outcome.criteria,
      'population': outcome.population,
      'warnings': outcome.warnings,
    };
  }

  /// Everything the Label view shows for one set: per episode the task, what
  /// the agent said, the record the judge was given, the questions, the
  /// judge's answers and the labels so far.
  Json load(String dir) {
    if (!isSet(dir)) throw FileSystemException('not a calibration set (no $sampleFile)', dir);
    final sample = _sample(dir);
    final runs = [for (final r in sample['runs'] as List? ?? const []) '$r'];
    final wanted = {for (final e in sample['episodes'] as List? ?? const []) '$e'};
    final labels = _labels(dir);
    final notes = _notes(dir);
    final names = [for (final r in runs) p.basename(p.normalize(r))];
    final items = <Json>[];
    final warnings = <String>[];
    for (final (index, run) in runs.indexed) {
      final runDir = _abs(run);
      if (!Directory(runDir).existsSync()) {
        warnings.add('run $run is missing: its episodes are not shown');
        continue;
      }
      final store = RunStore(Directory(runDir));
      final manifest = store.readManifest();
      final judge = store.readJudgeProvenance();
      final suitePath = manifest.suitePath == null
          ? null
          : AibService.locateSuite(manifest.suitePath!, runDir, suiteHash: manifest.suiteHash, judgedRubrics: judge?.rubrics ?? const {});
      if (suitePath == null) {
        warnings.add('the suite of $run was not found');
        continue;
      }
      final loaded = SuiteLoader.loadFile(suitePath, assertionKinds: AibService.knownAssertionKinds);
      if (!loaded.isValid) {
        warnings.add('the suite of $run does not load: ${loaded.errors.first}');
        continue;
      }
      final suite = loaded.suite!;
      final missing = AibService.rubricsMissingFrom(suite, judge);
      if (missing.isNotEmpty) {
        warnings.add(
          '$run: the judge answered ${missing.join(', ')} in a wording the suite at $suitePath does not carry; those questions are missing',
        );
      } else if (suite.sourceHash != manifest.suiteHash) {
        warnings.add('$run: the suite changed since the run; the questions shown are the current ones');
      }
      final holdout = readHoldout(suitePath, suite.name);
      final verdicts = store.readVerdicts();
      final traces = [
        for (final t in store.readTraces())
          if (wanted.contains(labelIdOf(names[index], t.meta.episodeId, runCount: runs.length))) t,
      ];
      for (final item in judgedEpisodes(runName: names[index], runCount: runs.length, traces: traces, verdicts: verdicts, suite: suite)) {
        items.add(
          _item(
            item,
            runDir: runDir,
            verdict: verdicts[item.trace.meta.episodeId],
            manifest: manifest,
            hidden: !showHoldout && holdout.contains(item.task.id),
            labels: labels,
            notes: notes,
          ),
        );
      }
    }
    final order = [for (final e in sample['episodes'] as List? ?? const []) '$e'];
    items.sort((a, b) => order.indexOf('${a['labelId']}').compareTo(order.indexOf('${b['labelId']}')));
    final missing = wanted.difference({for (final i in items) '${i['labelId']}'});
    if (missing.isNotEmpty) {
      final shown = missing.take(5).join(', ');
      warnings.add('${missing.length} sampled episode(s) not found or no longer judged: $shown${missing.length > 5 ? ', …' : ''}');
    }
    final calibration = File(p.join(dir, 'calibration.json'));
    return {
      ..._summary(dir, p.dirname(dir)),
      'items': items,
      'warnings': warnings,
      'calibration': calibration.existsSync() ? jsonDecode(calibration.readAsStringSync()) : null,
    };
  }

  Json _item(
    LabelItem item, {
    required String runDir,
    required Verdict? verdict,
    required RunManifest manifest,
    required bool hidden,
    required Map<String, String> labels,
    required Map<String, Object?> notes,
  }) {
    final judged = <String, JsonMap>{
      for (final detail in verdict?.detailsOfType(CriterionTypes.artifactRubric) ?? const <JsonMap>[])
        if (detail['rubric'] is String) detail['rubric'] as String: detail,
    };
    final trace = item.trace;
    final turns = [
      for (final e in trace.events)
        if (e.type == TraceEventTypes.userTurn)
          {'when': 'after done', 'id': e.data['id'], 'text': e.data['instruction'], 'simulated': e.data['simulated'] == true}
        else if (e.type == TraceEventTypes.userSteer)
          {'when': 'while working', 'id': e.data['id'], 'text': e.data['message'], 'delivered': e.data['delivered'] == true},
    ];
    final end = trace.firstOfType(TraceEventTypes.episodeEnd)?.data ?? const {};
    final agent = manifest.agents[trace.meta.agentId];
    return {
      'labelId': item.labelId,
      'run': item.runName,
      // What the trace endpoint needs: the run's folder and its parent.
      'runDir': runDir,
      'traceLibrary': p.dirname(runDir),
      'episodeId': trace.meta.episodeId,
      'taskId': item.task.id,
      'title': hidden ? null : item.task.title,
      'instruction': hidden ? null : item.task.instruction,
      'holdout': hidden,
      'agentId': trace.meta.agentId,
      'model': asJsonMap(agent?['metadata'])['model'],
      'repetition': trace.meta.repetition,
      'endReason': trace.endReason,
      'endMessage': end['message'],
      'turns': hidden ? const [] : turns,
      'verdict': verdict == null ? null : {'type': verdict.type.name, 'score': verdict.score},
      'rubrics': [
        for (final r in item.rubrics)
          {
            'name': r.rubric.name,
            'scope': r.rubric.scope,
            'criteria': [
              for (final c in r.rubric.criteria)
                {
                  'id': c.id,
                  'key': '${r.rubric.name}:${c.id}',
                  'question': c.question.trim(),
                  'weight': c.weight,
                  'label': labels['${item.labelId},${r.rubric.name}:${c.id}'],
                },
            ],
            'artifact': r.artifact,
            'evidence': r.evidence,
            'judge': switch (judged[r.rubric.name]) {
              final d? => {'votes': d['votes'], 'k': d['k'], 'answers': d['answers'], 'rationales': d['rationales'], 'judgeId': d['judgeId']},
              null => null,
            },
          },
      ],
      'note': notes[item.labelId],
    };
  }

  /// Sets one answer (`yes`, `no` or `?`) in `labels.csv`, and the episode's
  /// note when given. Returns the set's counts after the write.
  Json save(String dir, {required String labelId, String? criterion, String? label, String? note}) {
    if (!isSet(dir)) throw FileSystemException('not a calibration set', dir);
    if (labelId.contains(',') || labelId.contains('\n') || (criterion?.contains(',') ?? false)) throw ArgumentError('bad id');
    if (criterion != null) {
      final value = label?.trim().toLowerCase();
      if (value != 'yes' && value != 'no' && value != '?') throw ArgumentError('label must be yes, no or ?');
      final file = File(p.join(dir, labelsFile));
      final lines = file.existsSync() ? file.readAsLinesSync() : <String>[];
      final prefix = '$labelId,$criterion,';
      final at = lines.indexWhere((l) => l.trim().startsWith(prefix));
      if (at < 0) {
        lines.add('$prefix$value');
      } else {
        lines[at] = '$prefix$value';
      }
      file.writeAsStringSync('${lines.join('\n')}\n');
    }
    if (note != null) {
      final notes = _notes(dir);
      if (note.trim().isEmpty) {
        notes.remove(labelId);
      } else {
        notes[labelId] = note;
      }
      File(p.join(dir, notesFile)).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(notes));
    }
    final labels = _labels(dir);
    return {'answers': labels.length, 'answered': labels.values.where((v) => v != '?').length};
  }

  /// `aib calibrate` over the set's runs and labels, written into the set.
  Future<Json> calibrate(String dir) async {
    final sample = _sample(dir);
    final runs = [for (final r in sample['runs'] as List? ?? const []) _abs('$r')];
    final unanswered = _labels(dir).values.where((v) => v == '?').length;
    if (unanswered > 0) throw AibError('$unanswered answer(s) still open; calibration needs every row answered');
    final outcome = await service.calibrate(runs, labels: p.join(dir, labelsFile), out: dir);
    return {'markdown': outcome.markdown, 'json': outcome.json, 'missing': outcome.missing};
  }

  String _abs(String path) => p.normalize(p.isAbsolute(path) ? path : p.join(root, path));

  Json _sample(String dir) {
    return jsonObject(jsonDecode(File(p.join(dir, sampleFile)).readAsStringSync()));
  }

  /// `labelId,rubric:criterion` -> `yes` / `no` / `?`, in file order.
  Map<String, String> _labels(String dir) {
    final file = File(p.join(dir, labelsFile));
    if (!file.existsSync()) return {};
    final out = <String, String>{};
    for (final raw in file.readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split(',');
      if (parts.length < 3) continue;
      out['${parts[0].trim()},${parts[1].trim()}'] = parts[2].trim().toLowerCase();
    }
    return out;
  }

  Map<String, Object?> _notes(String dir) {
    final file = File(p.join(dir, notesFile));
    if (!file.existsSync()) return {};
    return jsonObject(jsonDecode(file.readAsStringSync()));
  }
}
