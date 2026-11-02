import 'package:aib_core/ports.dart';

/// The envelope vocabulary of the intent and user bridges (`aib_flutter`'s
/// `IntentBridge` and `UserBridge`), which the strategies in this package
/// speak. Named once here because the core must not name it (ADR 0002).
abstract final class IntentConventions {
  static const catalogKey = 'intents.catalog';
  static const describeKey = 'intents.describe';
  static const invokeKey = 'intents.invoke';
  static const userAskKey = 'user.ask';
  static const userKeyPrefix = 'user.';

  /// Result field carrying `{added, removed}` when the in-scope intents moved
  /// (ADR 0013).
  static const capabilitiesKey = 'capabilities';

  /// Error code of a question the scripted user has no answer for.
  static const noScriptedAnswer = 'no_scripted_answer';

  /// The intent an envelope of [key] with [payload] calls, or null.
  static String? intentOf(String key, JsonMap payload) => key == invokeKey ? payload['intent'] as String? : null;

  /// An envelope named by its intent where it has one:
  /// `intents.invoke:data.count` rather than `intents.invoke`.
  static String label(String key, JsonMap payload) {
    final intent = intentOf(key, payload);
    return intent == null ? key : '$invokeKey:$intent';
  }
}
