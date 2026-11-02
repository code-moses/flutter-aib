import 'package:aib_core/aib_core.dart';
import 'package:aib_flutter/aib_flutter.dart';

import '../app/use_cases.dart' show DomainError;
import '../workspace/model.dart';
import '../workspace/navigation.dart';
import '../workspace/store.dart';
import '../workspace/use_cases.dart';

/// Wires the workspace app (suite `todo_v2`) into the benchmark framework.
/// Eight intents are always in scope; thirteen more exist only while the screen
/// that mounts them is on top, so a preparing agent reading the catalogue at
/// the start sees only the global part.
FlutterEnvironment buildWorkspaceEnvironment({
  required WorkspaceStore store,
  required WorkspaceUseCases useCases,
  required WorkspaceNav nav,
  Future<void> Function()? settle,

  /// The semantics bridge's opt-in checks; null installs it with none.
  SemanticsBridge? semantics,

  /// The app's frame costs as resource samples; null samples none.
  FrameAttribution? frames,
}) {
  final environment = FlutterEnvironment(
    frames: frames,
    environmentId: 'todo_workspace',
    version: '1.0.0',
    settle: settle,
    onReset: (fixtureData) async {
      nav.reset();
      store.seed(fixtureData);
    },
    onStateQuery: (query) async {
      //   db.projects / db.todos / db.settings  -> the data
      //   view.state   -> one row {screen, projectId?, todoId?, filter, search}
      //   view.stack   -> the screens, bottom first
      //   db.tags / db.subtasks -> flattened, one row per tag or subtask,
      //   because the query language has `==` and `&&` but no "contains"
      final rows = store.rows();
      final result = SimpleQuery.parse(query.query).run({
        'db': {
          ...rows,
          'tags': [
            for (final todo in store.todos)
              for (final tag in todo.tags) {'todoId': todo.id, 'todoTitle': todo.title, 'tag': tag},
          ],
          'subtasks': [
            for (final todo in store.todos)
              for (final subtask in todo.subtasks) {'todoId': todo.id, 'todoTitle': todo.title, ...subtask.toRow()},
          ],
        },
        'view': {
          'state': [
            {...nav.top.toRow(), 'filter': nav.projectFilter.name, 'search': nav.search, 'depth': nav.stack.length},
          ],
          'stack': [for (final s in nav.stack) s.toRow()],
        },
      });
      return StateQueryResult(query: query.query, count: result.count, items: result.items);
    },
    // Data and list view state, as in v1. The open screen stays out: it is
    // a means here too, and counting "opened the project page" as progress
    // would reward navigation for its own sake.
    fingerprint: () async => jsonFingerprint({
      'data': store.rows(),
      'view': {'filter': nav.projectFilter.name, 'search': nav.search},
    }),
  );

  final intents = WorkspaceIntents(store, useCases, nav);
  (semantics ?? SemanticsBridge()).install(environment);
  IntentBridge(catalogProvider: intents.scoped)
    ..registerAll(intents.global())
    ..install(environment);
  return environment;
}

/// The workspace's intent catalogue. Handlers call the same use cases as
/// the UI (parity, spec §8.1), and the scoped ones exist only while their
/// screen is on top — exactly when the UI shows their controls.
final class WorkspaceIntents {
  WorkspaceIntents(this.store, this.useCases, this.nav);

  final WorkspaceStore store;
  final WorkspaceUseCases useCases;
  final WorkspaceNav nav;

  static const _projectRef = {
    'projectId': {'type': 'string', 'description': 'Project id'},
    'projectName': {'type': 'string', 'description': 'Exact project name'},
  };
  static const _todoRef = {
    'id': {'type': 'string', 'description': 'Todo id'},
    'title': {'type': 'string', 'description': 'Exact todo title — refused when two todos share it'},
  };
  static const _priority = {
    'type': 'string',
    'enum': ['low', 'normal', 'high'],
  };

