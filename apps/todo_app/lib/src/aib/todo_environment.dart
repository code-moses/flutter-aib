import 'package:aib_core/aib_core.dart';
import 'package:aib_flutter/aib_flutter.dart';
import 'package:flutter/widgets.dart';

import '../app/ui_state.dart';
import '../app/use_cases.dart';
import '../data/todo_store.dart';
import '../semantics_quality.dart';

/// Wires the todo app into the benchmark framework: fixture reset, state
/// queries, fingerprint, semantics bridge and the intent catalog. The whole
/// per-app integration surface (spec §8.2).
FlutterEnvironment buildTodoEnvironment({
  required TodoStore store,
  required TodoUseCases useCases,
  required UiState uiState,
  required GlobalKey<NavigatorState> navigatorKey,
  Future<void> Function()? settle,
  SemanticsQuality quality = .good,

  /// The semantics bridge's opt-in checks; null installs it with none.
  SemanticsBridge? semantics,

  /// The app's frame costs as resource samples; null samples none.
  FrameAttribution? frames,
}) {
  final environment = FlutterEnvironment(
    frames: frames,
    // The degraded build is a *different* environment, not a variant of the
    // same one: `semantics_degradation_delta` (§6.4) compares two runs, and
    // the id keeps them from being resumed or aggregated into each other.
    environmentId: quality == .bad ? 'todo_app@bad-semantics' : 'todo_app',
    version: '1.0.0',
    metadata: {'semanticsQuality': quality.name},
    settle: settle,
    onReset: (fixtureData) async {
      // Full app state = data + navigation + transient UI state (§5.3).
      navigatorKey.currentState?.popUntil((route) => route.isFirst);
      uiState.reset();
      store.seed(fixtureData);
    },
    onStateQuery: (query) async {
      // `view.*` exposes the transient UI state next to the data. Without it
      // search/filter/navigation tasks cannot be scored at all: their final
      // state is identical to the initial one, so only the milestone timeline
      // (`groundTruth.milestones`, §5.2 stateSequence) can see them.
      //   view.state           -> one row {search, filter, visibleCount}
      //   view.visible         -> the rows the list screen currently shows
      final visible = useCases.findTodos(query: uiState.searchQuery, completed: uiState.completedFilter);
      final result = SimpleQuery.parse(query.query).run({
        'db': {'todos': store.rows()},
        'view': {
          'state': [
            {'search': uiState.searchQuery, 'filter': uiState.filter.name, 'visibleCount': visible.length},
          ],
          'visible': [for (final todo in visible) todo.toRow()],
        },
      });
      return StateQueryResult(query: query.query, count: result.count, items: result.items);
    },
    // "Relevant app state" for the state-diff metrics is data *and* list view
    // state. With the data alone, an action that narrows the list hashes
    // identically before and after and counts as redundant. Navigation stays
    // outside: it is a means, not an end state.
    fingerprint: () async => jsonFingerprint({
      'todos': store.rows(),
      'view': {'search': uiState.searchQuery, 'filter': uiState.filter.name},
    }),
  );

  (semantics ?? SemanticsBridge()).install(environment);
  IntentBridge()
    ..registerAll(buildTodoIntents(useCases, uiState))
    ..install(environment);
  GenUiBridge(dataContextProvider: () async => {'todos': store.rows()}).install(environment);
  return environment;
}

/// The intent API mirrors the UI capabilities 1:1 and calls the same
/// use-case layer (parity, spec §8.1) — including the list's search and
/// filter, which are UI state rather than data.
List<AibIntent> buildTodoIntents(TodoUseCases useCases, UiState uiState) {
  JsonMap targetSchema() => {
    'type': 'object',
    'properties': {
      'id': {'type': 'string', 'description': 'Todo id'},
      'title': {'type': 'string', 'description': 'Exact todo title'},
    },
  };
  Future<T> guarded<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on DomainError catch (e) {
      throw IntentRejected(e.message);
    }
  }

  return [
    AibIntent(
      name: 'todo.create',
      description: 'Creates a todo (title required, dueDate YYYY-MM-DD).',
      paramsSchema: const {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
          'dueDate': {'type': 'string', 'pattern': r'^\d{4}-\d{2}-\d{2}$'},
          'notes': {'type': 'string'},
        },
        'required': ['title'],
      },
      handler: (params) => guarded(
        () async => {
          'id': useCases.createTodo(
            title: params['title'] as String? ?? '',
            dueDate: params['dueDate'] as String?,
            notes: params['notes'] as String?,
          ),
        },
      ),
    ),
    AibIntent(
      name: 'todo.update',
      description: 'Updates fields of a todo addressed by id or exact title.',
      paramsSchema: {
        'type': 'object',
        'properties': {
          ...asJsonMap(targetSchema()['properties']),
          'set': {
            'type': 'object',
            'properties': {
              'title': {'type': 'string'},
              'dueDate': {'type': 'string'},
              'notes': {'type': 'string'},
              'completed': {'type': 'boolean'},
            },
          },
        },
        'required': ['set'],
      },
      handler: (params) => guarded(() async {
        final target = useCases.resolveTarget(id: params['id'] as String?, title: params['title'] as String?);
        final updates = asJsonMap(params['set']);
        useCases.updateTodo(
          target.id,
          title: updates['title'] as String?,
          dueDate: updates['dueDate'] as String?,
          notes: updates['notes'] as String?,
          completed: updates['completed'] as bool?,
        );
        return {'updated': target.id};
      }),
    ),
    AibIntent(
      name: 'todo.delete',
      description: 'Deletes a todo addressed by id or exact title.',
      paramsSchema: targetSchema(),
      handler: (params) => guarded(() async {
        final target = useCases.resolveTarget(id: params['id'] as String?, title: params['title'] as String?);
        useCases.deleteTodo(target.id);
        return {'deleted': target.id};
      }),
    ),
    AibIntent(
      name: 'todo.toggle',
      description: 'Toggles completion of a todo (by id or exact title).',
      paramsSchema: targetSchema(),
      handler: (params) => guarded(() async {
        final target = useCases.resolveTarget(id: params['id'] as String?, title: params['title'] as String?);
        return {'completed': useCases.toggleComplete(target.id)};
      }),
    ),
    AibIntent(
      name: 'todo.search',
      description:
          'Sets the list search text and/or the completion filter '
          '(all|open|done) — the same view state the search field and the '
          'filter chips of the list screen control.',
      paramsSchema: const {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
          'filter': {
            'type': 'string',
            'enum': ['all', 'open', 'done'],
          },
        },
      },
      handler: (params) => guarded(() async {
        final query = params['query'] as String?;
        if (query != null) uiState.searchQuery = query;
        final filter = params['filter'] as String?;
        if (filter != null) {
          uiState.filter =
              TodoFilter.values.asNameMap()[filter] ??
              (throw IntentRejected(
                'unknown filter "$filter" '
                '(expected all|open|done)',
              ));
        }
        final visible = useCases.findTodos(query: uiState.searchQuery, completed: uiState.completedFilter);
        return {'search': uiState.searchQuery, 'filter': uiState.filter.name, 'visibleCount': visible.length};
      }),
    ),
    AibIntent(
      name: 'todo.find',
      description: 'Finds todos by title substring and/or completion state.',
      paramsSchema: const {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
          'completed': {'type': 'boolean'},
        },
      },
      handler: (params) => guarded(() async {
        final todos = useCases.findTodos(query: params['query'] as String?, completed: params['completed'] as bool?);
        return {
          'count': todos.length,
          'todos': [for (final todo in todos) todo.toRow()],
        };
      }),
    ),
  ];
}
