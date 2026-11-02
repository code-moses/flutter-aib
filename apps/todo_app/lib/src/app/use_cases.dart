import '../data/todo_store.dart';
import '../model/todo.dart';

/// Domain rule violation (validation, unknown target). UI shows it inline;
/// the intent bridge maps it to a structured `intent_rejected` result.
final class DomainError implements Exception {
  const DomainError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The single use-case layer — UI and intent API both call exclusively into
/// this class. This shared path *is* the intent-parity guarantee of spec
/// §8.1 (UI and intents cannot diverge because they run the same code).
final class TodoUseCases {
  TodoUseCases(this._store);

  final TodoStore _store;

  static final _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  String createTodo({required String title, String? dueDate, String? notes}) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      throw const DomainError('title must not be empty');
    }
    _validateDate(dueDate);
    final todo = Todo(id: _store.nextId(), title: trimmed, dueDate: _emptyToNull(dueDate), notes: _emptyToNull(notes));
    _store.add(todo);
    return todo.id;
  }

  void updateTodo(String id, {String? title, String? dueDate, String? notes, bool? completed}) {
    final todo = _require(id);
    if (title != null && title.trim().isEmpty) {
      throw const DomainError('title must not be empty');
    }
    _validateDate(dueDate);
    _store.replace(todo.copyWith(title: title?.trim(), dueDate: _emptyToNull(dueDate), notes: notes, completed: completed));
  }

  void deleteTodo(String id) {
    _require(id);
    _store.remove(id);
  }

  bool toggleComplete(String id) {
    final todo = _require(id);
    _store.replace(todo.copyWith(completed: !todo.completed));
    return !todo.completed;
  }

  /// Search/filter used by the UI list and the `todo.find` intent.
  List<Todo> findTodos({String? query, bool? completed}) => [
    for (final todo in _store.todos)
      if ((completed == null || todo.completed == completed) &&
          (query == null || query.trim().isEmpty || todo.title.toLowerCase().contains(query.trim().toLowerCase())))
        todo,
  ];

  /// Resolves an intent target given `id` or exact `title`.
  Todo resolveTarget({String? id, String? title}) {
    if (id != null) return _require(id);
    if (title != null) {
      final todo = _store.byTitle(title);
      if (todo == null) throw DomainError('no todo titled "$title"');
      return todo;
    }
    throw const DomainError('either id or title is required');
  }

  Todo _require(String id) {
    final todo = _store.byId(id);
    if (todo == null) throw DomainError('no todo with id "$id"');
    return todo;
  }

  static void _validateDate(String? date) {
    if (date != null && date.isNotEmpty && !_datePattern.hasMatch(date)) {
      throw DomainError('dueDate must be YYYY-MM-DD, got "$date"');
    }
  }

  static String? _emptyToNull(String? value) => value == null || value.trim().isEmpty ? null : value.trim();
}
