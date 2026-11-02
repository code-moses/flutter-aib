import 'dart:io';

import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:aib_flutter/aib_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:todo_app/src/aib/todo_environment.dart';
import 'package:todo_app/src/app/todo_app.dart';
import 'package:todo_app/src/app/ui_state.dart';
import 'package:todo_app/src/app/use_cases.dart';
import 'package:todo_app/src/data/todo_store.dart';
import 'package:todo_app/src/semantics_quality.dart';

/// Widget-test harness for M2 (ADR 0004): boots the real todo app, wires the
/// FlutterEnvironment and lets the BenchmarkEngine drive it — headless,
/// deterministic, CI-capable.
final class TodoHarness {
  TodoHarness._(this.store, this.environment, this.screenKey);

  final TodoStore store;
  final FlutterEnvironment environment;

  /// Repaint boundary around the whole app — the screenshot source for the
  /// vision modality (`screen.capture`, M6).
  final GlobalKey screenKey;

  static Future<TodoHarness> boot(
    WidgetTester tester, {
    SemanticsQuality quality = .good,
    SemanticsBridge? semantics,
    FrameAttribution? frames,
  }) async {
    final store = TodoStore();
    final useCases = TodoUseCases(store);
    final uiState = UiState();
    final navigatorKey = GlobalKey<NavigatorState>();
    final screenKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: screenKey,
        child: TodoApp(store: store, useCases: useCases, uiState: uiState, navigatorKey: navigatorKey, quality: quality),
      ),
    );
    final environment = buildTodoEnvironment(
      store: store,
      useCases: useCases,
      uiState: uiState,
      navigatorKey: navigatorKey,
      settle: () async => tester.pumpAndSettle(),
      quality: quality,
      semantics: semantics,
      frames: frames,
    );
    return TodoHarness._(store, environment, screenKey);
  }
}

/// Loads the real Roboto/MaterialIcons fonts into the test binding.
///
/// `flutter_test` renders every glyph as a filled box by default, which is
/// irrelevant for semantics- or intent-driven agents but fatal for a
/// *vision* agent: it would be asked to read text that was never drawn.
/// The fonts come from the pinned SDK itself (`.fvmrc`), so no asset is
/// vendored into the repo. Returns false when the SDK cache cannot be
/// located — callers skip the vision path in that case.
Future<bool> loadRealFonts() async {
  final sdkRoot = _flutterSdkRoot();
  if (sdkRoot == null) return false;
  final fontDir = Directory(p.join(sdkRoot, 'bin', 'cache', 'artifacts', 'material_fonts'));
  if (!fontDir.existsSync()) return false;

  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final file in files) {
      final bytes = File(p.join(fontDir.path, file)).readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  await load('Roboto', const ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']);
  await load('MaterialIcons', const ['MaterialIcons-Regular.otf']);
  return true;
}

/// The SDK the test is running under: `dart` lives in
/// `<sdk>/bin/cache/dart-sdk/bin/`.
String? _flutterSdkRoot() {
  final fromEnv = Platform.environment['FLUTTER_ROOT'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  var dir = p.dirname(Platform.resolvedExecutable);
  for (var i = 0; i < 4; i++) {
    dir = p.dirname(dir);
  }
  return Directory(p.join(dir, 'bin', 'cache', 'artifacts')).existsSync() ? dir : null;
}

/// Loads the real todo_v1 suite from the repo (cwd of `flutter test` is the
/// package root `apps/todo_app`).
TaskSuite loadTodoSuite() {
  final path = [
    '../../suites/todo_v1.yaml',
    'suites/todo_v1.yaml',
  ].firstWhere((p) => File(p).existsSync(), orElse: () => throw StateError('todo_v1.yaml not found from ${Directory.current}'));
  final result = SuiteLoader.loadFile(path);
  if (!result.isValid) {
    throw StateError('todo_v1.yaml invalid:\n${result.errors.join('\n')}');
  }
  return result.suite!;
}

EpisodeMeta episodeMeta(String taskId, String agentId, {int repetition = 1}) => EpisodeMeta(
  runId: 'm2-widget-test',
  episodeId: BenchmarkRunner.episodeId(taskId, agentId, repetition),
  taskId: taskId,
  agentId: agentId,
  environmentId: 'todo_app',
  repetition: repetition,
  startedAt: DateTime.now(),
);

Future<({EpisodeRecord record, EpisodeTrace trace})> runScripted({
  required TodoHarness harness,
  required TaskSpec task,
  required List<Envelope> script,
  required String agentId,
}) async {
  final agent = ScriptedAgent(agentId: agentId, scripts: {task.id: script});
  final result = await BenchmarkEngine().runEpisode(task: task, agent: agent, environment: harness.environment, meta: episodeMeta(task.id, agentId));
  // Full persistence round trip, exactly like a real run (P6).
  final trace = TraceCodec.decode(TraceCodec.encode(result.trace));
  final record = await RunEvaluation().evaluateEpisode(trace, task);
  return (record: record, trace: trace);
}

/// The semantics bridge with the opt-in checks `AIB_SEMANTICS_CHECKS` names
/// (comma-separated: staleRefCheck, actionabilityGate, candidateActions);
/// null when it names none, which installs the bridge as before.
SemanticsBridge? semanticsBridgeFromEnvironment(Map<String, String> env) {
  final checks = {for (final name in (env['AIB_SEMANTICS_CHECKS'] ?? '').split(',')) name.trim()}..remove('');
  const known = {'staleRefCheck', 'actionabilityGate', 'candidateActions'};
  final unknown = checks.difference(known);
  if (unknown.isNotEmpty) throw ArgumentError('AIB_SEMANTICS_CHECKS: unknown ${unknown.join(', ')} (known: ${known.join(', ')})');
  if (checks.isEmpty) return null;
  return SemanticsBridge(
    staleRefCheck: checks.contains('staleRefCheck'),
    actionabilityGate: checks.contains('actionabilityGate'),
    candidateActions: checks.contains('candidateActions'),
  );
}

/// Frame attribution when `AIB_FRAME_ATTRIBUTION` is set.
FrameAttribution? framesFromEnvironment(Map<String, String> env) => (env['AIB_FRAME_ATTRIBUTION'] ?? '').isEmpty ? null : FrameAttribution();
