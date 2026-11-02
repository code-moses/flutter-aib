import 'package:flutter/material.dart';

import '../app/ui_state.dart';
import '../app/use_cases.dart';
import '../data/todo_store.dart';
import '../model/todo.dart';
import '../semantics_quality.dart';
import 'edit_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.store, required this.useCases, required this.uiState, required this.quality});

  final TodoStore store;
  final TodoUseCases useCases;
  final UiState uiState;
  final SemanticsQuality quality;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final TextEditingController _searchController;

  TodoStore get store => widget.store;
  TodoUseCases get useCases => widget.useCases;
  UiState get uiState => widget.uiState;

  bool get _good => widget.quality == .good;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: uiState.searchQuery);
    uiState.addListener(_syncSearchField);
  }

  @override
  void dispose() {
    uiState.removeListener(_syncSearchField);
    _searchController.dispose();
    super.dispose();
  }

  /// Keeps the field in sync when the state is reset externally (fixture
  /// reset restores the full UI state, spec §5.3).
  void _syncSearchField() {
    if (_searchController.text != uiState.searchQuery) {
      _searchController.text = uiState.searchQuery;
    }
  }

  void _openEditor(BuildContext context, {Todo? existing}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EditScreen(useCases: useCases, quality: widget.quality, existing: existing),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Todos')),
      floatingActionButton: FloatingActionButton(
        // good: explicit label; bad: unlabelled icon-only button.
        tooltip: _good ? 'Add todo' : null,
        onPressed: () => _openEditor(context),
        child: _good ? const Icon(Icons.add) : const ExcludeSemantics(child: Icon(Icons.add)),
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([store, uiState]),
        builder: (context, _) {
          final todos = useCases.findTodos(query: uiState.searchQuery, completed: uiState.completedFilter);
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: TextField(
                  controller: _searchController,
                  onChanged: (value) => uiState.searchQuery = value,
                  decoration: _good ? const InputDecoration(labelText: 'Search', prefixIcon: Icon(Icons.search)) : const InputDecoration(),
                ),
              ),
              SegmentedButton<TodoFilter>(
                segments: [
                  for (final filter in TodoFilter.values)
                    ButtonSegment(
                      value: filter,
                      label: Text(
                        _good
                            ? switch (filter) {
                                .all => 'All',
                                .open => 'Open',
                                .done => 'Done',
                              }
                            : switch (filter) {
                                // bad: cryptic, generic segment texts
                                .all => '*',
                                .open => 'o',
                                .done => 'x',
                              },
                      ),
                    ),
                ],
                selected: {uiState.filter},
                onSelectionChanged: (selection) => uiState.filter = selection.first,
              ),
              Expanded(child: ListView(children: [for (final todo in todos) _tile(context, todo)])),
            ],
          );
        },
      ),
    );
  }

  Widget _tile(BuildContext context, Todo todo) {
    final tile = ListTile(
      leading: _good
          ? Semantics(
              label: "Complete '${todo.title}'",
              child: Checkbox(value: todo.completed, onChanged: (_) => useCases.toggleComplete(todo.id)),
            )
          : Checkbox(value: todo.completed, onChanged: (_) => useCases.toggleComplete(todo.id)),
      title: Text(todo.title),
      subtitle: todo.dueDate == null ? null : Text('Due ${todo.dueDate}'),
      trailing: IconButton(
        tooltip: _good ? "Delete '${todo.title}'" : null,
        onPressed: () => useCases.deleteTodo(todo.id),
        icon: _good ? const Icon(Icons.delete) : const ExcludeSemantics(child: Icon(Icons.delete)),
      ),
      onTap: () => _openEditor(context, existing: todo),
    );
    // bad: deeply merged tile — one opaque semantics blob per row.
    return _good ? tile : MergeSemantics(child: tile);
  }
}