  Future<T> _guarded<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on DomainError catch (e) {
      throw IntentRejected(e.message);
    }
  }

  Project _project(JsonMap params) => useCases.resolveProject(id: params['projectId'] as String?, name: params['projectName'] as String?);

  Priority? _priorityOf(Object? raw) =>
      raw == null ? null : Priority.values.asNameMap()[raw] ?? (throw DomainError('unknown priority "$raw" (low|normal|high)'));

  JsonMap _todoRow(WorkTodo todo) => {
    'id': todo.id,
    'title': todo.title,
    'project': store.projectById(todo.projectId)?.name,
    'projectId': todo.projectId,
    'dueDate': todo.dueDate,
    'completed': todo.completed,
    'priority': todo.priority.name,
    'tags': todo.tags,
    'subtasks': todo.subtasks.length,
  };

  JsonMap _screen() {
    final top = nav.top;
    return switch (top) {
      ProjectScreenRef(:final projectId) => {...top.toRow(), 'project': store.projectById(projectId)?.toRow()},
      TodoScreenRef(:final todoId) => {...top.toRow(), 'todo': store.todoById(todoId)?.toRow()},
      _ => top.toRow(),
    };
  }

  /// Always in scope.
  List<AibIntent> global() => [
    AibIntent(
      name: 'project.list',
      description:
          'Lists the projects with their id, name, whether they are archived, '
          'and how many open and completed todos each has.',
      kind: .observe,
      effect: .none,
      aliases: const ['Projekte', 'Projektliste'],
      handler: (_) async => {
        'projects': [
          for (final p in store.projects)
            {...p.toRow(), 'open': useCases.openTodosOf(p.id).length, 'completed': useCases.todosOf(p.id, completed: true).length},
        ],
      },
    ),
    AibIntent(
      name: 'project.open',
      description:
          'Opens a project page, by projectId or exact projectName. The page '
          'is what makes the project\'s own intents available: adding a todo '
          'to it, renaming, archiving and filtering it.',
      effect: .none,
      aliases: const ['Projekt öffnen'],
      examples: const [
        {
          'when': 'Open the Garden project',
          'params': {'projectName': 'Garden'},
        },
      ],
      paramsSchema: const {'type': 'object', 'properties': _projectRef},
      handler: (params) => _guarded(() async {
        final project = _project(params);
        nav.open(ProjectScreenRef(project.id));
        return _screen();
      }),
    ),
    AibIntent(
      name: 'todo.find',
      description:
          'Finds todos across all projects by title substring, completion, '
          'project, tag, priority or overdue state; archived projects are '
          'left out unless a project is named.',
      kind: .observe,
      effect: .none,
      aliases: const ['Aufgaben suchen', 'Suche'],
      examples: const [
        {
          'when': 'Which todos in Garden are still open?',
          'params': {'projectName': 'Garden', 'completed': false},
        },
        {
          'when': 'Everything tagged diy',
          'params': {'tag': 'diy'},
        },
      ],
      paramsSchema: const {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
          'completed': {'type': 'boolean'},
          ..._projectRef,
          'tag': {'type': 'string'},
          'priority': _priority,
          'overdue': {'type': 'boolean', 'description': 'Open and due before the app\'s today'},
        },
      },
      handler: (params) => _guarded(() async {
        final named = params['projectId'] != null || params['projectName'] != null;
        final todos = useCases.findTodos(
          query: params['query'] as String?,
          completed: params['completed'] as bool?,
          projectId: named ? _project(params).id : null,
          tag: params['tag'] as String?,
          priority: _priorityOf(params['priority']),
          overdue: params['overdue'] as bool?,
        );
        return {
          'today': store.settings.today,
          'count': todos.length,
          'todos': [for (final t in todos) _todoRow(t)],
        };
      }),
    ),
    AibIntent(
      name: 'todo.open',
      description:
          'Opens a todo\'s detail page, by id or exact title. The page is what '
          'makes the todo\'s own intents available: editing, completing, '
          'tagging, subtasks, moving and deleting it.',
      effect: .none,
      aliases: const ['Aufgabe öffnen'],
      examples: const [
        {
          'when': 'Open the todo "Fix the fence"',
          'params': {'title': 'Fix the fence'},
        },
      ],
      paramsSchema: const {'type': 'object', 'properties': _todoRef},
      handler: (params) => _guarded(() async {
        final todo = useCases.resolveTodo(id: params['id'] as String?, title: params['title'] as String?);
        nav.open(TodoScreenRef(todo.id));
        return _screen();
      }),
    ),
    AibIntent(
      name: 'todo.stats',
      description:
          'Counts open, completed and overdue todos per project, per '
          'priority or per tag — what the statistics page shows.',
      kind: .observe,
      effect: .none,
      aliases: const ['Statistik', 'Auswertung'],
      examples: const [
        {
          'when': 'How many todos does each project have?',
          'params': {'groupBy': 'project'},
        },
      ],
      paramsSchema: const {
        'type': 'object',
        'properties': {
          'groupBy': {
            'type': 'string',
            'enum': ['project', 'priority', 'tag'],
          },
        },
        'required': ['groupBy'],
      },
      handler: (params) =>
          _guarded(() async => {'today': store.settings.today, 'groupBy': params['groupBy'], 'rows': useCases.stats(params['groupBy'] as String)}),
    ),
    AibIntent(
      name: 'settings.open',
      description:
          'Opens the settings page, which is what makes the settings '
          'intents available: the default project, and deleting all '
          'completed todos.',
      effect: .none,
      aliases: const ['Einstellungen'],
      handler: (_) async {
        nav.open(const SettingsScreenRef());
        return _screen();
      },
    ),
    AibIntent(
      name: 'nav.back',
      description: 'Goes back one page.',
      effect: .none,
      aliases: const ['Zurück'],
      handler: (_) async {
        if (!nav.back()) throw const IntentRejected('already on the home page');
        return _screen();
      },
    ),
    AibIntent(
      name: 'nav.current',
      description: 'Where the user is right now: the page on top and what it shows.',
      kind: .observe,
      effect: .none,
      handler: (_) async => _screen(),
    ),
  ];

  /// The intents the page on top mounts. Called on every catalogue
  /// observation (and after every envelope, for the capability delta).
  Iterable<AibIntent> scoped() {
    final top = nav.top;
    switch (top) {
      case ProjectScreenRef(:final projectId):
        final project = store.projectById(projectId);
        if (project == null) return const [];
        return [
          _projectFilter(projectId),
          // An archived project is read-only: its page shows no controls
          // that change it, and so mounts no intents that would.
          if (!project.archived) ...[_projectAddTodo(projectId), _projectRename(projectId), _projectArchive(projectId)],
        ];
      case TodoScreenRef(:final todoId):
        final todo = store.todoById(todoId);
        final project = todo == null ? null : store.projectById(todo.projectId);
        if (todo == null || project == null || project.archived) {
          return const [];
        }
        return _todoIntents(todoId);
      case SettingsScreenRef():
        return _settingsIntents();
      case HomeScreenRef() || StatsScreenRef():
        return const [];
    }
  }

  AibIntent _projectFilter(String projectId) => AibIntent(
    name: 'project.filter',
    description:
        'Shows all, only open or only completed todos on the open project '
        'page.',
    effect: .none,
    aliases: const ['Filter'],
    paramsSchema: const {
      'type': 'object',
      'properties': {
        'filter': {
          'type': 'string',
          'enum': ['all', 'open', 'done'],
        },
      },
      'required': ['filter'],
    },
    handler: (params) => _guarded(() async {
      nav.projectFilter = ListFilter.values.byName(params['filter'] as String);
      return {
        'filter': nav.projectFilter.name,
        'visible': useCases
            .todosOf(
              projectId,
              completed: switch (nav.projectFilter) {
                .all => null,
                .open => false,
                .done => true,
              },
            )
            .length,
      };
    }),
  );

  AibIntent _projectAddTodo(String projectId) => AibIntent(
    name: 'project.addTodo',
    description:
        'Adds a todo to the open project (title required; dueDate '
        'YYYY-MM-DD, priority, tags optional).',
    effect: .reversible,
    aliases: const ['Aufgabe anlegen', 'Neue Aufgabe'],
    examples: const [
      {
        'when': 'Add "Buy seeds" due 2026-03-01, high priority',
        'params': {'title': 'Buy seeds', 'dueDate': '2026-03-01', 'priority': 'high'},
      },
    ],
    paramsSchema: const {
      'type': 'object',
      'properties': {
        'title': {'type': 'string'},
        'dueDate': {'type': 'string', 'pattern': r'^\d{4}-\d{2}-\d{2}$'},
        'notes': {'type': 'string'},
        'priority': _priority,
        'tags': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      'required': ['title'],
    },
    handler: (params) => _guarded(
      () async => {
        'id': useCases.addTodo(
          projectId: projectId,
          title: params['title'] as String? ?? '',
          dueDate: params['dueDate'] as String?,
          notes: params['notes'] as String?,
          priority: _priorityOf(params['priority']) ?? Priority.normal,
          tags: [for (final t in params['tags'] as List? ?? const []) '$t'],
        ),
      },
    ),
  );

  AibIntent _projectRename(String projectId) => AibIntent(
    name: 'project.rename',
    description: 'Renames the open project.',
    effect: .reversible,
    aliases: const ['Projekt umbenennen'],
    paramsSchema: const {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
      },
      'required': ['name'],
    },
    handler: (params) => _guarded(() async {
      useCases.renameProject(projectId, params['name'] as String);
      return {'renamed': projectId, 'name': params['name']};
    }),
  );

  AibIntent _projectArchive(String projectId) => AibIntent(
    name: 'project.archive',
    description:
        'Archives the open project: it becomes read-only and cannot be '
        'restored. Refused while the project has open todos.',
    effect: .irreversible,
    aliases: const ['Projekt archivieren'],
    handler: (_) => _guarded(() async {
      useCases.archiveProject(projectId);
      nav.closeWhere((s) => s is ProjectScreenRef && s.projectId == projectId);
      return {'archived': projectId};
    }),
  );

  List<AibIntent> _todoIntents(String todoId) => [
    AibIntent(
      name: 'todo.edit',
      description:
          'Changes title, dueDate (YYYY-MM-DD, empty to clear), notes or '
          'priority of the open todo.',
      effect: .reversible,
      aliases: const ['Aufgabe bearbeiten', 'Priorität'],
      paramsSchema: const {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
          'dueDate': {'type': 'string'},
          'notes': {'type': 'string'},
          'priority': _priority,
        },
      },
      handler: (params) => _guarded(() async {
        useCases.editTodo(
          todoId,
          title: params['title'] as String?,
          dueDate: params['dueDate'] as String?,
          notes: params['notes'] as String?,
          priority: _priorityOf(params['priority']),
        );
        return {'todo': _todoRow(store.todoById(todoId)!)};
      }),
    ),
    AibIntent(
      name: 'todo.complete',
      description: 'Marks the open todo completed, or open again.',
      effect: .reversible,
      aliases: const ['Erledigt', 'Abhaken'],
      paramsSchema: const {
        'type': 'object',
        'properties': {
          'completed': {'type': 'boolean'},
        },
        'required': ['completed'],
      },
      handler: (params) => _guarded(() async {
        useCases.setCompleted(todoId, completed: params['completed'] as bool);
        return {'todo': _todoRow(store.todoById(todoId)!)};
      }),
    ),
    AibIntent(
      name: 'todo.tag',
      description: 'Adds tags to or removes tags from the open todo.',
      effect: .reversible,
      aliases: const ['Schlagwort', 'Tag'],
      examples: const [
        {
          'when': 'Tag it "diy", remove "later"',
          'params': {
            'add': ['diy'],
            'remove': ['later'],
          },
        },
      ],
      paramsSchema: const {
        'type': 'object',
        'properties': {
          'add': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'remove': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
      },
      handler: (params) => _guarded(
        () async => {
          'tags': useCases.tag(
            todoId,
            add: [for (final t in params['add'] as List? ?? const []) '$t'],
            remove: [for (final t in params['remove'] as List? ?? const []) '$t'],
          ),
        },
      ),
    ),
    AibIntent(
      name: 'todo.addSubtask',
      description: 'Adds a subtask to the open todo.',
      effect: .reversible,
      aliases: const ['Teilaufgabe'],
      paramsSchema: const {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
        },
        'required': ['title'],
      },
      handler: (params) => _guarded(() async => {'subtaskId': useCases.addSubtask(todoId, params['title'] as String)}),
    ),
    AibIntent(
      name: 'todo.toggleSubtask',
      description:
          'Ticks a subtask of the open todo, or unticks it, by subtaskId or '
          'exact title.',
      effect: .reversible,
      aliases: const ['Teilaufgabe abhaken'],
      paramsSchema: const {
        'type': 'object',
        'properties': {
          'subtaskId': {'type': 'string'},
          'title': {'type': 'string'},
        },
      },
      handler: (params) => _guarded(
        () async => {'done': useCases.toggleSubtask(todoId, subtaskId: params['subtaskId'] as String?, title: params['title'] as String?)},
      ),
    ),
    AibIntent(
      name: 'todo.move',
      description:
          'Moves the open todo to another project, by projectId or exact '
          'projectName.',
      effect: .reversible,
      aliases: const ['Verschieben'],
      examples: const [
        {
          'when': 'Move it to the Garden project',
          'params': {'projectName': 'Garden'},
        },
      ],
      paramsSchema: const {'type': 'object', 'properties': _projectRef},
      handler: (params) => _guarded(() async {
        useCases.moveTodo(todoId, _project(params).id);
        return {'todo': _todoRow(store.todoById(todoId)!)};
      }),
    ),
    AibIntent(
      name: 'todo.delete',
      description: 'Deletes the open todo. Cannot be undone.',
      effect: .destructive,
      aliases: const ['Löschen'],
      handler: (_) => _guarded(() async {
        useCases.deleteTodo(todoId);
        nav.closeWhere((s) => s is TodoScreenRef && s.todoId == todoId);
        return {'deleted': todoId};
      }),
    ),
  ];

  List<AibIntent> _settingsIntents() => [
    AibIntent(
      name: 'settings.setDefaultProject',
      description:
          'Sets the project new todos go to by default, by projectId or '
          'exact projectName.',
      effect: .reversible,
      aliases: const ['Standardprojekt'],
      paramsSchema: const {'type': 'object', 'properties': _projectRef},
      handler: (params) => _guarded(() async {
        useCases.setDefaultProject(_project(params).id);
        return {'settings': store.settings.toRow()};
      }),
    ),
    AibIntent(
      name: 'settings.deleteCompleted',
      description:
          'Deletes every completed todo in every project that is not '
          'archived. Cannot be undone.',
      effect: .destructive,
      aliases: const ['Erledigte löschen', 'Aufräumen'],
      handler: (_) => _guarded(() async => {'deleted': useCases.deleteCompleted()}),
    ),
  ];
}
