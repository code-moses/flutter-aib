import 'package:aib_core/aib_core.dart' show JsonMap, asJsonMap;
import 'package:flutter/foundation.dart';

import 'model.dart';

/// In-memory persistence of the workspace, seeded from a JSON fixture
/// (ADR 0005). Fixture format:
///
/// `{"db": {"projects": [...], "todos": [...], "settings": {...}}}`
///
/// [seed] restores exactly this state, id counters included, so a reset is
/// byte-deterministic.
final class WorkspaceStore extends ChangeNotifier {
  final List<Project> _projects = [];
  final List<WorkTodo> _todos = [];
  WorkspaceSettings _settings = const WorkspaceSettings(today: '2026-07-01');
  int _todoCounter = 1;
  int _subtaskCounter = 1;

  List<Project> get projects => List.unmodifiable(_projects);
  List<WorkTodo> get todos => List.unmodifiable(_todos);
  WorkspaceSettings get settings => _settings;

  void seed(JsonMap fixtureData) {
    final db = asJsonMap(fixtureData['db']);
    _projects
      ..clear()
      ..addAll([for (final row in db['projects'] as List? ?? const []) Project.fromRow(asJsonMap(row))]);
    _todos
      ..clear()
      ..addAll([for (final row in db['todos'] as List? ?? const []) WorkTodo.fromRow(asJsonMap(row))]);
    _settings = WorkspaceSettings.fromRow(asJsonMap(db['settings']));
    _todoCounter = 1;
    _subtaskCounter = 1;
    notifyListeners();
  }

  String nextTodoId() {
    while (_todos.any((t) => t.id == 'todo-$_todoCounter')) {
      _todoCounter++;
    }
    return 'todo-${_todoCounter++}';
  }

  String nextSubtaskId() {
    bool taken(String id) => _todos.any((t) => t.subtasks.any((s) => s.id == id));
    while (taken('sub-$_subtaskCounter')) {
      _subtaskCounter++;
    }
    return 'sub-${_subtaskCounter++}';
  }

  Project? projectById(String id) {
    for (final project in _projects) {
      if (project.id == id) return project;
    }
    return null;
  }

  Project? projectByName(String name) {
    for (final project in _projects) {
      if (project.name == name) return project;
    }
    return null;
  }

  WorkTodo? todoById(String id) {
    for (final todo in _todos) {
      if (todo.id == id) return todo;
    }
    return null;
  }

  List<WorkTodo> todosTitled(String title) => [
    for (final todo in _todos)
      if (todo.title == title) todo,
  ];

  void addTodo(WorkTodo todo) {
    _todos.add(todo);
    notifyListeners();
  }

  void replaceTodo(WorkTodo todo) {
    final index = _todos.indexWhere((t) => t.id == todo.id);
    if (index < 0) throw ArgumentError('unknown todo ${todo.id}');
    _todos[index] = todo;
    notifyListeners();
  }

  void removeTodos(bool Function(WorkTodo) test) {
    _todos.removeWhere(test);
    notifyListeners();
  }

  void replaceProject(Project project) {
    final index = _projects.indexWhere((p) => p.id == project.id);
    if (index < 0) throw ArgumentError('unknown project ${project.id}');
    _projects[index] = project;
    notifyListeners();
  }

  set settings(WorkspaceSettings value) {
    _settings = value;
    notifyListeners();
  }

  JsonMap rows() => {
    'projects': [for (final p in _projects) p.toRow()],
    'todos': [for (final t in _todos) t.toRow()],
    'settings': [_settings.toRow()],
  };
}
