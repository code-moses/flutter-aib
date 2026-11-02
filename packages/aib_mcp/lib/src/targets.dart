import 'package:aib_agents/aib_agents.dart';
import 'package:aib_core/aib_core.dart';

import 'config.dart';

/// One model an agent config talks to.
typedef ModelTarget = ({String provider, String model, String? baseUrl});

/// Every model a config reaches: the agent's `llm:`, both sides of a
/// `modelRouter:`, its decider, the `decisions:` client and `embedding:`.
/// Read the way [LlmClientFactory] builds them, not by searching the YAML.
List<ModelTarget> modelTargets(JsonMap config) {
  final targets = <ModelTarget>[];
  void llm(JsonMap block) {
    final model = (block['model'] ?? block['deployment'] ?? block['modelId']) as String?;
    if (model == null) return;
    targets.add((
      provider: block['provider'] as String? ?? 'anthropic',
      model: model,
      baseUrl: (block['baseUrl'] ?? block['resourceUrl']) as String?,
    ));
  }

  void jev(JsonMap block) {
    if (block.isEmpty) return;
    final backend = block['backend'] as String?;
    targets.add((
      provider: backend == null ? 'jev' : 'jev-$backend',
      model: '${block['model'] ?? 'default'}',
      baseUrl: block['baseUrl'] as String? ?? (backend == 'ollama' ? defaultOllama : null),
    ));
  }

  final router = asJsonMap(config['modelRouter']);
  if (router.isEmpty) {
    llm(LlmClientFactory.llmSection(config));
  } else {
    llm(asJsonMap(router['local']));
    llm(asJsonMap(router['cloud']));
    if (router['decider'] == 'jev') jev(asJsonMap(router['jev']));
  }
  final embedding = asJsonMap(config['embedding']);
  if (embedding.isNotEmpty) llm({'provider': 'openai', ...embedding});
  jev(asJsonMap(asJsonMap(config['decisions'])['client']));
  return targets;
}

const defaultOllama = 'http://localhost:11434';

/// Runs on this machine's GPU: Ollama models and local jev backends.
bool isLocal(ModelTarget target) =>
    target.provider == 'ollama' || target.provider == 'jev-ollama' || target.provider == 'jev-llama-server' || _isLoopback(target.baseUrl);

bool _isLoopback(String? url) {
  final host = url == null ? null : Uri.tryParse(url)?.host;
  return host == 'localhost' || host == '127.0.0.1' || host == '::1';
}

/// Models that cost money: remote, and not marked `nominal` in [prices].
/// A remote model the table does not know is paid — its price is unknown,
/// not zero.
List<ModelTarget> paidTargets(List<ModelTarget> targets, PriceTable prices) => [
  for (final target in targets)
    if (!isLocal(target) && !prices.isNominal(target.model)) target,
];

/// The configured hosts [targets] run on. A local URL no host names gets a
/// host of its own with concurrency 1: two runs never share a GPU unasked.
Set<String> hostsOf(List<ModelTarget> targets, Map<String, HostLimit> hosts) => {
  for (final target in targets)
    if (isLocal(target))
      hosts.values.where((h) => sameHost(h.url, target.baseUrl ?? defaultOllama)).firstOrNull?.name ?? _normalize(target.baseUrl ?? defaultOllama),
};

bool sameHost(String a, String b) => _normalize(a) == _normalize(b);

String _normalize(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  final host = uri.host == '127.0.0.1' || uri.host == '::1' ? 'localhost' : uri.host;
  return '$host:${uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80)}';
}
