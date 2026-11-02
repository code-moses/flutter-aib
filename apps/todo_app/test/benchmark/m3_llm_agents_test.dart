/// M3 groundwork: the *complete* LLM agent stack (prompt building, tool
/// loop, telemetry, envelope mapping) drives the real todo app — with a
/// scripted FakeLlmClient instead of a live model, so the run is
/// deterministic and key-free. Live runs: see live/m3_live_benchmark_test.dart.
library;

import 'package:aib_agents/aib_agents.dart';
import 'package:aib_agents/testing.dart';
import 'package:aib_core/aib_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/src/semantics_quality.dart';

import 'harness.dart';

Future<({EpisodeRecord record, EpisodeTrace trace})> runLlmAgent({
  required WidgetTester tester,
  required TaskSpec task,
  required ToolLoopAgent agent,
  SemanticsQuality quality = .good,
}) async {
  final harness = await TodoHarness.boot(tester, quality: quality);
  final result = await BenchmarkEngine().runEpisode(
    task: task,
    agent: agent,
    environment: harness.environment,
    meta: episodeMeta(task.id, agent.manifest.agentId),
  );
  final trace = TraceCodec.decode(TraceCodec.encode(result.trace));
  final record = await RunEvaluation().evaluateEpisode(trace, task);
  return (record: record, trace: trace);
}

void main() {
  final suite = loadTodoSuite();

  testWidgets('SemanticsAgent (fake LLM) completes todo.create.simple '
      'through the real UI', (tester) async {
    final handle = tester.ensureSemantics();
    final llm = FakeLlmClient(
      responses: [
        FakeLlmClient.calls([
          ('tap', {'label': 'Add todo'}),
        ]),
        FakeLlmClient.calls([
          ('set_text', {'label': 'Title', 'text': 'Milch kaufen'}),
        ]),
        FakeLlmClient.calls([
          ('set_text', {'label': 'Due date (YYYY-MM-DD)', 'text': '2026-07-10'}),
        ]),
        FakeLlmClient.calls([
          ('tap', {'label': 'Save todo'}),
        ]),
        FakeLlmClient.calls([
          ('done', {'summary': 'created'}),
        ]),
      ],
    );
    final (:record, :trace) = await runLlmAgent(
      tester: tester,
      task: suite.taskById('todo.create.simple')!,
      agent: SemanticsAgent(client: llm),
    );

    expect(record.verdict.type, VerdictType.success, reason: record.verdict.reason ?? '');
    expect(record.metrics['action_count'], 4);
    expect(record.metrics['observation_count'], 1, reason: 'deterministic bootstrap tree observation');
    expect(record.metrics['llm_roundtrips'], 5);
    expect(record.metrics['tokens_total'], 5 * 120);
    expect(record.metrics['kind_integrity_violations'], 0);

    // The bootstrap observation reached the model as conversation context.
    final firstRequest = llm.requests.first;
    expect(firstRequest.messages.last.content, contains('Add todo'));
    expect(firstRequest.messages.first.content, contains('semantics tree'));
    handle.dispose();
  });

  testWidgets('IntentAgent (fake LLM) completes todo.create.simple '
      'via discovered intents', (tester) async {
    final handle = tester.ensureSemantics();
    // Catalog schema 3: the bootstrap catalog is a listing and nothing in it
    // is callable. The first turn buys the schemas, the second acts.
    final llm = FakeLlmClient(
      responses: [
        FakeLlmClient.calls([
          (
            'describe_intents',
            {
              'names': ['todo.create'],
            },
          ),
        ]),
        FakeLlmClient.calls([
          ('intent_todo_create', {'title': 'Milch kaufen', 'dueDate': '2026-07-10'}),
        ]),
        FakeLlmClient.calls([
          ('done', {'summary': 'created'}),
        ]),
      ],
    );
    final (:record, :trace) = await runLlmAgent(
      tester: tester,
      task: suite.taskById('todo.create.simple')!,
      agent: IntentAgent(client: llm),
    );

    expect(record.verdict.type, VerdictType.success, reason: record.verdict.reason ?? '');
    expect(record.metrics['action_count'], 1);
    expect(record.metrics['path_efficiency'], 1.0);
    expect(record.metrics['llm_roundtrips'], 3);

    // Describing is what makes an intent callable: the first request offers
    // the way to ask, the second offers what was asked for.
    expect(llm.requests.first.tools.map((t) => t.name), containsAll(['describe_intents', 'done']));
    expect(llm.requests.first.tools.map((t) => t.name), isNot(contains('intent_todo_create')));
    expect(llm.requests[1].tools.map((t) => t.name), containsAll(['intent_todo_create', 'done']));
    handle.dispose();
  });

  testWidgets('strategy contrast: intent path beats UI path on efficiency '
      'for the same goal', (tester) async {
    final handle = tester.ensureSemantics();
    // Same task, both fake-LLM agents — the framework produces directly
    // comparable records (the core of the thesis comparison, spec §6.5).
    final task = suite.taskById('todo.complete.single')!;
    final semantics = await runLlmAgent(
      tester: tester,
      task: task,
      agent: SemanticsAgent(
        client: FakeLlmClient(
          responses: [
            FakeLlmClient.calls([
              ('tap', {'label': "Complete 'Steuererklärung abgeben'"}),
            ]),
            FakeLlmClient.calls([('done', <String, Object?>{})]),
          ],
        ),
      ),
    );
    final intent = await runLlmAgent(
      tester: tester,
      task: task,
      agent: IntentAgent(
        client: FakeLlmClient(
          responses: [
            FakeLlmClient.calls([
              (
                'describe_intents',
                {
                  'names': ['todo.toggle'],
                },
              ),
            ]),
            FakeLlmClient.calls([
              ('intent_todo_toggle', {'title': 'Steuererklärung abgeben'}),
            ]),
            FakeLlmClient.calls([('done', <String, Object?>{})]),
          ],
        ),
      ),
    );

    expect(semantics.record.verdict.type, VerdictType.success, reason: semantics.record.verdict.reason ?? '');
    expect(intent.record.verdict.type, VerdictType.success, reason: intent.record.verdict.reason ?? '');
    // Both used 1 action here, but the semantics agent paid for the tree.
    expect(
      semantics.record.metrics['observation_bytes']!,
      greaterThan(intent.record.metrics['observation_bytes']!),
      reason: 'tree observation is heavier than the intent catalog',
    );
    handle.dispose();
  });
}
