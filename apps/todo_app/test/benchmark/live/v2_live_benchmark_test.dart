import 'dart:io';

import 'package:aib_cli/aib_cli.dart';
import 'package:aib_core/aib_core.dart';
import 'package:aib_otel/aib_otel.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart' show framesFromEnvironment, semanticsBridgeFromEnvironment;
import '../workspace_harness.dart';

/// Live runs of `todo_v2` against the workspace app, with agents built from
/// `suites/agents/*.yaml` through the same registry `aib run` uses — so every
/// configured arm (hybrid, prepared_*, intent, semantics) runs here, as on
/// SYSco. Execution only; score with `aib evaluate` afterwards (P6):
///
/// ```sh
/// AIB_AGENT=../../suites/agents/todo_v2_prepared_lexical.yaml \
/// AIB_AGENTS=prepared AIB_REPS=1 AIB_OUT=../../results/todo-v2-run \
///   fvm flutter test test/benchmark/live/v2_live_benchmark_test.dart
/// fvm dart run aib_cli:aib evaluate --run results/todo-v2-run \
///   --judge suites/agents/ollama_judge.yaml --metrics intents,prefetch
/// ```
///
/// `AIB_TASKS` narrows the suite; a run resumes into an existing directory.
void main() {
  final env = Platform.environment;
  final configPath = env['AIB_AGENT'];

  testWidgets(
    'todo_v2 live run',
    (tester) async {
      HttpOverrides.global = null; // flutter_test blocks real HTTP
      final handle = tester.ensureSemantics();
      final harness = await WorkspaceHarness.boot(tester, semantics: semanticsBridgeFromEnvironment(env), frames: framesFromEnvironment(env));
      var suite = loadWorkspaceSuite();
      final only = (env['AIB_TASKS'] ?? '').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();
      if (only.isNotEmpty) {
        suite = TaskSuite(
          name: suite.name,
          schema: suite.schema,
          defaultRepetitions: suite.defaultRepetitions,
          tasks: [
            for (final task in suite.tasks)
              if (only.contains(task.id)) task,
          ],
          sourcePath: suite.sourcePath,
          sourceHash: suite.sourceHash,
        );
      }
      expect(suite.tasks, isNotEmpty, reason: 'AIB_TASKS matched no task');

      final config = Builtins.loadConfig(configPath);
      final registry = Builtins.agentRegistry();
      final agents = {for (final name in (env['AIB_AGENTS'] ?? 'hybrid').split(',')) name.trim(): registry.create(name.trim(), config)};
      final out = Directory(env['AIB_OUT'] ?? '../../results/todo-v2-${DateTime.now().toIso8601String().replaceAll(':', '-')}');

      // `AIB_OTEL=<OTLP/HTTP traces endpoint>` exports every episode as spans,
      // as `aib run --otel` does; `AIB_OTEL_CAPTURE_CONTENT=1` adds payloads.
      final otel = (env['AIB_OTEL'] ?? '').trim();
      await tester.runAsync(() async {
        final observer = otel.isEmpty ? null : await OtelExport.start(otel, captureContent: (env['AIB_OTEL_CAPTURE_CONTENT'] ?? '').isNotEmpty);
        final runner = BenchmarkRunner(
          suite: suite,
          agents: agents,
          environment: harness.environment,
          store: RunStore(out),
          repetitionsOverride: int.tryParse(env['AIB_REPS'] ?? ''),
          pricing: PriceTable.fromJson(Builtins.loadConfig(suitesPath('pricing_2026_09.yaml'))),
          observer: observer,
          onEpisode: (meta, result) =>
              // ignore: avoid_print
              print('  ${meta.episodeId}: ${result.outcome.reason.name}'),
          onSkipped: (meta, _) =>
              // ignore: avoid_print
              print('  ${meta.episodeId}: reused'),
        );
        try {
          final manifest = await runner.run();
          // ignore: avoid_print
          print('run ${manifest.runId} written to ${out.path}');
        } finally {
          if (observer != null) await OtelExport.shutdown();
        }
      });
      handle.dispose();
    },
    // Gated: set AIB_AGENT=<suites/agents/*.yaml> to run todo_v2 live.
    skip: configPath == null,
    timeout: const Timeout(Duration(hours: 4)),
  );
}
