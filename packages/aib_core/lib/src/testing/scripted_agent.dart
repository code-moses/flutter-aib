import '../common/json.dart';
import '../ports/agent.dart';
import '../ports/envelope.dart';
import '../ports/environment.dart';
import '../task/task.dart';

/// Deterministic agent with predefined envelope sequences per task (spec §10):
/// the reference instrument for validating engine, metrics and evaluator, and
/// for driving real environments without an LLM.
final class ScriptedAgent implements BenchmarkAgent {
  ScriptedAgent({String agentId = 'scripted', String version = '1.0.0', this.scripts = const {}, this.defaultScript = const [], this.doneSummary})
    : manifest = AgentManifest(agentId: agentId, version: version, description: 'Deterministic scripted agent (framework validation)');

  @override
  final AgentManifest manifest;

  /// taskId -> envelope sequence. Falls back to [defaultScript].
  final Map<String, List<Envelope>> scripts;
  final List<Envelope> defaultScript;
  final String? doneSummary;

  List<Envelope> _current = const [];
  int _index = 0;

  /// Results received during the episode — inspectable by tests.
  final List<EnvelopeResult> receivedResults = [];
  EpisodeOutcome? lastOutcome;

  @override
  Future<void> startEpisode(TaskSpec task, EnvironmentDescriptor environment) async {
    _current = scripts[task.id] ?? defaultScript;
    _index = 0;
    receivedResults.clear();
  }

  @override
  Future<Envelope> next(EnvelopeResult? lastResult, BudgetStatus budget) async {
    if (lastResult != null) receivedResults.add(lastResult);
    if (_index < _current.length) {
      return _current[_index++];
    }
    return Envelope.done(summary: doneSummary);
  }

  @override
  Future<void> endEpisode(EpisodeOutcome outcome) async {
    lastOutcome = outcome;
  }

  /// CLI config format:
  /// ```yaml
  /// agentId: scripted-demo
  /// scripts:
  ///   task.id:
  ///     - {key: state.insert, kind: act, payload: {...}, decision: {...}}
  /// defaultScript: [...]
  /// ```
  factory ScriptedAgent.fromJson(JsonMap json) {
    List<Envelope> parseScript(Object? raw) => [for (final step in raw as List? ?? const []) Envelope.fromJson(asJsonMap(step))];
    return ScriptedAgent(
      agentId: json['agentId'] as String? ?? 'scripted',
      scripts: asJsonMap(json['scripts']).map((taskId, steps) => MapEntry(taskId, parseScript(steps))),
      defaultScript: parseScript(json['defaultScript']),
      doneSummary: json['doneSummary'] as String?,
    );
  }
}
