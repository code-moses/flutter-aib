import 'dart:io';

import 'package:aib_core/aib_core.dart';
import 'package:aib_flutter/aib_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/src/aib/workspace_environment.dart';
import 'package:todo_app/src/workspace/navigation.dart';
import 'package:todo_app/src/workspace/store.dart';
import 'package:todo_app/src/workspace/use_cases.dart';
import 'package:todo_app/src/workspace/workspace_app.dart';

/// Boots the workspace app (suite `todo_v2`) headless and wires its
/// FlutterEnvironment, as [TodoHarness] does for v1.
final class WorkspaceHarness {
  WorkspaceHarness._(this.store, this.nav, this.environment, this.screenKey);

  final WorkspaceStore store;
  final WorkspaceNav nav;
  final FlutterEnvironment environment;

  /// Repaint boundary around the app — the vision modality's screenshot.
  final GlobalKey screenKey;

  static Future<WorkspaceHarness> boot(WidgetTester tester, {SemanticsBridge? semantics, FrameAttribution? frames}) async {
    final store = WorkspaceStore();
    final useCases = WorkspaceUseCases(store);
    final nav = WorkspaceNav();
    final screenKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: screenKey,
        child: WorkspaceApp(store: store, useCases: useCases, nav: nav),
      ),
    );
    final environment = buildWorkspaceEnvironment(
      store: store,
      useCases: useCases,
      nav: nav,
      settle: () async => tester.pumpAndSettle(),
      semantics: semantics,
      frames: frames,
    );
    return WorkspaceHarness._(store, nav, environment, screenKey);
  }
}

/// A file under the repo's `suites/`, found from the package root (the cwd of
/// `flutter test`) or the repo root.
String suitesPath(String relative) => [
  '../../suites/$relative',
  'suites/$relative',
].firstWhere((p) => File(p).existsSync(), orElse: () => throw StateError('suites/$relative not found from ${Directory.current.path}'));

TaskSuite loadWorkspaceSuite() {
  final result = SuiteLoader.loadFile(suitesPath('todo_v2.yaml'));
  if (!result.isValid) {
    throw StateError('todo_v2.yaml invalid:\n${result.errors.join('\n')}');
  }
  return result.suite!;
}
