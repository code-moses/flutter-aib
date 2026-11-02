import '../app/use_cases.dart' show DomainError;
import 'model.dart';
import 'store.dart';

/// The single use-case layer of the workspace: UI and intents both call into
/// it, which is the parity guarantee (spec §8.1) — as in v1.
final class WorkspaceUseCases {
  WorkspaceUseCases(this.store);

  final WorkspaceStore store;

  static final _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  // ---- projects -----------------------------------------------------------

  Project resolveProject({String? id, String? name}) {
    if (id != null) {
      return store.projectById(id) ?? (throw DomainError('no project with id "$id"'));
    }
    if (name != null) {
      return store.projectByName(name) ??
          (throw DomainError(
            'no project named "$name" (projects: '
            '${store.projects.map((p) => p.name).join(', ')})',
          ));
    }
    throw const DomainError('either projectId or projectName is required');
  }

  void renameProject(String id, String name) {
    final project = resolveProject(id: id);
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const DomainError('name must not be empty');
    final clash = store.projectByName(trimmed);
    if (clash != null && clash.id != id) {
      throw DomainError('a project named "$trimmed" already exists');
    }
    store.replaceProject(project.copyWith(name: trimmed));
  }

  /// Archiving hides a project and makes it read-only. A project with open
  /// todos cannot be archived — they would disappear from every list.
  void archiveProject(String id) {
    final project = resolveProject(id: id);
    final open = openTodosOf(id).length;
    if (open > 0) {
      throw DomainError(
        'project "${project.name}" still has $open open todo(s); complete '
        'or move them first',
      );
    }
    store.replaceProject(project.copyWith(archived: true));
  }

  List<WorkTodo> todosOf(String projectId, {bool? completed}) => [
    for (final todo in store.todos)
      if (todo.projectId == projectId && (completed == null || todo.completed == completed)) todo,
  ];

  List<WorkTodo> openTodosOf(String projectId) => todosOf(projectId, completed: false);

  // ---- todos --------------------------------------------------------------

  String addTodo({
    required String projectId,
    required String title,
    String? dueDate,
    String? notes,
    Priority priority = .normal,
    List<String> tags = const [],
  }) {
    final project = _writable(projectId);
    final trimmed = title.trim();
    if (trimmed.isEmpty) throw const DomainError('title must not be empty');
    _validateDate(dueDate);
    final todo = WorkTodo(
      id: store.nextTodoId(),
      projectId: project.id,
      title: trimmed,
      dueDate: _emptyToNull(dueDate),
      notes: _emptyToNull(notes),
      priority: priority,
      tags: WorkTodo.normalizeTags(tags),
    );
    store.addTodo(todo);
    return todo.id;
  }

  /// By id, or by exact title when that title is unique. Two todos may share
  /// a title in different projects; guessing between them would act on
  /// whichever came first, so the caller is told to disambiguate.
  WorkTodo resolveTodo({String? id, String? title}) {
    if (id != null) {
      return store.todoById(id) ?? (throw DomainError('no todo with id "$id"'));
    }
    if (title != null) {
      final matches = store.todosTitled(title);
      if (matches.isEmpty) throw DomainError('no todo titled "$title"');
      if (matches.length > 1) {
        final where = matches.map((t) => '${t.id} in "${store.projectById(t.projectId)?.name}"').join(', ');
        throw DomainError(
          '${matches.length} todos are titled "$title" ($where); address '
          'one by id',
        );
      }
      return matches.single;
    }
    throw const DomainError('either id or title is required');
  }

  void editTodo(String id, {String? title, String? dueDate, String? notes, Priority? priority}) {
    final todo = _todoInWritableProject(id);
    if (title != null && title.trim().isEmpty) {
      throw const DomainError('title must not be empty');
    }
    _validateDate(dueDate);
    store.replaceTodo(
      todo.copyWith(
        title: title?.trim(),
        dueDate: _emptyToNull(dueDate),
        clearDueDate: dueDate != null && dueDate.trim().isEmpty,
        notes: notes,
        priority: priority,
      ),
    );
  }

  void setCompleted(String id, {required bool completed}) {
    final todo = _todoInWritableProject(id);
    store.replaceTodo(todo.copyWith(completed: completed));
  }

  List<String> tag(String id, {List<String> add = const [], List<String> remove = const []}) {
    final todo = _todoInWritableProject(id);
    final removed = {for (final t in remove) t.trim()};
    final tags = [
      for (final t in todo.tags)
        if (!removed.contains(t)) t,
      ...add,
    ];
    final updated = todo.copyWith(tags: tags);
    store.replaceTodo(updated);
    return updated.tags;
  }

