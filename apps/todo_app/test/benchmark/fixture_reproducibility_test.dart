/// M2 reproducibility criterion (spec §11 Phase 2): 10× reset -> identical
/// snapshots. Verified on two levels: data fingerprint (byte-exact store
/// state) and structural semantics tree (ids/rects stripped — semantics node
/// ids are allocation-order dependent, ADR 0004). Between resets the state
/// is deliberately mutated to prove reset really restores, not just retains.
library;

import 'package:aib_core/aib_core.dart';
import 'package:aib_flutter/aib_flutter.dart' show structuralTree;
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  final suite = loadTodoSuite();

  testWidgets('10× reset restores identical fixture state and UI', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await TodoHarness.boot(tester);
    final environment = harness.environment;
    final fixture = suite.tasks.first.fixture;
    final fingerprinter = environment as StateFingerprintProvider;

    final fingerprints = <String>{};
    final structuralTrees = <String>{};

    for (var i = 0; i < 10; i++) {
      await environment.reset(fixture);
      await tester.pumpAndSettle();

      fingerprints.add(await fingerprinter.stateFingerprint());
      final tree = await environment.handle(const Envelope(key: 'semantics.tree', kind: .observe));
      expect(tree.status, EnvelopeStatus.ok);
      structuralTrees.add(stableStringify(structuralTree(tree.payload['tree'])));

      // Dirty the state: create, complete, delete, search — the next reset
      // must erase all of it.
      await environment.handle(
        Envelope(
          key: 'intents.invoke',
          kind: .act,
          payload: {
            'intent': 'todo.create',
            'params': {'title': 'Müll $i', 'dueDate': '2026-08-0${(i % 9) + 1}'},
          },
        ),
      );
      await environment.handle(
        const Envelope(
          key: 'intents.invoke',
          kind: .act,
          payload: {
            'intent': 'todo.delete',
            'params': {'title': 'Wäsche waschen'},
          },
        ),
      );
    }

    expect(fingerprints, hasLength(1), reason: 'data fingerprint must be identical across all 10 resets');
    expect(structuralTrees, hasLength(1), reason: 'semantics structure must be identical across all 10 resets');

    // Ground-truth queries see the pristine fixture as well.
    final snapshot = await environment.captureFinalState([const StateQuery('db.todos'), const StateQuery("db.todos.where(completed == false)")]);
    expect(snapshot.resultFor('db.todos')!.count, 10);
    expect(snapshot.resultFor("db.todos.where(completed == false)")!.count, 7);
    handle.dispose();
  });

  testWidgets('reset also restores navigation and transient UI state', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await TodoHarness.boot(tester);
    final environment = harness.environment;
    await environment.reset(suite.tasks.first.fixture);
    await tester.pumpAndSettle();

    // Navigate into the editor and type — then reset.
    await environment.handle(const Envelope(key: 'semantics.tap', kind: .act, payload: {'label': 'Add todo'}));
    expect(find.text('New todo'), findsOneWidget);

    await environment.reset(suite.tasks.first.fixture);
    await tester.pumpAndSettle();
    expect(find.text('New todo'), findsNothing, reason: 'reset must pop back to the root screen');
    expect(find.text('Todos'), findsOneWidget);
    handle.dispose();
  });
}
