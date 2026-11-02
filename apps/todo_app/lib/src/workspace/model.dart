/// The workspace variant of the todo app (suite `todo_v2`): todos live in
/// projects, carry a priority, tags and subtasks, and the app has a settings
/// page. Most of its capabilities are scope-gated behind the screen that mounts
/// them.
///
/// Dates are ISO strings (YYYY-MM-DD): fixture, UI, intents and ground-truth
/// queries share one representation.
library;

enum Priority { low, normal, high }

final class Project {
  const Project({required this.id, required this.name, this.archived = false});

  final String id;
  final String name;
  final bool archived;

  Project copyWith({String? name, bool? archived}) => Project(id: id, name: name ?? this.name, archived: archived ?? this.archived);

  Map<String, Object?> toRow() => {'id': id, 'name': name, 'archived': archived};

  factory Project.fromRow(Map<String, Object?> row) =>
      Project(id: row['id'] as String, name: row['name'] as String, archived: row['archived'] as bool? ?? false);
}

final class Subtask {
  const Subtask({required this.id, required this.title, this.done = false});

  final String id;
  final String title;
  final bool done;

  Map<String, Object?> toRow() => {'id': id, 'title': title, 'done': done};

  factory Subtask.fromRow(Map<String, Object?> row) =>
      Subtask(id: row['id'] as String, title: row['title'] as String, done: row['done'] as bool? ?? false);
}

final class WorkTodo {
  const WorkTodo({
    required this.id,
    required this.projectId,
    required this.title,
    this.dueDate,
    this.notes,
    this.completed = false,
    this.priority = .normal,
    this.tags = const [],
    this.subtasks = const [],
  });

  final String id;
  final String projectId;
  final String title;
  final String? dueDate;
  final String? notes;
  final bool completed;
  final Priority priority;

  /// Sorted and de-duplicated, so two routes to the same tag set produce the
  /// same row — and the same fingerprint.
  final List<String> tags;
  final List<Subtask> subtasks;

  WorkTodo copyWith({
    String? projectId,
    String? title,
    String? dueDate,
    bool clearDueDate = false,
    String? notes,
    bool? completed,
    Priority? priority,
    List<String>? tags,
    List<Subtask>? subtasks,
  }) => WorkTodo(
    id: id,
    projectId: projectId ?? this.projectId,
    title: title ?? this.title,
    dueDate: clearDueDate ? null : dueDate ?? this.dueDate,
    notes: notes ?? this.notes,
    completed: completed ?? this.completed,
    priority: priority ?? this.priority,
    tags: tags == null ? this.tags : normalizeTags(tags),
    subtasks: subtasks ?? this.subtasks,
  );

  Map<String, Object?> toRow() => {
    'id': id,
    'projectId': projectId,
    'title': title,
    'dueDate': dueDate,
    'notes': notes,
    'completed': completed,
    'priority': priority.name,
    'tags': tags,
    'subtasks': [for (final s in subtasks) s.toRow()],
  };

  factory WorkTodo.fromRow(Map<String, Object?> row) => WorkTodo(
    id: row['id'] as String,
    projectId: row['projectId'] as String,
    title: row['title'] as String,
    dueDate: row['dueDate'] as String?,
    notes: row['notes'] as String?,
    completed: row['completed'] as bool? ?? false,
    priority: Priority.values.asNameMap()[row['priority']] ?? Priority.normal,
    tags: normalizeTags([for (final tag in row['tags'] as List? ?? const []) tag as String]),
    subtasks: [for (final raw in row['subtasks'] as List? ?? const []) Subtask.fromRow(Map<String, Object?>.from(raw as Map))],
  );

  static List<String> normalizeTags(Iterable<String> tags) => ({
    for (final tag in tags)
      if (tag.trim().isNotEmpty) tag.trim(),
  }.toList()..sort());
}

/// App settings. `today` is part of the fixture rather than the clock, so
/// "overdue" means the same thing in every run.
final class WorkspaceSettings {
  const WorkspaceSettings({required this.today, this.defaultProjectId});

  final String today;
  final String? defaultProjectId;

  WorkspaceSettings copyWith({String? defaultProjectId}) =>
      WorkspaceSettings(today: today, defaultProjectId: defaultProjectId ?? this.defaultProjectId);

  Map<String, Object?> toRow() => {'today': today, 'defaultProjectId': defaultProjectId};

  factory WorkspaceSettings.fromRow(Map<String, Object?> row) =>
      WorkspaceSettings(today: row['today'] as String? ?? '2026-07-01', defaultProjectId: row['defaultProjectId'] as String?);
}
