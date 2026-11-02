/// The essential-state oracle (§5.2 `stateSequence`) against the real app.
///
/// These two suite tasks are the ones `finalStateMatch` cannot score at all:
/// searching and filtering leave the data untouched, so the final state of a
/// solved and an unsolved episode is byte-identical. Only the milestone
/// timeline recorded during the episode separates them — and it has to do so
/// through *both* modalities, otherwise the task would silently favour one
/// agent strategy over the other (parity, §8.1).
library;

import 'package:aib_core/aib_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const observeTree = Envelope(key: 'semantics.tree', kind: .observe);

Envelope tap(String label) => Envelope(key: 'semantics.tap', kind: .act, payload: {'label': label});

Envelope setText(String label, String text) => Envelope(key: 'semantics.setText', kind: .act, payload: {'label': label, 'text': text});

Envelope search(JsonMap params) => Envelope(key: 'intents.invoke', kind: .act, payload: {'intent': 'todo.search', 'params': params});

void main() {
  final suite = loadTodoSuite();

  testWidgets('todo.search.narrow via intents -> success', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await TodoHarness.boot(tester);
    final (:record, :trace) = await runScripted(
      harness: harness,
      task: suite.taskById('todo.search.narrow')!,
      agentId: 'scripted-intent',
      script: [
        search({'query': 'Reifen'}),
      ],
    );
    expect(record.verdict.type, VerdictType.success, reason: record.verdict.reason ?? '');
    expect(record.metrics['milestone_coverage'], 1.0);
    handle.dispose();
  });

  testWidgets('todo.search.narrow via the UI path -> success', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await TodoHarness.boot(tester);
    final (:record, :trace) = await runScripted(
      harness: harness,
      task: suite.taskById('todo.search.narrow')!,
      agentId: 'scripted-semantics',
      script: [observeTree, setText('Search', 'Reifen')],
    );
    expect(record.verdict.type, VerdictType.success, reason: record.verdict.reason ?? '');
    handle.dispose();
  });

  testWidgets('an episode that does nothing scores 0 on a task whose final '
      'state is unchanged by definition', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await TodoHarness.boot(tester);
    final task = suite.taskById('todo.search.narrow')!;
    final (:record, :trace) = await runScripted(harness: harness, task: task, agentId: 'scripted-idle', script: [observeTree]);

    // finalStateMatch passes — the data really is untouched — so without the
    // milestone the idle agent would look successful. The stateSequence
    // criterion carries 0.8 of the weight and fails, leaving exactly 0.2.
    expect(record.verdict.type, VerdictType.partial);
    expect(record.verdict.score, closeTo(0.2, 1e-9));
    expect(record.metrics['milestone_coverage'], 0.0);
    expect(
      (record.verdict.details[CriterionTypes.finalStateMatch] as Map)['score'],
      1.0,
      reason: 'the blindness of the terminal oracle is the point of the test',
    );
    handle.dispose();
  });

  testWidgets('todo.filter.open via intents -> success', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await TodoHarness.boot(tester);
    final (:record, :trace) = await runScripted(
      harness: harness,
      task: suite.taskById('todo.filter.open')!,
      agentId: 'scripted-intent',
      script: [
        search({'filter': 'open'}),
      ],
    );
    expect(record.verdict.type, VerdictType.success, reason: record.verdict.reason ?? '');
    handle.dispose();
  });

  testWidgets('todo.filter.open via the UI path -> success', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await TodoHarness.boot(tester);
    final (:record, :trace) = await runScripted(
      harness: harness,
      task: suite.taskById('todo.filter.open')!,
      agentId: 'scripted-semantics',
      script: [observeTree, tap('Open')],
    );
    expect(record.verdict.type, VerdictType.success, reason: record.verdict.reason ?? '');
    handle.dispose();
  });

  testWidgets('the wrong filter reaches neither milestone', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await TodoHarness.boot(tester);
    final (:record, :trace) = await runScripted(
      harness: harness,
      task: suite.taskById('todo.filter.open')!,
      agentId: 'scripted-intent',
      script: [
        search({'filter': 'done'}),
      ],
    );
    expect(record.metrics['milestone_coverage'], 0.0);
    expect((record.verdict.details[CriterionTypes.stateSequence] as Map)['detail'] as String, contains('never reached'));
    handle.dispose();
  });

  testWidgets('probes land in the trace and cost nothing the agent is '
      'charged for', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await TodoHarness.boot(tester);
    final (:record, :trace) = await runScripted(
      harness: harness,
      task: suite.taskById('todo.search.narrow')!,
      agentId: 'scripted-intent',
      script: [
        search({'query': 'Reifen'}),
      ],
    );

    final probes = trace.probes();
    expect(probes.map((p) => p.seq), [-1, 0], reason: 'initial state plus one probe per exchange');
    expect(probes.first.resultFor('view.visible')!.count, 10, reason: 'unfiltered list at reset');
    expect(probes.last.resultFor('view.visible')!.count, 1);

    // action_count / path_efficiency must not see the probes at all.
    expect(record.metrics['action_count'], 1);
    expect(record.metrics['path_efficiency'], 1.0);
    handle.dispose();
  });
}
