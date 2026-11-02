import 'dart:convert';

import 'package:aib_agents/aib_agents.dart';
import 'package:aib_agents/testing.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('embedding clients', () {
    test('ollama sends the batch and keeps its order', () async {
      late Map<String, dynamic> sent;
      final client = OllamaEmbeddingClient(
        model: 'nomic-embed-text',
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/embed');
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'model': 'nomic-embed-text',
              'embeddings': [
                [1, 0],
                [0, 1],
              ],
              'prompt_eval_count': 7,
            }),
            200,
          );
        }),
      );

      final response = await client.embed(['a', 'b']);

      expect(sent['input'], ['a', 'b']);
      expect(response.vectors, [
        [1.0, 0.0],
        [0.0, 1.0],
      ]);
      expect(response.promptTokens, 7);
    });

    test('openai orders vectors by index, not by arrival', () async {
      final client = OpenAiEmbeddingClient(
        model: 'text-embedding-3-small',
        apiKey: 'k',
        httpClient: MockClient((request) async {
          expect(request.url.path, '/v1/embeddings');
          expect(request.headers['authorization'], 'Bearer k');
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'index': 1,
                  'embedding': [0, 1],
                },
                {
                  'index': 0,
                  'embedding': [1, 0],
                },
              ],
              'usage': {'prompt_tokens': 3},
            }),
            200,
          );
        }),
      );

      final response = await client.embed(['first', 'second']);

      expect(response.vectors.first, [1.0, 0.0]);
      expect(response.promptTokens, 3);
    });

    test('a short answer is refused rather than misaligned', () async {
      final client = OllamaEmbeddingClient(
        model: 'nomic-embed-text',
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'embeddings': [
                [1, 0],
              ],
            }),
            200,
          ),
        ),
      );

      expect(client.embed(['a', 'b']), throwsA(isA<LlmClientException>().having((e) => e.kind, 'kind', LlmErrorKind.badRequest)));
    });

    test('the factory reads the embedding block', () {
      expect(
        LlmClientFactory.embeddingFromConfig({
          'llm': {'provider': 'ollama', 'model': 'qwen3:8b'},
          'embedding': {'provider': 'ollama', 'model': 'nomic-embed-text'},
        }),
        isA<OllamaEmbeddingClient>(),
      );
      expect(LlmClientFactory.embeddingFromConfig({'model': 'qwen3:8b'}), isNull);
      expect(
        LlmClientFactory.otherSections({
          'embedding': {'model': 'x'},
        }),
        isEmpty,
      );
    });

    test('the agent pins its embedding model', () async {
      final agent = IntentAgent(client: FakeLlmClient(), embeddingClient: FakeEmbeddingClient());

      expect(agent.manifest.metadata['embeddingModel'], 'fake-embedding');
      expect((await agent.modelIdentity())['embedding'], {'model': 'fake-embedding'});
    });
  });
}
