import 'package:aib_core/ports.dart';

import 'agent_config.dart';

/// How the hybrid agent combines its strategies.
enum RouterMode {
  /// Offer every enabled strategy's tools at once and let the model choose. The
  /// default: it mirrors the winning hybrid of `song2025apiagents` on WebArena
  /// and keeps the loop skeleton identical to the single-strategy agents.
  union,

  /// Start with one strategy and fall back to the next when the environment
  /// says the first cannot do it.
  ///
  /// Escalating adds the next strategy's tools mid-episode, and a runtime that
  /// renders tools at the top of the prompt (Ollama) then prefills the whole
  /// conversation once more. Inherent to the mode; say so when reporting
  /// cascade latency (`tool_surface_changes` counts it).
  cascade,
}

/// The hybrid agent's configuration, from the `router:` block of an agent YAML
/// and hashed into the run manifest.
final class RouterConfig {
  const RouterConfig({
    this.mode = .union,
    this.strategies = const ['intents', 'genui', 'user', 'semantics'],
    this.bootstrap = 'intents.catalog',
    this.escalateFrom = 'intents',
    this.escalateTo = 'semantics',
    this.escalateOn = const ['unsupported', 'failed'],
  });

  final RouterMode mode;

  /// Enabled strategies, in the order their tools are offered. Order is not
  /// cosmetic: models weight earlier tools more heavily, so it is part of
  /// the configuration rather than an implementation detail.
  final List<String> strategies;

  /// Envelope key of the deterministic first observation.
  final String bootstrap;

  // cascade only
  final String escalateFrom;
  final String escalateTo;

  /// Result statuses that trigger an escalation.
  final List<String> escalateOn;

  bool enables(String strategy) => strategies.contains(strategy);

  factory RouterConfig.fromJson(JsonMap json) {
    // `compact` was removed; fail rather than silently run `full`.
    final profile = json['profile'];
    if (profile != null && profile != 'full') {
      throw FormatException('router profile "$profile" no longer exists');
    }
    final escalation = asJsonMap(json['escalation']);
    return RouterConfig(
      mode: switch (json['router']) {
        'cascade' => RouterMode.cascade,
        _ => RouterMode.union,
      },
      strategies: [for (final s in json['strategies'] as List? ?? const []) '$s'].isEmpty
          ? const ['intents', 'genui', 'user', 'semantics']
          : [for (final s in json['strategies'] as List) '$s'],
      bootstrap: json['bootstrap'] as String? ?? 'intents.catalog',
      escalateFrom: escalation['from'] as String? ?? 'intents',
      escalateTo: escalation['to'] as String? ?? 'semantics',
      escalateOn: [for (final s in escalation['on'] as List? ?? const []) '$s'].isEmpty
          ? const ['unsupported', 'failed']
          : [for (final s in escalation['on'] as List) '$s'],
    );
  }

  JsonMap toJson() => {
    'router': mode.name,
    'strategies': strategies,
    'bootstrap': bootstrap,
    if (mode == .cascade) 'escalation': {'from': escalateFrom, 'to': escalateTo, 'on': escalateOn},
    // Keeps the v1 hash stable.
    'profile': 'full',
  };

  String get hash => configHash(toJson());
}
