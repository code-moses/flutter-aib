import 'dart:convert';
import 'dart:io';

import 'package:aib_agents/aib_agents.dart';
import 'package:aib_core/aib_core.dart';
import 'package:aib_core/testing.dart';
import 'package:yaml/yaml.dart';

/// Built-in agent and environment factories (P7: everything is registered,
/// nothing is hard-wired into the engine).
///
/// Agent spec syntax on the command line: `name` or `name=configFile`, e.g.
/// `--agents scripted=scripts/todo_scripted.yaml`. The FlutterEnvironment is
/// not here: it lives inside the app process and is driven via the widget-test
/// harness (ADR 0004).
final class Builtins {
  /// Metric providers `--metrics` can name; contributions register here.
  static Registry<MetricProvider> metricProviders() => Registry<MetricProvider>()
    ..register('intents', (_) => intentConventions)
    ..register('consistency', (_) => consistencyMetrics)
    ..register('calibration', (_) => calibrationMetrics)
    ..register('prefetch', (_) => prefetchMetrics)
    ..register('routing', (_) => routingMetrics)
    ..register('decisions', (_) => decisionMetrics);

  static Registry<BenchmarkAgent> agentRegistry() {
    final registry = Registry<BenchmarkAgent>();
    registry.register('scripted', (config) => ScriptedAgent.fromJson(config));
    // LLM reference agents; config = an agent YAML (see suites/agents/*.yaml).
    // Built through [AgentProfile], the same builder an app uses.
    for (final name in AgentProfile.agents) {
      registry.register(
        name,
        (config) => AgentProfile.build(
          name,
          config,
          client: LlmClientFactory.fromConfig(config),
          embeddingClient: LlmClientFactory.embeddingFromConfig(config),
          decisions: LlmClientFactory.decisionsFromConfig(config),
        ),
      );
    }
    return registry;
  }

  static Registry<BenchmarkEnvironment> environmentRegistry() {
    final registry = Registry<BenchmarkEnvironment>();
    registry.register('mock', (config) => MockEnvironment());
    return registry;
  }

  /// Loads a YAML/JSON config file into a JsonMap ({} if [path] is null).
  static JsonMap loadConfig(String? path) {
    if (path == null) return const {};
    final content = File(path).readAsStringSync();
    return asJsonMap(jsonDecode(jsonEncode(loadYaml(content))));
  }

  /// Parses `name` / `name=configFile` specs.
  static (String name, String? configPath) parseSpec(String spec) {
    final index = spec.indexOf('=');
    if (index < 0) return (spec, null);
    return (spec.substring(0, index), spec.substring(index + 1));
  }
}
