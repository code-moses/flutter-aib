import 'package:aib_agents/agents.dart';
import 'package:aib_agents/testing.dart';
import 'package:aib_core/ports.dart';
import 'package:test/test.dart';

const _task = TaskSpec(
  id: 't',
  title: 't',
  instruction: 'find the order',
  fixture: FixtureRef(id: 'f', data: {}),
  budget: Budget(maxSteps: 20, maxWallClockSeconds: 60),
);

const _descriptor = EnvironmentDescriptor(
  environmentId: 'env',
  envelopes: [
    EnvelopeSpec(key: 'intents.catalog', kind: .observe),
    EnvelopeSpec(key: 'semantics.tree', kind: .observe),
  ],
);

const _budget = BudgetStatus(stepsUsed: 0, maxSteps: 20, elapsedMs: 0, maxWallClockMs: 60000, tokensUsed: 0);

LlmResponse _tree(int i) => FakeLlmClient.calls([('observe_tree', <String, Object?>{})], text: 'look $i');

void main() {
  test('past the stride the old turns become one summary, priced as a side call; the rest stays', () async {
    final llm = FakeLlmClient(
      responses: [
        _tree(1),
        _tree(2),
        _tree(3),
        const LlmResponse(text: 'Looked at the tree three times; order id is A-17.'),
        FakeLlmClient.calls([
          ('done', {'summary': 'A-17'}),
        ]),
      ],
    );
    final agent = HybridAgent(
      client: llm,
      config: const AgentConfig(parallelToolCalls: false, compaction: CompactionConfig(after: 2, keep: 1)),
    );
    await agent.startEpisode(_task, _descriptor);
    await agent.next(null, _budget);
    for (var i = 1; i <= 3; i++) {
      final step = await agent.next(EnvelopeResult.ok({'tree': 'node $i'}), _budget);
      expect(step.key, 'semantics.tree');
    }
    final done = await agent.next(EnvelopeResult.ok({'tree': 'node 4'}), _budget);
    expect(done.key, 'meta.done');

    final summaryRequest = llm.requests[3];
    expect(summaryRequest.tools, isEmpty);
    expect(summaryRequest.messages.last.content, contains('agent called observe_tree'));
    // node 1 answered the bootstrap catalogue: the opening, never compacted.
    expect(summaryRequest.messages.last.content, contains('node 2'));

    final last = llm.requests[4];
    final contents = [for (final m in last.messages) m.content];
    expect(contents.where((c) => c.startsWith(Compactor.heading)).single, contains('A-17'));
    // The opening (system, briefing, catalogue) stays; of the three tool
    // results the last is kept, with the turn that asked for it.
    expect(last.messages.first.role, LlmRole.system);
    expect(contents.any((c) => c.contains('node 1')), isTrue);
    expect(contents.any((c) => c.contains('node 2') || c.contains('node 3')), isFalse);
    expect(contents.last, contains('node 4'));
    expect(last.messages.length, lessThan(llm.requests[2].messages.length + 2));

    final sideCalls = done.decision!.extra![AgentDecision.sideCallsKey] as List;
    expect((sideCalls.single as Map)['purpose'], 'compaction');
    expect(done.decision!.note, contains('compacted=2'));
  });

  test('a summary that fails leaves the conversation as it was', () async {
    final llm = _FailingSummary();
    final agent = HybridAgent(
      client: llm,
      config: const AgentConfig(parallelToolCalls: false, compaction: CompactionConfig(after: 1, keep: 1)),
    );
    await agent.startEpisode(_task, _descriptor);
    await agent.next(null, _budget);
    await agent.next(EnvelopeResult.ok({'tree': 1}), _budget);
    await agent.next(EnvelopeResult.ok({'tree': 2}), _budget);
    final third = await agent.next(EnvelopeResult.ok({'tree': 3}), _budget);
    expect(third.decision!.note, contains('compaction_failed=1'));
  });

  test('the config refuses a stride that keeps everything', () {
    expect(() => CompactionConfig.fromJson({'after': 2, 'keep': 2}), throwsFormatException);
    expect(() => CompactionConfig.fromJson({'stride': 2}), throwsFormatException);
    expect(AgentConfig.fromJson({'compaction': <String, Object?>{}}).toJson()['compaction'], {
      'after': 8,
      'keep': 4,
      'maxSummaryTokens': 400,
      'maxTranscriptChars': 24000,
    });
    expect(const AgentConfig().toJson(), isNot(contains('compaction')));
  });
}

/// Answers every agent turn with observe_tree; a request without tools (the
/// summary) fails.
final class _FailingSummary implements LlmClient {
  @override
  String get model => 'fake';

  @override
  Future<LlmResponse> complete(LlmRequest request, {CancellationToken? cancellation}) async {
    if (request.tools.isEmpty) throw LlmClientException('down', kind: LlmErrorKind.server);
    return _tree(0);
  }
}
