import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:aib_otel/aib_otel.dart';
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' show SpanStatusCode;
import 'package:dartastic_opentelemetry/testing.dart' show InMemorySpanExporter, maybeInitializeOtelForTest;
import 'package:test/test.dart';

void main() {
  late InMemorySpanExporter spans;

  setUpAll(() async => spans = (await maybeInitializeOtelForTest()).spans);
  setUp(() => spans.clear());

  test('an episode is one trace, and its tools are the exchanges', () async {
    final task = TaskSpec(
      id: 't',
      title: 't',
      instruction: 'Create a todo.',
      budget: Budget(maxSteps: 10, maxWallClockSeconds: 30),
      fixture: const FixtureRef(
        id: 'f',
        data: {
          'db': {'todos': <Object>[]},
        },
      ),
    );
    final result = await BenchmarkEngine(observer: OtelTraceObserver()).runEpisode(
      task: task,
      agent: ScriptedAgent(
        scripts: {
          't': [
            const Envelope(
              key: 'state.list',
              kind: .observe,
              payload: {'path': 'db.todos'},
              decision: AgentDecision(model: 'scripted', tokensPrompt: 100, tokensCompletion: 20, llmLatencyMs: 5, llmCalls: 1),
            ),
            const Envelope(
              key: 'state.insert',
              kind: .act,
              payload: {
                'path': 'db.todos',
                'item': {'title': 'Milch kaufen'},
              },
            ),
          ],
        },
      ),
      environment: MockEnvironment(),
      meta: EpisodeMeta(
        runId: 'r',
        episodeId: 'e',
        taskId: 't',
        agentId: 'scripted',
        environmentId: 'mock',
        repetition: 1,
        startedAt: DateTime.utc(2026, 9, 14),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final record = await RunEvaluation().evaluateEpisode(result.trace, task);

    final episode = spans.findSpanByName(Aib.episodeSpan)!;
    final decisions = spans.findSpansByName(GenAi.invokeAgent);
    final tools = spans.findSpansByName(GenAi.executeTool);

    expect(tools, hasLength((record.metrics['action_count']! + record.metrics['observation_count']!).toInt()));
    for (final tool in tools) {
      expect(decisions.map((d) => d.spanContext.spanId), contains(tool.parentSpanContext!.spanId));
    }
    expect({for (final span in spans.spans) span.spanContext.traceId}, {episode.spanContext.traceId});
    expect(episode.status, isNot(SpanStatusCode.Error));
  });
}
