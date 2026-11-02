import 'package:flutter/material.dart';

import 'src/workspace/navigation.dart';
import 'src/workspace/store.dart';
import 'src/workspace/use_cases.dart';
import 'src/workspace/workspace_app.dart';

/// Standalone entry point of the workspace variant (suite `todo_v2`), for
/// manual exploration:
///
/// ```sh
/// fvm flutter run -t lib/main_workspace.dart
/// ```
///
/// The benchmark does not start here: it boots the same app in the widget
/// test harness and seeds it from `suites/fixtures/todo_workspace_seed.json`
/// on every reset. The demo data below is a small excerpt of that fixture.
void main() {
  final store = WorkspaceStore()
    ..seed(const {
      'db': {
        'settings': {'today': '2026-07-01', 'defaultProjectId': 'p-privat'},
        'projects': [
          {'id': 'p-arbeit', 'name': 'Arbeit', 'archived': false},
          {'id': 'p-privat', 'name': 'Privat', 'archived': false},
          {'id': 'p-urlaub', 'name': 'Urlaub 2026', 'archived': false},
          {'id': 'p-alt', 'name': 'Altprojekt', 'archived': true},
        ],
        'todos': [
          {
            'id': 'w-01',
            'projectId': 'p-arbeit',
            'title': 'Projektbericht schreiben',
            'dueDate': '2026-07-08',
            'priority': 'high',
            'tags': ['Bericht'],
          },
          {'id': 'w-04', 'projectId': 'p-arbeit', 'title': 'Arzt anrufen', 'dueDate': '2026-07-03'},
          {'id': 'w-08', 'projectId': 'p-privat', 'title': 'Arzt anrufen', 'dueDate': '2026-06-29'},
          {'id': 'w-10', 'projectId': 'p-privat', 'title': 'Anmeldung gesendet', 'completed': true},
          {
            'id': 'w-17',
            'projectId': 'p-urlaub',
            'title': 'Urlaub buchen',
            'dueDate': '2026-07-10',
            'priority': 'high',
            'subtasks': [
              {'id': 's-01', 'title': 'Flüge vergleichen', 'done': false},
              {'id': 's-02', 'title': 'Hotel reservieren', 'done': false},
              {'id': 's-03', 'title': 'Mietwagen prüfen', 'done': true},
            ],
          },
          {'id': 'w-22', 'projectId': 'p-alt', 'title': 'Domain kündigen', 'dueDate': '2026-04-01'},
        ],
      },
    });
  runApp(WorkspaceApp(store: store, useCases: WorkspaceUseCases(store), nav: WorkspaceNav()));
}
