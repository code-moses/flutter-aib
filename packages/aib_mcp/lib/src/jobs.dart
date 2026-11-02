import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:aib_cli/aib_cli.dart';
import 'package:aib_core/aib_core.dart';
import 'package:path/path.dart' as p;

/// What a job is doing, as `aib_job_status` reports it.
enum JobState {
  queued,
  running,
  succeeded,
  failed,
  cancelled;

  bool get isFinal => this == succeeded || this == failed || this == cancelled;
}

/// A long operation: a run, a judged evaluation, a sweep. Tools start one and
/// return its id; `aib_job_status` / `aib_job_wait` follow it.
final class Job {
  Job({required this.id, required this.kind, required this.label, required this.hosts, this.maxUsd, this.runDir, this.total = 0, this.study});

  final String id;

  /// `run`, `evaluate`, `sweep`, `holdout`.
  final String kind;
  final String label;

  /// Model hosts it occupies while running.
  final Set<String> hosts;

  /// Spend at which the job is stopped; null for an unpriced job.
  final double? maxUsd;

  /// The run directory under the checkout, for run jobs.
  final String? runDir;
  final String? study;

  JobState state = .queued;
  final DateTime createdAt = DateTime.now();
  DateTime? startedAt;
  DateTime? endedAt;
  int done = 0;
  int total;
  double spendUsd = 0;
  String? error;

  /// Why a job ended before its work was done: `cancelled`, `budget`,
  /// `wall clock`.
  String? stopReason;
  JsonMap? result;

  final _log = <String>[];
  final _changes = StreamController<void>.broadcast();
  final _cancel = Completer<String>();

  /// Fires with the reason when the job is asked to stop.
  Future<String> get cancelled => _cancel.future;
  bool get isCancelling => _cancel.isCompleted;

  /// Emits whenever state, progress or spend moved.
  Stream<void> get changes => _changes.stream;

  static const _logLines = 500;

  void log(String line) {
    _log.add(line);
    if (_log.length > _logLines) _log.removeRange(0, _log.length - _logLines);
  }

  List<String> tail([int lines = 50]) => _log.sublist(_log.length > lines ? _log.length - lines : 0);

  void progress({int? done, int? total, double? spend}) {
    if (done != null) this.done = done;
    if (total != null) this.total = total;
    if (spend != null) spendUsd = spend;
    _changes.add(null);
  }

  void requestStop(String reason) {
    if (!_cancel.isCompleted) _cancel.complete(reason);
  }

  void _finish(JobState state, {String? error, JsonMap? result}) {
    this.state = state;
    this.error = error;
    this.result = result;
    endedAt = DateTime.now();
    _changes.add(null);
  }

  JsonMap toJson({PathFormatter? path}) => {
    'job': id,
    'kind': kind,
    'label': label,
    'state': state.name,
    'hosts': hosts.toList(),
    'runDir': ?(runDir == null ? null : (path ?? (s) => s)(runDir!)),
    'study': ?study,
    'episodes': {'done': done, 'total': total},
    'spendUsd': spendUsd,
    'maxUsd': ?maxUsd,
    'createdAt': createdAt.toIso8601String(),
    'startedAt': ?startedAt?.toIso8601String(),
    'endedAt': ?endedAt?.toIso8601String(),
    'stopReason': ?stopReason,
    'error': ?error,
    'result': ?result,
  };
}

typedef PathFormatter = String Function(String path);

/// What a job does once it holds its hosts. Returns the job's result;
/// throws to fail it. Must return promptly after [Job.cancelled] fires.
typedef JobBody = Future<JsonMap?> Function(Job job);

/// Queues and runs jobs, at most `concurrency` per model host at a time.
///
/// Latency metrics are only comparable when runs do not share a GPU, so a
/// second run against the same Ollama waits for the first even when the
/// machine could fit both. Jobs that touch no host start at once.
final class JobManager {
  JobManager({required Map<String, int> hostLimits, this.historyFile}) : _limits = hostLimits;

  final Map<String, int> _limits;

  /// Finished jobs are appended here as JSON lines: the record of what was
  /// run and spent, and the base of the daily budget.
  final File? historyFile;

  final _jobs = <String, Job>{};
  final _bodies = <String, JobBody>{};
  final _running = <String, Future<void>>{};
  var _next = 0;

