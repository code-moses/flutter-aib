/// M6 — a *foreign* agent drives the app: Python, another modality
/// (screenshots + taps), attached over the stdio wire protocol. The core
/// stays untouched; the engine cannot tell this agent from an in-process one
/// (spec §7 VisionAgent, §11 Phase 6).
///
///   AIB_VISION=1 [AIB_VISION_MODEL=qwen2.5vl:7b] \
///     flutter test test/benchmark/live/m6_vision_agent_test.dart
///
/// Optional: AIB_TASKS (default todo.complete.single), AIB_REPS (default 1),
/// AIB_OUT (run directory), AIB_VISION_DEBUG=1 (agent decisions to stderr).
library;

import 'dart:io';

import 'package:aib_core/aib_core.dart';
import 'package:aib_flutter/aib_flutter.dart';
import 'package:aib_protocol/aib_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

void main() {
  final env = Platform.environment;
  final live = env['AIB_VISION'] == '1';

  testWidgets(
    'M6: external Python vision agent drives the todo app '
    'over the stdio protocol',
    (tester) async {
      HttpOverrides.global = null;
      final handle = tester.ensureSemantics();

      expect(await loadRealFonts(), isTrue, reason: 'without real fonts the screenshots contain no readable text');

      final suite = loadTodoSuite();
      final taskIds = (env['AIB_TASKS'] ?? 'todo.complete.single').split(',').toList();
      final tasks = [for (final id in taskIds) suite.taskById(id) ?? (throw StateError('unknown task $id'))];

      final harness = await TodoHarness.boot(tester, semantics: semanticsBridgeFromEnvironment(env), frames: framesFromEnvironment(env));
      // The vision modality is installed *next to* the existing bridges: the
      // environment gains keys, nothing else in the app changes (§4.2
      // discovery — the agent finds them in the descriptor).
      VisionBridge(
        capture: () async {
          final boundary = harness.screenKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final data = await image.toByteData(format: .png);
          return CapturedScreen(pngBytes: data!.buffer.asUint8List(), width: boundary.size.width, height: boundary.size.height, devicePixelRatio: 2);
        },
        tapAt: (x, y) async {
          await tester.tapAt(Offset(x, y));
          await tester.pumpAndSettle();
        },
        enterText: (text) async {
          // Type where the *user* would: into the focused field. Falling back
          // to "the first text field on screen" would silently repair a
          // mis-aimed tap and credit the agent with precision it did not have.
          final focused = find.byWidgetPredicate((w) => w is EditableText && w.focusNode.hasFocus);
          if (focused.evaluate().isEmpty) {
            throw StateError('no text field is focused — tap one first');
          }
          await tester.enterText(focused.first, text);
          await tester.pumpAndSettle();
        },
      ).install(harness.environment);

      final outDir = Directory(env['AIB_OUT'] ?? '../../results/m6-vision');
      final store = RunStore(outDir);

      await tester.runAsync(() async {
        final transport = await SubprocessTransport.spawn('python3', ['../../agents/vision_python/vision_agent.py']);
        final agent = await RemoteAgent.connect(transport);
        expect(agent.manifest.agentId, 'vision');
        expect(agent.manifest.metadata['language'], 'python');

        final runner = BenchmarkRunner(
          suite: TaskSuite(
            name: suite.name,
            schema: suite.schema,
            defaultRepetitions: suite.defaultRepetitions,
            tasks: tasks,
            sourcePath: suite.sourcePath,
            sourceHash: suite.sourceHash,
          ),
          agents: {'vision': agent},
          environment: harness.environment,
          store: store,
          repetitionsOverride: int.tryParse(env['AIB_REPS'] ?? '') ?? 1,
          onEpisode: (meta, result) =>
              // ignore: avoid_print
              print(
                '  ${meta.episodeId}: ${result.outcome.reason.name} '
                '(${result.outcome.message ?? ''})',
              ),
        );
        final manifest = await runner.run();
        final records = await RunEvaluation().evaluateRun(store.readTraces(), suite);
        store.writeVerdicts({for (final record in records) record.episodeId: record.verdict});
        ReporterRegistry()['md']!.writeTo(RunReportData(manifest: manifest, records: records, aggregates: Aggregator().aggregate(records)), outDir);
        await transport.close();
        // ignore: avoid_print
        print('M6 vision run written to ${outDir.path}');
      });
      handle.dispose();
    },
    skip: !live,
    timeout: const Timeout(Duration(hours: 2)),
  );

  test('the Python agent answers the protocol handshake and manifest', () async {
    // Runs in CI without any model: proves the foreign agent speaks the
    // protocol (spec §4.5 conformance), independent of what it decides.
    final transport = await SubprocessTransport.spawn('python3', ['../../agents/vision_python/vision_agent.py']);
    final agent = await RemoteAgent.connect(transport);
    expect(agent.manifest.agentId, 'vision');
    expect(agent.manifest.version, 'vision_py_v3');
    expect(agent.manifest.metadata['transport'], 'stdio');

    await agent.startEpisode(
      const TaskSpec(
        id: 't',
        title: 't',
        instruction: 'do it',
        budget: Budget(maxSteps: 25, maxWallClockSeconds: 60),
        fixture: FixtureRef(id: 'baseline'),
      ),
      const EnvironmentDescriptor(
        environmentId: 'todo_app',
        envelopes: [
          EnvelopeSpec(key: 'screen.capture', kind: .observe),
          EnvelopeSpec(key: 'pointer.tap', kind: .act),
        ],
      ),
    );
    // First step is the deterministic bootstrap observation — no model call,
    // so this assertion holds with or without Ollama running.
    final first = await agent.next(null, const BudgetStatus(stepsUsed: 0, maxSteps: 25, elapsedMs: 0, maxWallClockMs: 60000, tokensUsed: 0));
    expect(first.key, 'screen.capture');
    expect(first.kind, EnvelopeKind.observe);
    await transport.close();
  }, skip: !Platform.isMacOS && !Platform.isLinux);
}
