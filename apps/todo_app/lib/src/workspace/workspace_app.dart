import 'package:flutter/material.dart';

import '../app/use_cases.dart' show DomainError;
import 'model.dart';
import 'navigation.dart';
import 'store.dart';
import 'use_cases.dart';

/// The workspace app. Its Navigator renders [WorkspaceNav.stack] as pages,
/// so a screen is open exactly when the navigation state says so, whichever
/// of a tap or an intent opened it.
class WorkspaceApp extends StatelessWidget {
  const WorkspaceApp({super.key, required this.store, required this.useCases, required this.nav});

  final WorkspaceStore store;
  final WorkspaceUseCases useCases;
  final WorkspaceNav nav;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AIB Workspace',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: ListenableBuilder(
        listenable: Listenable.merge([nav, store]),
        builder: (context, _) => Navigator(
          pages: [for (final screen in nav.stack) MaterialPage<void>(key: ValueKey(screen.key), child: _page(screen))],
          onDidRemovePage: (page) {
            final key = page.key;
            if (key is ValueKey<String>) nav.removed(key.value);
          },
        ),
      ),
    );
  }

  Widget _page(Screen screen) {
    final deps = _Deps(store, useCases, nav);
    return switch (screen) {
      HomeScreenRef() => _HomePage(deps),
      ProjectScreenRef(:final projectId) => _ProjectPage(deps, projectId),
      TodoScreenRef(:final todoId) => _TodoPage(deps, todoId),
      SettingsScreenRef() => _SettingsPage(deps),
      StatsScreenRef() => _StatsPage(deps),
    };
  }
}

final class _Deps {
  const _Deps(this.store, this.useCases, this.nav);
  final WorkspaceStore store;
  final WorkspaceUseCases useCases;
  final WorkspaceNav nav;
}

/// Runs [action]; a domain error becomes a snack bar instead of a crash.
void _guard(BuildContext context, void Function() action) {
  try {
    action();
  } on DomainError catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }
}

Future<String?> _askText(BuildContext context, {required String title, required String label, String initial = ''}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('OK')),
      ],
    ),
  );
}

String _priorityLabel(Priority p) => switch (p) {
  .low => 'Low',
  .normal => 'Normal',
  .high => 'High',
};

// ---- home -------------------------------------------------------------------

class _HomePage extends StatefulWidget {
  const _HomePage(this.deps);
  final _Deps deps;
  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  late final _search = TextEditingController(text: widget.deps.nav.search);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.deps;
    if (_search.text != d.nav.search) _search.text = d.nav.search;
    final query = d.nav.search;
    final hits = query.trim().isEmpty ? const <WorkTodo>[] : d.useCases.findTodos(query: query);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Projects'),
        actions: [
          IconButton(tooltip: 'Statistics', icon: const Icon(Icons.bar_chart), onPressed: () => d.nav.open(const StatsScreenRef())),
          IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings), onPressed: () => d.nav.open(const SettingsScreenRef())),
        ],
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _search,
              onChanged: (value) => d.nav.search = value,
              decoration: const InputDecoration(labelText: 'Search all todos', prefixIcon: Icon(Icons.search)),
            ),
          ),
          for (final todo in hits)
            ListTile(
              leading: const Icon(Icons.task_alt),
              title: Text(todo.title),
              subtitle: Text(d.store.projectById(todo.projectId)?.name ?? ''),
              onTap: () => d.nav.open(TodoScreenRef(todo.id)),
            ),
          if (hits.isNotEmpty) const Divider(),
          for (final project in d.store.projects)
            ListTile(
              leading: Icon(project.archived ? Icons.inventory_2 : Icons.folder),
              title: Text(project.archived ? '${project.name} (archived)' : project.name),
              subtitle: Text('${d.useCases.openTodosOf(project.id).length} open'),
              onTap: () => d.nav.open(ProjectScreenRef(project.id)),
            ),
        ],
      ),
    );
  }
}

// ---- project ----------------------------------------------------------------

class _ProjectPage extends StatelessWidget {
  const _ProjectPage(this.d, this.projectId);
  final _Deps d;
  final String projectId;