  Iterable<Job> get jobs => _jobs.values;

  Job? operator [](String id) => _jobs[id];

  String newId() => 'job-${++_next}-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';

  Job submit(Job job, JobBody body) {
    _jobs[job.id] = job;
    _bodies[job.id] = body;
    job.log('queued${job.hosts.isEmpty ? '' : ' for ${job.hosts.join(', ')}'}');
    _schedule();
    return job;
  }

  /// Asks [id] to stop; a queued job is cancelled at once.
  Job cancel(String id, {String reason = 'cancelled'}) {
    final job = _jobs[id] ?? (throw AibError('no job "$id"'));
    if (job.state.isFinal) return job;
    job.stopReason = reason;
    job.requestStop(reason);
    if (job.state == .queued) {
      job._finish(JobState.cancelled);
      _record(job);
      _schedule();
    }
    return job;
  }

  /// Resolves when [job] ends, or after [timeout].
  Future<void> wait(Job job, Duration timeout) async {
    if (job.state.isFinal) return;
    await job.changes.firstWhere((_) => job.state.isFinal).timeout(timeout, onTimeout: () {});
  }

  int _inUse(String host) => _jobs.values.where((j) => j.state == .running && j.hosts.contains(host)).length;

  void _schedule() {
    for (final job in _jobs.values.where((j) => j.state == .queued).toList()) {
      if (job.hosts.every((h) => _inUse(h) < (_limits[h] ?? 1))) _start(job);
    }
  }

  void _start(Job job) {
    job
      ..state = .running
      ..startedAt = DateTime.now()
      ..log('started');
    job.progress();
    _running[job.id] = () async {
      try {
        final result = await _bodies[job.id]!(job);
        job._finish(job.isCancelling ? JobState.cancelled : JobState.succeeded, result: result);
      } on Object catch (error) {
        job.log('failed: $error');
        job._finish(job.isCancelling ? JobState.cancelled : JobState.failed, error: error is AibError ? error.message : '$error');
      } finally {
        _running.remove(job.id);
        _record(job);
        _schedule();
      }
    }();
  }

  void _record(Job job) {
    final file = historyFile;
    if (file == null) return;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('${jsonEncode(job.toJson())}\n', mode: FileMode.append);
  }

  /// What jobs spent today: the history plus what is running now.
  double spentToday() {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    var total = 0.0;
    final seen = <String>{};
    final file = historyFile;
    if (file != null && file.existsSync()) {
      for (final line in file.readAsLinesSync()) {
        try {
          final entry = asJsonMap(jsonDecode(line));
          if ('${entry['endedAt'] ?? entry['createdAt']}'.startsWith(today)) {
            total += (entry['spendUsd'] as num?)?.toDouble() ?? 0;
            seen.add('${entry['job']}');
          }
        } on FormatException {
          continue;
        }
      }
    }
    for (final job in _jobs.values) {
      if (!seen.contains(job.id)) total += job.spendUsd;
    }
    return total;
  }

  /// Stops everything and waits for cleanup, so no app keeps its benchmark
  /// inputs because the server went away.
  Future<void> shutdown() async {
    for (final job in _jobs.values.where((j) => !j.state.isFinal).toList()) {
      cancel(job.id, reason: 'server shutdown');
    }
    await Future.wait(_running.values);
  }
}

// Bodies

/// Runs [command], streaming its output into [job]'s log, until it exits or
/// the job is asked to stop — then the whole process tree is terminated.
/// Returns the exit code; null when stopped.
Future<int?> runProcess(Job job, List<String> command, {String? cwd, Map<String, String> env = const {}, void Function(String line)? onLine}) async {
  job.log('\$ ${command.join(' ')}');
  final process = await Process.start(command.first, command.skip(1).toList(), workingDirectory: cwd, environment: env);
  void pump(Stream<List<int>> stream) => stream.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    job.log(line);
    onLine?.call(line);
  });
  pump(process.stdout);
  pump(process.stderr);
  final exit = process.exitCode;
  final outcome = await Future.any<Object?>([exit, job.cancelled]);
  if (outcome is int) return outcome;
  job.log('stopping: $outcome');
  await killTree(process.pid);
  await exit.timeout(const Duration(seconds: 15), onTimeout: () => -1);
  return null;
}

