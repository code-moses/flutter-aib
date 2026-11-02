import 'dart:convert';

import 'package:aib_core/ports.dart';

import 'llm_client.dart';

/// Tool calling as constrained decoding (`agent.toolCalling: constrained`, ADR
/// 0015): the model completes a JSON document the decoder only lets it write
/// one way.
///
/// A local runtime turns model text into `tool_calls` with a parser, and
/// whatever the parser cannot read comes back as an empty turn. Under a grammar
/// each of those failures is unrepresentable: the tool name is one of the
/// offered names, and the arguments satisfy that tool's schema.
///
/// The tool list still goes to the provider as `tools`. The schema constrains
/// what is written, not what the model is told.
abstract final class ConstrainedToolCalls {
  /// One JSON object per turn: `{"tool": <name>, "arguments": {...}}`.
  ///
  /// `tool` comes first, so the arguments are decoded knowing which tool they
  /// belong to. `done` and `abort` are among the tools, which is how a
  /// constrained turn ends the episode: prose is not a valid completion.
  static JsonMap schemaFor(List<LlmTool> tools) => {
    'anyOf': [
      for (final tool in tools)
        {
          'type': 'object',
          'properties': {
            'tool': {'const': tool.name},
            'arguments': tool.parameters,
          },
          'required': ['tool', 'arguments'],
          'additionalProperties': false,
        },
    ],
  };

  /// [response] with the constrained JSON in its text read as the tool call it
  /// is.
  ///
  /// A response that already carries native `toolCalls` is returned as is. One
  /// whose text is not the expected document — a completion cut off by
  /// `num_predict` — is returned as is too, so the loop nudges it like any
  /// other turn with no usable call; the trace keeps its `stopReason`. A decoded
  /// call empties the text: the JSON *was* the call, and leaving it in the
  /// assistant message would put the call in the history twice.
  static LlmResponse decode(LlmResponse response) {
    if (response.toolCalls.isNotEmpty) return response;
    final text = response.text.trim();
    if (!text.startsWith('{')) return response;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return response;
    }
    if (decoded is! Map || decoded['tool'] is! String) return response;
    final arguments = decoded['arguments'];
    return response.copyWith(
      text: '',
      toolCalls: [LlmToolCall(id: 'call_0', name: decoded['tool'] as String, arguments: arguments is Map ? asJsonMap(arguments) : const {})],
    );
  }
}