  String addSubtask(String id, String title) {
    final todo = _todoInWritableProject(id);
    final trimmed = title.trim();
    if (trimmed.isEmpty) throw const DomainError('title must not be empty');
    final subtask = Subtask(id: store.nextSubtaskId(), title: trimmed);
    store.replaceTodo(todo.copyWith(subtasks: [...todo.subtasks, subtask]));
    return subtask.id;
  }

  bool toggleSubtask(String todoId, {String? subtaskId, String? title}) {
    final todo = _todoInWritableProject(todoId);
    final index = todo.subtasks.indexWhere((s) => subtaskId != null ? s.id == subtaskId : s.title == title);
    if (index < 0) {
      throw DomainError(
        'no subtask ${subtaskId ?? '"$title"'} on "${todo.title}" '
        '(subtasks: ${todo.subtasks.map((s) => s.title).join(', ')})',
      );
    }
    final subtask = todo.subtasks[index];
    final toggled = Subtask(id: subtask.id, title: subtask.title, done: !subtask.done);
    store.replaceTodo(todo.copyWith(subtasks: [...todo.subtasks]..[index] = toggled));
    return toggled.done;
  }

  void moveTodo(String id, String projectId) {
    final todo = _todoInWritableProject(id);
    final target = _writable(projectId);
    store.replaceTodo(todo.copyWith(projectId: target.id));
  }

  void deleteTodo(String id) {
    final todo = _todoInWritableProject(id);
    store.removeTodos((t) => t.id == todo.id);
  }

  /// Every search the app offers, in one place: the list screens, `todo.find`
  /// and the ground-truth queries read the same predicate.
  List<WorkTodo> findTodos({
    String? query,
    bool? completed,
    String? projectId,
    String? tag,
    Priority? priority,
    bool? overdue,
    bool includeArchived = false,
  }) {
    final today = store.settings.today;
    return [
      for (final todo in store.todos)
        if ((completed == null || todo.completed == completed) &&
            (projectId == null || todo.projectId == projectId) &&
            (tag == null || todo.tags.contains(tag)) &&
            (priority == null || todo.priority == priority) &&
            (overdue == null || isOverdue(todo, today) == overdue) &&
            (includeArchived || projectId != null || !(store.projectById(todo.projectId)?.archived ?? false)) &&
            (query == null || query.trim().isEmpty || todo.title.toLowerCase().contains(query.trim().toLowerCase())))
          todo,
    ];
  }

  static bool isOverdue(WorkTodo todo, String today) => !todo.completed && todo.dueDate != null && todo.dueDate!.compareTo(today) < 0;

  /// Counts per group — what the statistics page shows.
  List<Map<String, Object?>> stats(String groupBy) {
    final today = store.settings.today;
    final active = findTodos();
    Map<String, Object?> row(String group, Iterable<WorkTodo> todos) => {
      'group': group,
      'open': todos.where((t) => !t.completed).length,
      'completed': todos.where((t) => t.completed).length,
      'overdue': todos.where((t) => isOverdue(t, today)).length,
    };
    return switch (groupBy) {
      'project' => [
        for (final project in store.projects)
          if (!project.archived) row(project.name, active.where((t) => t.projectId == project.id)),
      ],
      'priority' => [for (final priority in Priority.values.reversed) row(priority.name, active.where((t) => t.priority == priority))],
      'tag' => [
        for (final tag in {for (final t in active) ...t.tags}.toList()..sort()) row(tag, active.where((t) => t.tags.contains(tag))),
      ],
      _ => throw DomainError('unknown groupBy "$groupBy" (expected project|priority|tag)'),
    };
  }

  // ---- settings -----------------------------------------------------------

  void setDefaultProject(String projectId) {
    final project = _writable(projectId);
    store.settings = store.settings.copyWith(defaultProjectId: project.id);
  }

  /// Removes every completed todo of every non-archived project. Destructive
  /// and not undoable — the reason it lives on the settings page.
  int deleteCompleted() {
    final doomed = findTodos(completed: true).map((t) => t.id).toSet();
    store.removeTodos((t) => doomed.contains(t.id));
    return doomed.length;
  }

  // ---- helpers ------------------------------------------------------------

  Project _writable(String projectId) {
    final project = resolveProject(id: projectId);
    if (project.archived) {
      throw DomainError('project "${project.name}" is archived (read-only)');
    }
    return project;
  }

  WorkTodo _todoInWritableProject(String id) {
    final todo = resolveTodo(id: id);
    _writable(todo.projectId);
    return todo;
  }

  static void _validateDate(String? date) {
    if (date != null && date.isNotEmpty && !_datePattern.hasMatch(date)) {
      throw DomainError('dueDate must be YYYY-MM-DD, got "$date"');
    }
  }

  static String? _emptyToNull(String? value) => value == null || value.trim().isEmpty ? null : value.trim();
}
