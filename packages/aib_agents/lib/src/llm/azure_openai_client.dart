import 'package:aib_core/ports.dart';

import 'llm_client.dart';
import 'openai_client.dart';

/// Azure OpenAI adapter. The wire format is OpenAI's; three things differ: the
/// URL shape (`/openai/deployments/{deployment}/...` with a mandatory
/// `api-version`), the auth header (`api-key`, not `Bearer`), and that the
/// deployment is a name chosen by whoever created the resource. [modelId] says
/// which model it actually is, for pricing and the manifest.
final class AzureOpenAiClient extends OpenAiClient implements LlmModelIdentity {
  /// [model] — what every decision, price lookup and manifest reads — is the
  /// [modelId]; the deployment only addresses the endpoint.
  AzureOpenAiClient({
    required this.deployment,
    required this.resourceUrl,
    this.apiVersion = defaultApiVersion,
    String? modelId,
    super.apiKey,
    super.retryPolicy,
    super.httpClient,
  }) : modelId = modelId ?? deployment,
       super(model: modelId ?? deployment, baseUrl: resourceUrl);

  /// Azure retires API versions on a published schedule; pinning it means a
  /// rerun a year from now still sends what the original run sent.
  static const defaultApiVersion = '2024-10-21';

  /// The deployment name — what the endpoint is addressed by.
  final String deployment;

  /// e.g. `https://my-resource.openai.azure.com`.
  final String resourceUrl;

  final String apiVersion;

  /// The underlying model (`gpt-4o-2024-11-20`), used for pricing and for
  /// comparing a run against the same model on another provider.
  final String modelId;

  @override
  Uri get endpoint => Uri.parse(
    '$resourceUrl/openai/deployments/$deployment/chat/completions'
    '?api-version=$apiVersion',
  );

  /// The deployment is recorded next to the model it serves.
  @override
  Future<JsonMap> modelIdentity() async => {'provider': 'azure', 'model': modelId, 'deployment': deployment, 'apiVersion': apiVersion};

  @override
  Map<String, String> get headers => {'content-type': 'application/json', 'api-key': apiKey};
}
