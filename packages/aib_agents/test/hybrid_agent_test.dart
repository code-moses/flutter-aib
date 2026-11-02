import 'package:aib_agents/agents.dart';
import 'package:aib_agents/aib_agents.dart' show LlmClientFactory;
import 'package:aib_agents/testing.dart';
import 'package:aib_core/ports.dart';
import 'package:test/test.dart';

const _task = TaskSpec(
  id: 't1',
  title: 'Phase 0',
  instruction: 'do the thing',
  fixture: FixtureRef(id: 'fx', data: {}),
  budget: Budget(maxSteps: 10, maxWallClockSeconds: 60),
);

const _descriptor = EnvironmentDescriptor(
  environmentId: 'env',
  envelopes: [
    EnvelopeSpec(key: 'intents.catalog', kind: .observe),
    EnvelopeSpec(key: 'intents.invoke', kind: .act),
  ],
);

const _budget = BudgetStatus(stepsUsed: 0, maxSteps: 10, elapsedMs: 0, maxWallClockMs: 60000, tokensUsed: 0);

void main() {
  group('HybridAgent', () {
    test('union mode offers every enabled strategy at once', () async {
      final agent = HybridAgent(client: FakeLlmClient());
      await agent.startEpisode(_task, _descriptor);
      final names = agent.strategyTools.map((t) => t.name).toSet();
      expect(names, containsAll({'observe_tree', 'observe_data', 'ask_user'}));
    });

    test('a disabled strategy contributes nothing', () async {
      final agent = HybridAgent(
        client: FakeLlmClient(),
        router: const RouterConfig(strategies: ['intents', 'user']),
      );
      await agent.startEpisode(_task, _descriptor);
      final names = agent.strategyTools.map((t) => t.name).toSet();
      expect(names, contains('ask_user'));
      expect(names, isNot(contains('observe_tree')));
    });

    test('records which strategy each envelope came from', () async {
      final agent = HybridAgent(
        client: FakeLlmClient(
          responses: [
            FakeLlmClient.calls([
              ('ask_user', {'type': 'text', 'prompt': 'which one?'}),
            ]),
          ],
        ),
      );
      await agent.startEpisode(_task, _descriptor);

      final bootstrap = await agent.next(null, _budget);
      expect(bootstrap.key, 'intents.catalog');
      expect(bootstrap.decision?.note, contains('route=intents'));

      final asked = await agent.next(EnvelopeResult.ok(), _budget);
      expect(asked.key, 'user.ask');
      expect(asked.decision?.note, contains('route=user'));
    });

    test('cascade escalates once the first strategy cannot deliver', () async {
      final agent = HybridAgent(
        client: FakeLlmClient(),
        router: const RouterConfig(mode: .cascade, strategies: ['intents', 'semantics']),
      );
      await agent.startEpisode(_task, _descriptor);
      expect(agent.strategyTools.map((t) => t.name), isNot(contains('observe_tree')));

      agent.onResult(const Envelope(key: 'intents.invoke', kind: .act), EnvelopeResult.unsupported('intents.invoke'));
      expect(agent.strategyTools.map((t) => t.name), contains('observe_tree'));
    });

    test('warmPrefix primes the first call\'s system message and tools after the episode', () async {
      Future<FakeLlmClient> episode(AgentConfig config) async {
        final llm = FakeLlmClient(
          responses: [
            FakeLlmClient.calls([
              ('done', {'summary': 'ok'}),
            ]),
          ],
        );
        final agent = HybridAgent(client: llm, config: config);
        await agent.startEpisode(_task, _descriptor);
        await agent.next(null, _budget);
        await agent.next(EnvelopeResult.ok(), _budget);
        expect(llm.warmedPrefixes, isEmpty, reason: 'never on the episode\'s clock');
        await agent.endEpisode(const EpisodeOutcome(reason: .done));
        return llm;
      }

      final warmed = await episode(const AgentConfig(parallelToolCalls: false, warmPrefix: true));
      final first = warmed.requests.first;
      final prime = warmed.warmedPrefixes.single;
      expect(prime.messages.single.content, first.messages.first.content);
      expect([for (final tool in prime.tools) tool.name], [for (final tool in first.tools) tool.name]);

      expect((await episode(const AgentConfig(parallelToolCalls: false))).warmedPrefixes, isEmpty);
      expect(const AgentConfig().toJson(), isNot(contains('warmPrefix')), reason: 'earlier arms keep their hash');
    });

    test('a steering message enters the conversation after the pending tool result, as the user', () async {
      final llm = FakeLlmClient(
        responses: [
          FakeLlmClient.calls([
            ('ask_user', {'type': 'text', 'prompt': 'which one?'}),
          ]),
          FakeLlmClient.calls([
            ('done', {'summary': 'ok'}),
          ]),
        ],
      );
      final agent = HybridAgent(client: llm);
      await agent.startEpisode(_task, _descriptor);
      await agent.next(null, _budget);
      await agent.next(EnvelopeResult.ok(), _budget);
      agent.steer('Nimm lieber den zweiten.', id: 's1');
      await agent.next(EnvelopeResult.ok({'answer': 'x'}), _budget);
      final messages = llm.requests.last.messages;
      expect(messages[messages.length - 2].role, LlmRole.tool);
      expect(messages.last.role, LlmRole.user);
      expect(messages.last.content, '${ToolLoopAgent.steeringHeading}\nNimm lieber den zweiten.');
    });

    test('manifest carries the hashes the release gate compares', () {
      final agent = HybridAgent(client: FakeLlmClient());
      final metadata = agent.manifest.metadata;
      expect(metadata['promptHash'], isA<String>());
      expect(metadata['routerConfigHash'], isA<String>());
      expect(metadata['catalogSchemaVersion'], isA<String>());

      // Same config must hash the same, or the gate compares noise.
      expect(HybridAgent(client: FakeLlmClient()).manifest.metadata['routerConfigHash'], metadata['routerConfigHash']);
      // A different router must not.
      expect(
        HybridAgent(
          client: FakeLlmClient(),
          router: const RouterConfig(mode: .cascade),
        ).manifest.metadata['routerConfigHash'],
        isNot(metadata['routerConfigHash']),
      );
    });

    test('defaults to one tool call per turn', () {
      expect(HybridAgent(client: FakeLlmClient()).config.parallelToolCalls, isFalse);
    });
  });

  group('RouterConfig', () {
    test('parses the router block of an agent yaml', () {
      final config = RouterConfig.fromJson({
        'router': 'cascade',
        'strategies': ['intents', 'semantics'],
        'escalation': {
          'from': 'intents',
          'to': 'semantics',
          'on': ['failed'],
        },
      });
      expect(config.mode, RouterMode.cascade);
      expect(config.strategies, ['intents', 'semantics']);
      expect(config.escalateOn, ['failed']);
      expect(config.enables('genui'), isFalse);
    });

    test('the removed compact profile is refused, not ignored', () {
      expect(() => RouterConfig.fromJson(const {'profile': 'compact'}), throwsFormatException);
      expect(RouterConfig.fromJson(const {'profile': 'full'}).hash, const RouterConfig().hash);
    });

    test('an unknown config section is hashed into the manifest', () {
      final config = {
        'llm': {'provider': 'ollama'},
        'router': {'router': 'union'},
        'preparation': {'strategy': 'lexical', 'topK': 5},
      };
      final agent = HybridAgent(client: FakeLlmClient(), configBlocks: LlmClientFactory.otherSections(config));
      final blocks = asJsonMap(agent.manifest.metadata['configBlocks']);
      expect(blocks.keys, ['preparation']);
      expect(asJsonMap(blocks['preparation'])['hash'], configHash(config['preparation']));
      expect(HybridAgent(client: FakeLlmClient()).manifest.metadata, isNot(contains('configBlocks')), reason: 'v1 manifests stay as they were');
    });

    test('the v1 hash did not move when the profile went', () {
      expect(const RouterConfig().hash, 'af9b752d3fb7b940');
    });

    test('an empty block yields the documented defaults', () {
      final config = RouterConfig.fromJson(const {});
      expect(config.mode, RouterMode.union);
      expect(config.strategies, contains('intents'));
      expect(config.bootstrap, 'intents.catalog');
    });
  });
}
