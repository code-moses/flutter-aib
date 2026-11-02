// Episode duration with and without the OTel observer, interleaved so load
// on the machine hits both alike. Spans go to the in-memory exporter, so
// network export is not in the number.
//
// Run: fvm dart run tool/overhead.dart [repetitions]
import 'dart:io';

import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:aib_otel/aib_otel.dart';
import 'package:dartastic_opentelemetry/testing.dart' show maybeInitializeOtelForTest;

Future<void> main(List<String> args) async {
  final repetitions = args.isEmpty ? 20 : int.parse(args.first);
  final harness = await maybeInitializeOtelForTest();

  final task = TaskSpec(
    id: 't',
    title: 't',
    instruction: 'Create five todos.',
    budget: Budget(maxSteps: 50, maxWallClockSeconds: 60),
    fixture: const FixtureRef(
      id: 'f',
      data: {
        'db': {'todos': <Object>[]},
      },
    ),
  );
  final script = [
    for (var i = 0; i < 5; i++) ...[
      Envelope(
        key: 'state.insert',
        kind: .act,
        payload: {
          'path': 'db.todos',
          'item': {'title': 'Todo $i'},
        },
      ),
      const Envelope(key: 'state.list', kind: .observe, payload: {'path': 'db.todos'}),
    ],
  ];

  Future<int> episode(TraceObserver? observer, String id) async {
    final watch = Stopwatch()..start();
    await BenchmarkEngine(observer: observer).runEpisode(
      task: task,
      agent: ScriptedAgent(scripts: {'t': script}),
      environment: MockEnvironment(),
      meta: EpisodeMeta(
        runId: 'overhead',
        episodeId: id,
        taskId: 't',
        agentId: 'scripted',
        environmentId: 'mock',
        repetition: 1,
        startedAt: DateTime.now(),
      ),
    );
    return watch.elapsedMicroseconds;
  }

  await episode(null, 'warm-plain');
  await episode(OtelTraceObserver(), 'warm-otel');
  final plain = <int>[];
  final exported = <int>[];
  for (var i = 0; i < repetitions; i++) {
    plain.add(await episode(null, 'plain-$i'));
    exported.add(await episode(OtelTraceObserver(), 'otel-$i'));
    harness.spans.clear();
  }

  String median(List<int> values) => ((values..sort())[values.length ~/ 2] / 1000).toStringAsFixed(2);
  stdout
    ..writeln('$repetitions episodes each, ${script.length} envelopes')
    ..writeln('median ms without observer: ${median(plain)}')
    ..writeln('median ms with observer:    ${median(exported)}');
  exit(0);
}
