/// M2 — ScriptedAgent drives the real todo app through the framework via
/// the semantics modality (UI path: tree -> tap -> setText -> save), including
/// the good/bad degradation contrast (spec §8.1).
library;

import 'package:aib_core/aib_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const observeTree = Envelope(key: 'semantics.tree', kind: .observe);

Envelope tap(String label) => Envelope(key: 'semantics.tap', kind: .act, payload: {'label': label});

Envelope setText(String label, String text) => Envelope(key: 'semantics.setText', kind: .act, payload: {'label': label, 'text': text});

/// UI path for todo.create.simple: FAB -> title -> due date -> save.
final createViaUi = [
  observeTree,
  tap('Add todo'),
  observeTree,
  setText('Title', 'Milch kaufen'),
  setText('Due date (YYYY-MM-DD)', '2026-07-10'),
  tap('Save todo'),
];

void main() {
  final suite = loadTodoSuite();

  testWidgets('good semantics: create task via UI path -> success', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await TodoHarness.boot(tester);
    final (:record, :trace) = await runScripted(
      harness: harness,
      task: suite.taskById('todo.create.simple')!,
      agentId: 'scripted-semantics',
      script: createViaUi,
    );
    expect(record.verdict.type, VerdictType.success, reason: record.verdict.reason ?? '');
    expect(record.metrics['action_count'], 4);
    expect(record.metrics['observation_count'], 2);
    // optimalSteps=1 (intent path) vs 4 UI actions — by design (§6.2).
    expect(record.metrics['path_efficiency'], 0.25);
    expect(record.metrics['observation_bytes'], greaterThan(0));
    handle.dispose();
  });

  testWidgets('good semantics: complete a task by checkbox label', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await TodoHarness.boot(tester);
    final (:record, :trace) = await runScripted(
      harness: harness,
      task: suite.taskById('todo.complete.single')!,
      agentId: 'scripted-semantics',
      script: [observeTree, tap("Complete 'Steuererklärung abgeben'")],
    );
    expect(record.verdict.type, VerdictType.success, reason: record.verdict.reason ?? '');
    handle.dispose();
  });

  testWidgets('good semantics: delete via labelled delete button', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await TodoHarness.boot(tester);
    final (:record, :trace) = await runScripted(
      harness: harness,
      task: suite.taskById('todo.delete.single')!,
      agentId: 'scripted-semantics',
      script: [observeTree, tap("Delete 'Obsolete Aufgabe'")],
    );
    expect(record.verdict.type, VerdictType.success, reason: record.verdict.reason ?? '');
    handle.dispose();
  });

  testWidgets('bad semantics: the identical label-based script fails '
      '(semantics_degradation_delta groundwork)', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await TodoHarness.boot(tester, quality: .bad);
    final (:record, :trace) = await runScripted(
      harness: harness,
      task: suite.taskById('todo.create.simple')!,
      agentId: 'scripted-semantics',
      script: createViaUi,
    );
    // The FAB has no label in the bad variant -> tap fails, nothing is
    // created. Functionality identical, semantics degraded — exactly the
    // contrast the suite is built to measure.
    expect(record.verdict.type, VerdictType.failure);
    final failedEnvelopes = trace.exchanges().where((x) => x.status == 'failed');
    expect(failedEnvelopes, isNotEmpty);
    handle.dispose();
  });

  testWidgets('bad variant still exposes full intent parity', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await TodoHarness.boot(tester, quality: .bad);
    final (:record, :trace) = await runScripted(
      harness: harness,
      task: suite.taskById('todo.create.simple')!,
      agentId: 'scripted-intent',
      script: [
        const Envelope(
          key: 'intents.invoke',
          kind: .act,
          payload: {
            'intent': 'todo.create',
            'params': {'title': 'Milch kaufen', 'dueDate': '2026-07-10'},
          },
        ),
      ],
    );
    expect(record.verdict.type, VerdictType.success, reason: record.verdict.reason ?? '');
    handle.dispose();
  });
}