  @override
  Widget build(BuildContext context) {
    final project = d.store.projectById(projectId);
    if (project == null) return const Scaffold();
    final filter = d.nav.projectFilter;
    final todos = d.useCases.todosOf(
      projectId,
      completed: switch (filter) {
        .all => null,
        .open => false,
        .done => true,
      },
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(project.name),
        actions: [
          if (!project.archived) ...[
            IconButton(
              tooltip: 'Rename project',
              icon: const Icon(Icons.edit),
              onPressed: () async {
                final name = await _askText(context, title: 'Rename project', label: 'Project name', initial: project.name);
                if (name != null && context.mounted) {
                  _guard(context, () => d.useCases.renameProject(projectId, name));
                }
              },
            ),
            IconButton(
              tooltip: 'Archive project',
              icon: const Icon(Icons.archive),
              onPressed: () => _guard(context, () {
                d.useCases.archiveProject(projectId);
                d.nav.closeWhere((s) => s is ProjectScreenRef && s.projectId == projectId);
              }),
            ),
          ],
        ],
      ),
      floatingActionButton: project.archived
          ? null
          : FloatingActionButton(tooltip: 'Add todo', onPressed: () => _addTodo(context), child: const Icon(Icons.add)),
      body: Column(
        children: [
          SegmentedButton<ListFilter>(
            segments: const [
              ButtonSegment(value: .all, label: Text('All')),
              ButtonSegment(value: .open, label: Text('Open')),
              ButtonSegment(value: .done, label: Text('Done')),
            ],
            selected: {filter},
            onSelectionChanged: (s) => d.nav.projectFilter = s.first,
          ),
          Expanded(
            child: ListView(
              children: [
                for (final todo in todos)
                  ListTile(
                    leading: Semantics(
                      label: "Complete '${todo.title}'",
                      child: Checkbox(
                        value: todo.completed,
                        onChanged: project.archived
                            ? null
                            : (value) => _guard(context, () => d.useCases.setCompleted(todo.id, completed: value ?? false)),
                      ),
                    ),
                    title: Text(todo.title),
                    subtitle: Text(
                      [
                        if (todo.dueDate != null) 'Due ${todo.dueDate}',
                        '${_priorityLabel(todo.priority)} priority',
                        if (todo.tags.isNotEmpty) todo.tags.join(', '),
                      ].join(' · '),
                    ),
                    onTap: () => d.nav.open(TodoScreenRef(todo.id)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addTodo(BuildContext context) async {
    final title = TextEditingController();
    final due = TextEditingController();
    var priority = Priority.normal;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('New todo'),
          content: Column(
            mainAxisSize: .min,
            children: [
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              TextField(
                controller: due,
                decoration: const InputDecoration(labelText: 'Due date (YYYY-MM-DD)'),
              ),
              const SizedBox(height: 8),
              SegmentedButton<Priority>(
                segments: [for (final p in Priority.values) ButtonSegment(value: p, label: Text(_priorityLabel(p)))],
                selected: {priority},
                onSelectionChanged: (s) => setState(() => priority = s.first),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Add todo')),
          ],
        ),
      ),
    );
    if (ok == true && context.mounted) {
      _guard(context, () => d.useCases.addTodo(projectId: projectId, title: title.text, dueDate: due.text, priority: priority));
    }
  }
}

// ---- todo detail --------------------------------------------------------------

class _TodoPage extends StatefulWidget {
  const _TodoPage(this.d, this.todoId);
  final _Deps d;
  final String todoId;
  @override
  State<_TodoPage> createState() => _TodoPageState();
}

class _TodoPageState extends State<_TodoPage> {
  late final WorkTodo? _initial = widget.d.store.todoById(widget.todoId);
  late final _title = TextEditingController(text: _initial?.title);
  late final _due = TextEditingController(text: _initial?.dueDate);
  late final _notes = TextEditingController(text: _initial?.notes);
  final _newTag = TextEditingController();
  final _newSubtask = TextEditingController();

  @override
  void dispose() {
    for (final c in [_title, _due, _notes, _newTag, _newSubtask]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    final todo = d.store.todoById(widget.todoId);
    if (todo == null) return const Scaffold();
    final uc = d.useCases;
    final writable = !(d.store.projectById(todo.projectId)?.archived ?? true);
    return Scaffold(
      appBar: AppBar(
        title: Text(todo.title),
        actions: [
          if (writable)
            IconButton(
              tooltip: 'Delete todo',
              icon: const Icon(Icons.delete),
              onPressed: () => _guard(context, () {
                uc.deleteTodo(todo.id);
                d.nav.closeWhere((s) => s is TodoScreenRef && s.todoId == todo.id);
              }),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          CheckboxListTile(
            title: const Text('Completed'),
            value: todo.completed,
            onChanged: writable ? (v) => _guard(context, () => uc.setCompleted(todo.id, completed: v ?? false)) : null,
          ),
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          TextField(
            controller: _due,
            decoration: const InputDecoration(labelText: 'Due date (YYYY-MM-DD)'),
          ),
          TextField(
            controller: _notes,
            decoration: const InputDecoration(labelText: 'Notes'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: writable
                ? () => _guard(context, () => uc.editTodo(todo.id, title: _title.text, dueDate: _due.text, notes: _notes.text))
                : null,
            child: const Text('Save changes'),
          ),
          const SizedBox(height: 16),
          const Text('Priority'),
          SegmentedButton<Priority>(
            segments: [for (final p in Priority.values) ButtonSegment(value: p, label: Text(_priorityLabel(p)))],
            selected: {todo.priority},
            onSelectionChanged: writable ? (s) => _guard(context, () => uc.editTodo(todo.id, priority: s.first)) : null,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: todo.projectId,
            decoration: const InputDecoration(labelText: 'Project'),
            items: [
              for (final p in d.store.projects)
                if (!p.archived || p.id == todo.projectId) DropdownMenuItem(value: p.id, child: Text(p.name)),
            ],
            onChanged: writable ? (id) => _guard(context, () => uc.moveTodo(todo.id, id!)) : null,
          ),
          const SizedBox(height: 16),
          const Text('Tags'),
          Wrap(
            spacing: 8,
            children: [
              for (final tag in todo.tags)
                InputChip(
                  label: Text(tag),
                  onDeleted: writable ? () => _guard(context, () => uc.tag(todo.id, remove: [tag])) : null,
                  deleteButtonTooltipMessage: "Remove tag '$tag'",
                ),
            ],
          ),
          if (writable)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newTag,
                    decoration: const InputDecoration(labelText: 'New tag'),
                  ),
                ),
                IconButton(
                  tooltip: 'Add tag',
                  icon: const Icon(Icons.add),
                  onPressed: () => _guard(context, () {
                    uc.tag(todo.id, add: [_newTag.text]);
                    _newTag.clear();
                  }),
                ),
              ],
            ),
          const SizedBox(height: 16),
          const Text('Subtasks'),
          for (final s in todo.subtasks)
            CheckboxListTile(
              title: Text(s.title),
              value: s.done,
              onChanged: writable ? (_) => _guard(context, () => uc.toggleSubtask(todo.id, subtaskId: s.id)) : null,
            ),
          if (writable)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newSubtask,
                    decoration: const InputDecoration(labelText: 'New subtask'),
                  ),
                ),
                IconButton(
                  tooltip: 'Add subtask',
                  icon: const Icon(Icons.add),
                  onPressed: () => _guard(context, () {
                    uc.addSubtask(todo.id, _newSubtask.text);
                    _newSubtask.clear();
                  }),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// ---- settings -----------------------------------------------------------------

class _SettingsPage extends StatelessWidget {
  const _SettingsPage(this.d);
  final _Deps d;

  @override
  Widget build(BuildContext context) {
    final settings = d.store.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            initialValue: settings.defaultProjectId,
            decoration: const InputDecoration(labelText: 'Default project'),
            items: [
              for (final p in d.store.projects)
                if (!p.archived) DropdownMenuItem(value: p.id, child: Text(p.name)),
            ],
            onChanged: (id) => _guard(context, () => d.useCases.setDefaultProject(id!)),
          ),
          const SizedBox(height: 24),
          FilledButton.tonal(
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Delete completed todos?'),
                  content: const Text(
                    'Every completed todo in every project is deleted. '
                    'This cannot be undone.',
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
                  ],
                ),
              );
              if (ok == true && context.mounted) {
                _guard(context, d.useCases.deleteCompleted);
              }
            },
            child: const Text('Delete completed todos'),
          ),
        ],
      ),
    );
  }
}

// ---- statistics ---------------------------------------------------------------

class _StatsPage extends StatefulWidget {
  const _StatsPage(this.d);
  final _Deps d;
  @override
  State<_StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<_StatsPage> {
  String _groupBy = 'project';

  @override
  Widget build(BuildContext context) {
    final rows = widget.d.useCases.stats(_groupBy);
    return Scaffold(
      appBar: AppBar(title: const Text('Statistics')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'project', label: Text('By project')),
              ButtonSegment(value: 'priority', label: Text('By priority')),
              ButtonSegment(value: 'tag', label: Text('By tag')),
            ],
            selected: {_groupBy},
            onSelectionChanged: (s) => setState(() => _groupBy = s.first),
          ),
          for (final row in rows)
            ListTile(
              title: Text('${row['group']}'),
              subtitle: Text(
                '${row['open']} open · ${row['completed']} completed · '
                '${row['overdue']} overdue',
              ),
            ),
        ],
      ),
    );
  }
}