/// SIGTERM to [pid] and every descendant (a `flutter test` starts the tool,
/// a tester and the app), then SIGKILL to whatever is left.
Future<void> killTree(int pid) async {
  Future<List<int>> tree() async {
    final ps = await Process.run('ps', ['-A', '-o', 'pid=,ppid=']);
    final children = <int, List<int>>{};
    for (final line in '${ps.stdout}'.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length != 2) continue;
      children.putIfAbsent(int.parse(parts[1]), () => []).add(int.parse(parts[0]));
    }
    final all = <int>[];
    void walk(int node) {
      for (final child in children[node] ?? const <int>[]) {
        walk(child);
      }
      all.add(node);
    }

    walk(pid);
    return all;
  }

  final pids = await tree();
  for (final id in pids) {
    Process.killPid(id, ProcessSignal.sigterm);
  }
  await Future<void>.delayed(const Duration(seconds: 5));
  for (final id in pids) {
    Process.killPid(id, ProcessSignal.sigkill);
  }
}

/// Follows a run directory while a runner writes it: episodes complete, and
/// what the new ones cost by [prices] — the same accounting `cost_usd`
/// uses. Episodes finished before [since] count as done but cost nothing:
/// they were reused, not run.
final class RunWatcher {
  RunWatcher(this.dir, {required this.prices, required this.since});

  final String dir;
  final PriceTable prices;
  final DateTime since;

  final _costed = <String, double>{};
  final _done = <String>{};

  late final _metrics = MetricsRegistry.builtin(pricing: prices);

  int get done => _done.length;
  double get spend => _costed.values.fold(0, (a, b) => a + b);

  void poll() {
    final traces = Directory(p.join(dir, RunStore.tracesDir));
    if (!traces.existsSync()) return;
    for (final file in traces.listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl'))) {
      final id = p.basenameWithoutExtension(file.path);
      if (_done.contains(id)) continue;
      final EpisodeTrace trace;
      try {
        trace = TraceCodec.decode(file.readAsStringSync());
      } on FormatException {
        continue; // mid-write
      }
      if (!trace.isComplete) continue;
      _done.add(id);
      if (file.lastModifiedSync().isAfter(since)) {
        _costed[id] = _metrics.computeAll(_metrics.contextFor(trace))['cost_usd']?.toDouble() ?? 0;
      }
    }
  }
}

/// Copies [from] into [to], replacing files that changed.
void copyTree(String from, String to) {
  final source = Directory(from);
  if (!source.existsSync()) return;
  for (final entity in source.listSync(recursive: true).whereType<File>()) {
    final target = File(p.join(to, p.relative(entity.path, from: from)));
    if (target.existsSync() && target.lengthSync() == entity.lengthSync() && !entity.lastModifiedSync().isAfter(target.lastModifiedSync())) continue;
    target.parent.createSync(recursive: true);
    entity.copySync(target.path);
  }
}

/// Runs [work] in a fresh isolate of this process, so a stop request can
/// kill it mid-episode. [work] reports through its [SendPort] with
/// `{'log': line}`, `{'episode': id, 'reason': r}` and ends with
/// `{'result': json}` or `{'error': message}`.
Future<JsonMap?> runIsolate(Job job, void Function(SendPort port) work, {void Function(JsonMap message)? onMessage}) async {
  final port = ReceivePort();
  final exit = ReceivePort();
  final isolate = await Isolate.spawn(work, port.sendPort, onExit: exit.sendPort, errorsAreFatal: true);
  final done = Completer<JsonMap?>();
  port.listen((message) {
    final json = asJsonMap(message);
    if (json['log'] case final String line) job.log(line);
    if (json.containsKey('result') && !done.isCompleted) done.complete(asJsonMap(json['result']));
    if (json['error'] case final String error when !done.isCompleted) done.completeError(AibError(error));
    onMessage?.call(json);
  });
  exit.listen((_) {
    if (!done.isCompleted) done.completeError(const AibError('the run ended without a result'));
  });
  job.cancelled.then((reason) {
    isolate.kill(priority: Isolate.immediate);
    if (!done.isCompleted) done.complete(null);
  });
  try {
    return await done.future;
  } finally {
    port.close();
    exit.close();
  }
}
