import 'template.dart';

/// Renders a branch's turns into the raw prompt a model reads, ending in the
/// open assistant turn plus the answer prefix — the position whose
/// next-token logits are the answer.
typedef JevPromptRenderer = String Function(List<JevTurn> turns, String answerPrefix);

/// The chat templates of the model families a decision model is run on, as
/// `apply_chat_template(…, add_generation_prompt=True, enable_thinking=False)`
/// renders them. For backends that take a raw prompt. `qwen35` is checked
/// character for character against Qwen3.5's Jinja template by
/// `test/golden_test.dart`.
///
/// No BOS token is written: llama.cpp and Ollama add it where the tokenizer
/// config asks for it.
enum JevChatFormat {
  /// Qwen3.5: ChatML, contents trimmed, an empty think block before the
  /// answer (thinking off).
  qwen35,

  /// Qwen3: ChatML with the empty think block, contents verbatim.
  qwen3,

  /// Plain ChatML (Qwen2.5, many fine-tunes).
  chatml,

  /// Llama 3.x headers.
  llama3,

  /// Gemma 2/3: no system role, the system text leads the first user turn.
  gemma;

  /// The renderer, as a function a backend can hold.
  JevPromptRenderer get renderer => render;

  String render(List<JevTurn> turns, String answerPrefix) => switch (this) {
    qwen35 => _chatml(turns, trim: true, think: true) + answerPrefix,
    qwen3 => _chatml(turns, trim: false, think: true) + answerPrefix,
    chatml => _chatml(turns, trim: false, think: false) + answerPrefix,
    llama3 => _llama3(turns) + answerPrefix,
    gemma => _gemma(turns) + answerPrefix,
  };

  /// The format a model id most likely needs, or null when the name does not
  /// say. Then the caller has to name one, or use a backend that applies the
  /// model's own template.
  static JevChatFormat? forModel(String model) {
    final name = model.toLowerCase();
    if (RegExp(r'qwen3[._-]?5').hasMatch(name)) return qwen35;
    if (name.contains('qwen3')) return qwen3;
    if (name.contains('qwen2') || name.contains('qwen1.5')) return chatml;
    if (RegExp(r'llama[-_ ]?3').hasMatch(name)) return llama3;
    if (name.contains('gemma')) return gemma;
    return null;
  }

  /// By config name; throws for an unknown one rather than falling back.
  static JevChatFormat byName(String name) => values.firstWhere(
    (format) => format.name == name,
    orElse: () => throw FormatException('unknown chat format "$name" (${values.map((f) => f.name).join(' | ')})'),
  );
}

String _chatml(List<JevTurn> turns, {required bool trim, required bool think}) {
  final out = StringBuffer();
  for (final (i, turn) in turns.indexed) {
    if (turn.role == 'system' && i > 0) {
      throw const JevUnsupported('a system turn must come first');
    }
    if (turn.role != 'system' && turn.role != 'user' && turn.role != 'assistant') {
      throw JevUnsupported('ChatML formats render system, user and assistant turns, not "${turn.role}"');
    }
    final content = trim ? turn.content.trim() : turn.content;
    out.write('<|im_start|>${turn.role}\n$content<|im_end|>\n');
  }
  out.write('<|im_start|>assistant\n');
  if (think) out.write('<think>\n\n</think>\n\n');
  return out.toString();
}

String _llama3(List<JevTurn> turns) {
  final out = StringBuffer();
  for (final turn in turns) {
    out.write('<|start_header_id|>${turn.role}<|end_header_id|>\n\n${turn.content.trim()}<|eot_id|>');
  }
  out.write('<|start_header_id|>assistant<|end_header_id|>\n\n');
  return out.toString();
}

String _gemma(List<JevTurn> turns) {
  final out = StringBuffer();
  var pending = '';
  for (final turn in turns) {
    if (turn.role == 'system') {
      pending = '${turn.content.trim()}\n\n';
      continue;
    }
    final role = turn.role == 'assistant' ? 'model' : turn.role;
    out.write('<start_of_turn>$role\n$pending${turn.content.trim()}<end_of_turn>\n');
    pending = '';
  }
  out.write('<start_of_turn>model\n');
  return out.toString();
}
