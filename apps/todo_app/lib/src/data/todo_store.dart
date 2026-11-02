import 'package:aib_core/aib_core.dart' show JsonMap, asJsonMap, jsonFingerprint;
import 'package:flutter/foundation.dart';

import '../model/todo.dart';

/// In-memory persistence seeded from a JSON fixture (ADR 0005).
///
/// Fixture format (`suites/fixtures/*.json`): `{"db": {"todos": [{id, title,
/// dueDate, notes, completed}, …]}}`
///
/// [seed] restores exactly this state (including the id counter), so
/// `env.reset()` is byte-deterministic; [fingerprint] hashes the canonical
/// serialization.
final class TodoStore extends ChangeNotifier {
  final List<Todo> _todos = [];
  int _idCounter = 1;

  List<Todo> get todos => List.unmodifiable(_todos);

  void seed(JsonMap fixtureData) {
    _todos
      ..clear()
      ..addAll([for (final row in (asJsonMap(fixtureData['db'])['todos'] as List? ?? const [])) Todo.fromRow(asJsonMap(row))]);
    _idCounter = 1;
    notifyListeners();
  }

  String nextId() {
    while (_todos.any((t) => t.id == 'todo-$_idCounter')) {
      _idCounter++;
    }
    return 'todo-${_idCounter++}';
  }

  Todo? byId(String id) {
    for (final todo in _todos) {
      if (todo.id == id) return todo;
    }
    return null;
  }

  Todo? byTitle(String title) {
    for (final todo in _todos) {
      if (todo.title == title) return todo;
    }
    return null;
  }

  void add(Todo todo) {
    _todos.add(todo);
    notifyListeners();
  }

  void replace(Todo todo) {
    final index = _todos.indexWhere((t) => t.id == todo.id);
    if (index < 0) throw ArgumentError('unknown todo ${todo.id}');
    _todos[index] = todo;
    notifyListeners();
  }

  void remove(String id) {
    _todos.removeWhere((t) => t.id == id);
    notifyListeners();
  }

  List<JsonMap> rows() => [for (final todo in _todos) todo.toRow()];

  String fingerprint() => jsonFingerprint({'todos': rows()});
}
