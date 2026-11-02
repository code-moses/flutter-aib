import 'dart:convert';

import 'package:aib_core/ports.dart';

import '../llm/llm_client.dart';

/// `agent.compaction`: old turns folded into one summary instead of being
/// stubbed by the observation window.
///
/// ```yaml
/// agent:
///   compaction:
///     after: 8          # compact once this many tool results are uncompacted
///     keep: 4           # the most recent results that stay in full
///     maxSummaryTokens: 400
/// ```
///
/// The trade against the window: the window forgets what an old result said
/// and keeps that it was called; a summary keeps what mattered and costs a
/// model call. Both rewrite the request once per stride, which is what keeps
/// the prefix cacheable in between — a summary is computed when a stride is
/// crossed and then re-sent unchanged.
final class CompactionConfig {
  const CompactionConfig({this.after = 8, this.keep = 4, this.maxSummaryTokens = 400, this.maxTranscriptChars = 24000});

  final int after;
  final int keep;
  final int maxSummaryTokens;

  /// How much of the span the summariser reads; the oldest part goes first.
  final int maxTranscriptChars;

  factory CompactionConfig.fromJson(JsonMap json) {
    const known = {'after', 'keep', 'maxSummaryTokens', 'maxTranscriptChars'};
    final unknown = json.keys.where((key) => !known.contains(key)).toList();
    if (unknown.isNotEmpty) throw FormatException('agent.compaction: unknown key(s) ${unknown.join(', ')}');
    final config = CompactionConfig(
      after: (json['after'] as num?)?.toInt() ?? 8,
      keep: (json['keep'] as num?)?.toInt() ?? 4,
      maxSummaryTokens: (json['maxSummaryTokens'] as num?)?.toInt() ?? 400,
      maxTranscriptChars: (json['maxTranscriptChars'] as num?)?.toInt() ?? 24000,
    );
    if (config.keep < 1 || config.after <= config.keep) {
      throw FormatException('agent.compaction needs keep >= 1 and after > keep, got after ${config.after}, keep ${config.keep}');
    }
    return config;
  }

  JsonMap toJson() => {'after': after, 'keep': keep, 'maxSummaryTokens': maxSummaryTokens, 'maxTranscriptChars': maxTranscriptChars};
}

/// One episode's compaction state: where the compacted span ends and what it
/// was summarised to.
final class Compactor {
  Compactor(this.config);

  final CompactionConfig config;

  /// [LlmMessage]s before this index of the conversation are replaced by
  /// [summary] (after the opening messages, which always stay).
  int _compactedUpTo = 0;
  String? _summary;

  /// Turns compacted so far, for the decision note.
  var compactedTurns = 0;

  void reset() {
    _compactedUpTo = 0;
    _summary = null;
    compactedTurns = 0;
  }

  static const heading =
      '[benchmark runner, not the user] Your earlier turns were compacted to '
      'save context. Summary of what you did and found:';

  static const _instructions =
      'You compress the working history of an agent that operates an app '
      'through tools, so it can continue without the full history. Write a '
      'short summary for the agent itself: what it has done, what it found, '
      'and every concrete value it may still need — ids, names, numbers, '
      'routes, field names, error messages — copied exactly. No advice, no '
      'plan, no preamble.';

  /// The conversation as the next request sends it, compacting first when a
  /// stride was crossed. [summarise] makes the model call; when it fails, the
  /// conversation is returned as it is and the caller's window applies.
  ///
  /// [pinned] results are never summarised away: under the fixed tool surface
  /// a describe result is the only place a schema is written down, so it is
  /// kept verbatim after the summary.
  Future<List<LlmMessage>?> apply(
    List<LlmMessage> messages, {
    required Set<LlmMessage> pinned,
    required Future<String> Function(LlmRequest request) summarise,
  }) async {
    final opening = messages.indexWhere((m) => m.role == .assistant);
    if (opening < 0) return null;
    final from = _compactedUpTo > opening ? _compactedUpTo : opening;
    final fresh = [
      for (var i = from; i < messages.length; i++)
        if (messages[i].role == .tool) i,
    ];
    if (fresh.length > config.after) {
      final cutoff = _cutoff(messages, from);
      if (cutoff != null) {
        final span = messages.sublist(from, cutoff);
        final summary = await summarise(
          LlmRequest(messages: [LlmMessage.system(_instructions), LlmMessage.user(_transcript(_summary, span))], maxTokens: config.maxSummaryTokens),
        );
        _summary = summary.trim();
        _compactedUpTo = cutoff;
        compactedTurns += span.where((m) => m.role == .assistant).length;
      }
    }
    final summary = _summary;
    if (summary == null) return null;
    final kept = [
      for (var i = opening; i < _compactedUpTo; i++)
        if (pinned.contains(messages[i])) messages[i],
    ];
    return [
      ...messages.sublist(0, opening),
      LlmMessage.user(
        [heading, summary, for (final message in kept) '\nKept in full, result of ${message.toolName ?? 'a tool'}:\n${message.content}'].join('\n'),
      ),
      ...messages.sublist(_compactedUpTo),
    ];
  }

  /// The latest turn start (an assistant message) after which at least
  /// [CompactionConfig.keep] tool results remain, or null when no turn
  /// boundary leaves that many. A cut anywhere else would separate a tool call
  /// from its result, which every provider refuses.
  int? _cutoff(List<LlmMessage> messages, int from) {
    int? cutoff;
    for (var i = from + 1; i < messages.length; i++) {
      if (messages[i].role != .assistant) continue;
      final after = messages.skip(i).where((m) => m.role == .tool).length;
      if (after >= config.keep) cutoff = i;
    }
    return cutoff;
  }

  String _transcript(String? previous, List<LlmMessage> span) {
    final lines = <String>[
      if (previous != null) ...['Summary so far:', previous, ''],
      'Turns to add:',
      for (final message in span)
        switch (message.role) {
          .assistant => [
            if (message.content.trim().isNotEmpty) 'agent: ${message.content.trim()}',
            for (final call in message.toolCalls) 'agent called ${call.name} ${jsonEncode(call.arguments)}',
          ].join('\n'),
          .tool => 'result of ${message.toolName ?? 'tool'}: ${message.content}',
          .user => 'note: ${message.content}',
          .system => '',
        },
    ];
    final text = lines.join('\n');
    return text.length <= config.maxTranscriptChars ? text : '…${text.substring(text.length - config.maxTranscriptChars)}';
  }
}
