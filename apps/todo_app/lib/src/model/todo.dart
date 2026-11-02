/// Todo entity. `dueDate` is an ISO date string (YYYY-MM-DD) or null —
/// string-typed on purpose so fixture, UI, intents and ground-truth queries
/// share one canonical representation.
final class Todo {
  const Todo({required this.id, required this.title, this.dueDate, this.notes, this.completed = false});

  final String id;
  final String title;
  final String? dueDate;
  final String? notes;
  final bool completed;

  Todo copyWith({String? title, String? dueDate, String? notes, bool? completed}) =>
      Todo(id: id, title: title ?? this.title, dueDate: dueDate ?? this.dueDate, notes: notes ?? this.notes, completed: completed ?? this.completed);

  Map<String, Object?> toRow() => {'id': id, 'title': title, 'dueDate': dueDate, 'notes': notes, 'completed': completed};

  factory Todo.fromRow(Map<String, Object?> row) => Todo(
    id: row['id'] as String,
    title: row['title'] as String,
    dueDate: row['dueDate'] as String?,
    notes: row['notes'] as String?,
    completed: row['completed'] as bool? ?? false,
  );
}
