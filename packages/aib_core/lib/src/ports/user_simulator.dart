import '../common/json.dart';
import '../task/task.dart';

/// A model standing in for the user.
///
/// The engine calls [beginEpisode] and [followUp]; an environment's user bridge
/// calls [answer]. What was said, and whether it stayed in role, comes back
/// through [drain] and lands in the trace as `user.simulated`.
abstract interface class UserSimulator {
  /// Model, prompt version and sampling, for the run manifest.
  JsonMap describe();

  /// Whether the current episode's task declares a simulated user.
  bool get isActive;

  void beginEpisode(TaskSpec task);

  /// A reply to `user.ask` (`{type, prompt, options}`); null when there is
  /// none and the bridge should refuse.
  Future<Object?> answer(JsonMap question);

  /// The user's next message after the agent said [summary], or null when
  /// the user is satisfied. [goalMet] is whether the task's final state
  /// holds; null when the task declares none or the environment cannot say.
  Future<String?> followUp(String? summary, {bool? goalMet});

  /// Records since the last drain: `{role, text, valid, issues, …}`.
  List<JsonMap> drain();
}
