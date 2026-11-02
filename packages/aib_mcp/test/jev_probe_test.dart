import 'package:aib_agents/testing.dart';
import 'package:aib_core/aib_core.dart';
import 'package:aib_mcp/src/jev_probe.dart';
import 'package:test/test.dart';

void main() {
  const fixture = {
    'suite': 'probe',
    'catalogue': [
      {'name': 'nav.open', 'summary': 'Show a page, from an id app.endpoints gave', 'aliases': <String>[]},
      {'name': 'app.endpoints', 'summary': 'List the data lists', 'aliases': <String>[]},
      {'name': 'time.start', 'summary': 'Start time tracking', 'aliases': <String>[]},
    ],
    'tasks': [
      {
        'id': 'open',
        'instruction': 'Show me the articles.',
        'language': 'en',
        'needed': ['nav.open', 'app.endpoints'],
      },
      {'id': 'refuse', 'instruction': 'Delete everything.', 'language': 'en', 'needed': <String>[]},
    ],
  };

  test('runs every variant on every backend and scores recall, floor, references and AUC', () async {
    final jev = FakeJevClient(
      noulFor: (text) => text.contains('nav.open')
          ? 0.7
          : text.contains('app.endpoints')
          ? 0.3
          : 0.2,
    );
    final result = await JevProbe.run(
      fixture: fixture,
      variants: [
        {'id': 'needed_v1'},
        {'id': 'call_rubric_state_v1'},
      ],
      backends: {
        'fake': {'backend': 'ollama', 'model': 'x', 'apiKey': 'secret'},
      },
      clientFor: (_) => jev,
    );
    expect(result['selections'] as List, hasLength(4));
    expect(asJsonMap(result['backends'])['fake'], isNot(contains('apiKey')));

    final rows = JevProbe.summarise(fixture: fixture, result: result, thresholds: const [0.5], minKeep: 2);
    expect(rows, hasLength(2));
    final row = rows.first;
    // Only the labelled task counts.
    expect(row['tasks'], 1);
    expect(asJsonMap(row['recall'])['0.5'], 0.5);
    expect(asJsonMap(row['recall'])['0.5+min2'], 1.0);
    // nav.open's summary names app.endpoints.
    expect(asJsonMap(row['recall'])['0.5+refs'], 1.0);
    expect(asJsonMap(row['kept'])['0.5+refs'], 2.0);
    // Both needed intents outscore time.start.
    expect(row['auc'], 1.0);
    expect(JevProbe.table(rows, thresholds: const [0.5], minKeep: 2), contains('| fake | needed_v1 |'));
  });
}
