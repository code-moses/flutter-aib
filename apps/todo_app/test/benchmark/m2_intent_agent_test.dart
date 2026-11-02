/// M2 — ScriptedAgent drives the real todo app through the framework via
/// the intent modality (intents.catalog / intents.invoke).
library;

import 'package:aib_core/aib_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Envelope invoke(String intent, JsonMap params) => Envelope(key: 'intents.invoke', kind: .act, payload: {'intent': intent, 'params': params});

const observeCatalog = Envelope(key: 'intents.catalog', kind: .observe);

void main() {
  final suite = loadTodoSuite();

  testWidgets('todo.create.simple via intents -> success, exact metrics', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await TodoHarness.boot(tester);
    final (:record, :trace) = await runScripted(
      harness: harness,
      task: suite.taskById('todo.create.simple')!,
      agentId: 'scripted-intent',
      script: [
        observeCatalog,
        invoke('todo.create', {'title': 'Milch kaufen', 'dueDate': '2026-07-10'}),
      ],
    );
    expect(record.verdict.type, VerdictType.success, reason: record.verdict.reason ?? '');
    expect(record.metrics['action_count'], 1);
    expect(record.metrics['observation_count'], 1);
    expect(record.metrics['path_efficiency'], 1.0);
    expect(record.metrics['redundant_action_ratio'], 0.0);
    expect(record.metrics['kind_integrity_violations'], 0);
    handle.dispose();
  });

  testWidgets('todo.complete.overdue via intents (batch task)', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await TodoHarness.boot(tester);
    final (:record, :trace) = await runScripted(
      harness: harness,
      task: suite.taskById('todo.complete.overdue')!,
      agentId: 'scripted-intent',
      script: [
        invoke('todo.find', {'completed': false}),
        invoke('todo.update', {
          'title': 'Blumen gießen',
          'set': {'completed': true},
        }),
        invoke('todo.update', {
          'title': 'Reifen wechseln',
          'set': {'completed': true},
        }),
      ],
    );
    expect(record.verdict.type, VerdictType.success, reason: record.verdict.reason ?? '');
    // todo.find is declared act (it went through intents.invoke) — the
    // fixture-accurate optimum is 2, so the detour shows up in the ratio.
    expect(record.metrics['action_count'], 3);
    expect(record.metrics['path_efficiency'], closeTo(2 / 3, 1e-9));
    handle.dispose();
  });

  testWidgets('wrong due date yields the declared partial credit', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await TodoHarness.boot(tester);
    final (:record, :trace) = await runScripted(
      harness: harness,
      task: suite.taskById('todo.create.simple')!,
      agentId: 'scripted-intent',
      script: [
        invoke('todo.create', {'title': 'Milch kaufen', 'dueDate': '2026-07-11'}),
      ],
    );
    expect(record.verdict.type, VerdictType.partial);
    expect(record.verdict.score, 0.5);
    expect(record.verdict.label, 'Task angelegt, Datum falsch');
    handle.dispose();
  });

  testWidgets('domain rejection is a structured failed envelope, '
      'not an environment crash', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await TodoHarness.boot(tester);
    final (:record, :trace) = await runScripted(
      harness: harness,
      task: suite.taskById('todo.delete.single')!,
      agentId: 'scripted-intent',
      script: [
        invoke('todo.delete', {'title': 'Gibt es nicht'}),
        invoke('todo.delete', {'title': 'Obsolete Aufgabe'}),
      ],
    );
    // State goal reached, but the failed envelope costs the traceAssertion
    // criterion (weight 0.2) -> partial 0.8.
    expect(record.verdict.type, VerdictType.partial);
    expect(record.verdict.score, closeTo(0.8, 1e-9));
    expect(record.metrics['infrastructure_error'], 0, reason: 'domain rejections must never count as framework faults');
    handle.dispose();
  });
}
