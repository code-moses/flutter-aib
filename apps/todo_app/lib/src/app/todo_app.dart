import 'package:flutter/material.dart';

import '../data/todo_store.dart';
import '../semantics_quality.dart';
import '../ui/home_screen.dart';
import 'ui_state.dart';
import 'use_cases.dart';

class TodoApp extends StatelessWidget {
  const TodoApp({
    super.key,
    required this.store,
    required this.useCases,
    required this.uiState,
    required this.navigatorKey,
    this.quality = SemanticsQuality.fromEnvironment,
  });

  final TodoStore store;
  final TodoUseCases useCases;
  final UiState uiState;
  final GlobalKey<NavigatorState> navigatorKey;
  final SemanticsQuality quality;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AIB Todo',
      navigatorKey: navigatorKey,
      theme: ThemeData(colorSchemeSeed: Colors.teal),
      home: HomeScreen(store: store, useCases: useCases, uiState: uiState, quality: quality),
    );
  }
}
