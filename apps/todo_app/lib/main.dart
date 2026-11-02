import 'package:flutter/material.dart';

import 'src/app/todo_app.dart';
import 'src/app/ui_state.dart';
import 'src/app/use_cases.dart';
import 'src/data/todo_store.dart';

/// Standalone entry point for manual exploration. Benchmarks drive the app
/// through `buildTodoEnvironment` (see test/benchmark/).
///
/// Semantics variant: `flutter run --dart-define=SEMANTICS_QUALITY=good|bad`.
void main() {
  final store = TodoStore()
    ..seed(const {
      'db': {
        'todos': [
          {'id': 'todo-demo-1', 'title': 'Explore the app', 'completed': false},
          {'id': 'todo-demo-2', 'title': 'Read the spec', 'dueDate': '2026-07-10', 'completed': false},
        ],
      },
    });
  final uiState = UiState();
  runApp(TodoApp(store: store, useCases: TodoUseCases(store), uiState: uiState, navigatorKey: GlobalKey<NavigatorState>()));
}
