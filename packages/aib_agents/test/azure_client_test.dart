import 'package:aib_agents/agents.dart';
import 'package:test/test.dart';

void main() {
  group('AzureOpenAiClient', () {
    test('builds the deployment URL and the api-key header', () {
      final client = AzureOpenAiClient(
        deployment: 'sysco-prod',
        resourceUrl: 'https://sysco-eu.openai.azure.com',
        modelId: 'gpt-4o-2024-11-20',
        apiKey: 'secret',
      );
      expect(
        client.endpoint.toString(),
        'https://sysco-eu.openai.azure.com/openai/deployments/sysco-prod'
        '/chat/completions?api-version=${AzureOpenAiClient.defaultApiVersion}',
      );
      expect(client.headers['api-key'], 'secret');
      expect(client.headers.containsKey('authorization'), isFalse);
      // The deployment is what the endpoint is called; the model is what
      // decisions carry and prices look up.
      expect(client.model, 'gpt-4o-2024-11-20');
      expect(client.deployment, 'sysco-prod');
    });

    test('records the deployment next to the model it serves', () async {
      final client = AzureOpenAiClient(deployment: 'sysco-prod', resourceUrl: 'https://sysco-eu.openai.azure.com', modelId: 'gpt-4o-2024-11-20');
      expect(await client.modelIdentity(), {
        'provider': 'azure',
        'model': 'gpt-4o-2024-11-20',
        'deployment': 'sysco-prod',
        'apiVersion': AzureOpenAiClient.defaultApiVersion,
      });
    });
  });
}
