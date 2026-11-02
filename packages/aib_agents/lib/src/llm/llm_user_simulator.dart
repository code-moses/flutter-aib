import 'package:aib_core/ports.dart';

import 'llm_client.dart';

/// The user as a pinned model, from a family other than the agent's and
/// the judge's.
///
/// Answers from the task's goal and persona, gives what
/// [UserSimulatorSpec.knows] lists verbatim, and checks every reply for
/// staying in role: not empty, not speaking as the assistant, not naming
/// ground truth it cannot know, and answering the question's type.
final class LlmUserSimulator implements UserSimulator {
  LlmUserSimulator({required this.client, this.temperature = 0});

  static const promptVersion = 'user_sim_v1';

  final LlmClient client;
  final double temperature;

  UserSimulatorSpec? _spec;
  final List<LlmMessage> _history = [];
  final List<JsonMap> _log = [];

  @override
  JsonMap describe() => {'model': client.model, 'promptVersion': promptVersion, 'temperature': temperature};

  @override
  bool get isActive => _spec != null;

  @override
  void beginEpisode(TaskSpec task) {
    _spec = task.userSimulator;
    _history.clear();
    _log.clear();
  }

  @override
  Future<Object?> answer(JsonMap question) async {
    final spec = _spec;
    if (spec == null) return null;
    final prompt = '${question['prompt'] ?? ''}';
    final type = '${question['type'] ?? 'text'}';
    final options = [for (final option in question['options'] as List? ?? const []) '$option'];

    for (final entry in spec.knows.entries) {
      if (entry.key == type || (entry.key.isNotEmpty && prompt.contains(entry.key))) {
        _record('answer', entry.value, question: prompt, source: 'knows');
        return entry.value;
      }
    }
    // A record to pick is an id, and no model knows one.
    if (type == 'pick') {
      _record('answer', null, question: prompt, issues: ['unknown_pick']);
      return null;
    }

    final hint = switch (type) {
      'confirm' => ' Begin with "ja" or "nein".',
      'choice' => ' Answer with exactly one of: ${options.join(' | ')}.',
      _ => '',
    };
    final text = await _say('The assistant asks you: $prompt$hint');
    _record(
      'answer',
      text,
      question: prompt,
      issues: _check(text, type: type, options: options),
    );
    return switch (type) {
      'confirm' => _confirmation(text),
      'choice' => _chosenOption(text, options) ?? text,
      _ => text,
    };
  }

  @override
  Future<String?> followUp(String? summary, {bool? goalMet}) async {
    if (_spec == null) return null;
    final text = await _say(
      'The assistant says it is done: "${summary ?? ''}". If your goal is '
      'fully met, reply exactly DONE. Otherwise write your next message to '
      'the assistant.',
    );
    final satisfied = text.toUpperCase().startsWith('DONE');
    _record(
      'followUp',
      text,
      question: summary,
      satisfied: satisfied,
      issues: satisfied ? [if (goalMet == false) 'premature_done'] : _check(text, type: 'text'),
    );
    return satisfied ? null : text;
  }

  @override
  List<JsonMap> drain() {
    final drained = List.of(_log);
    _log.clear();
    return drained;
  }

  Future<String> _say(String prompt) async {
    final response = await client.complete(
      LlmRequest(messages: [LlmMessage.system(_system(_spec!)), ..._history, LlmMessage.user(prompt)], temperature: temperature, maxTokens: 200),
    );
    final text = response.text.trim();
    _history
      ..add(LlmMessage.user(prompt))
      ..add(LlmMessage.assistant(text));
    return text;
  }

  static String _system(UserSimulatorSpec spec) => [
    'You are the user of a business app, talking to its assistant. You never '
        'operate the app and never act as the assistant. Reply in the '
        "assistant's language, in one or two short sentences.",
    if (spec.persona.isNotEmpty) 'Who you are: ${spec.persona}',
    'What you want: ${spec.goal}',
    if (spec.knows.isNotEmpty)
      'What you know: '
          '${spec.knows.entries.map((e) => '${e.key}: ${e.value}').join('; ')}',
    if (spec.mustNotAsk.isNotEmpty) 'Never ask for: ${spec.mustNotAsk.join(', ')}.',
    'If you are asked something you do not know, say so rather than invent it.',
  ].join('\n');

  List<String> _check(String text, {required String type, List<String> options = const []}) => [
    if (text.isEmpty) 'empty',
    if (_roleBreak.hasMatch(text)) 'role_break',
    for (final secret in _spec?.mustNotReveal ?? const <String>[])
      if (text.contains(secret)) 'revealed:$secret',
    for (final ruledOut in _spec?.mustNotAsk ?? const <String>[])
      if (text.toLowerCase().contains(ruledOut.toLowerCase())) 'contradicts_goal:$ruledOut',
    if (type == 'choice' && options.isNotEmpty && _chosenOption(text, options) == null) 'not_an_option',
    if (type == 'confirm' && _confirmation(text) == null) 'unparsable_confirm',
  ];

  static final _roleBreak = RegExp(
    r'as an AI|I am an AI|als KI|ich bin (eine? )?(KI|Assistent)|'
    r'intents?\.|meta\.(done|abort)',
    caseSensitive: false,
  );

  /// The option [text] names: the whole reply first, then the longest option
  /// that appears in it as a word of its own. A substring test answered
  /// "Jahr" to options [Ja, Nein], and picked "Kabel" out of "Patchkabel".
  static String? _chosenOption(String text, List<String> options) {
    final reply = text.trim().toLowerCase().replaceAll(RegExp(r'[.!]+$'), '');
    for (final option in options) {
      if (option.trim().toLowerCase() == reply) return option;
    }
    final byLength = [...options]..sort((a, b) => b.length.compareTo(a.length));
    for (final option in byLength) {
      final pattern = RegExp(
        '(^|[^\\p{L}\\p{N}])${RegExp.escape(option.toLowerCase())}'
        '(\$|[^\\p{L}\\p{N}])',
        unicode: true,
      );
      if (pattern.hasMatch(text.toLowerCase())) return option;
    }
    return null;
  }

  static bool? _confirmation(String text) {
    final lower = text.toLowerCase();
    if (RegExp(r'^(ja|yes|ok)\b').hasMatch(lower)) return true;
    if (RegExp(r'^(nein|no)\b').hasMatch(lower)) return false;
    return null;
  }

  void _record(String role, Object? text, {String? question, String? source, bool? satisfied, List<String> issues = const []}) => _log.add({
    'role': role,
    'question': ?question,
    'text': text,
    'source': ?source,
    'satisfied': ?satisfied,
    'valid': issues.isEmpty,
    'issues': issues,
  });
}
