/// GenAI semantic-convention names, in one place. The conventions are
/// experimental; [asOf] records when these were read, on every episode span.
abstract final class GenAi {
  static const asOf = '2026-09';

  static const operationName = 'gen_ai.operation.name';
  static const agentName = 'gen_ai.agent.name';
  static const requestModel = 'gen_ai.request.model';
  static const inputTokens = 'gen_ai.usage.input_tokens';
  static const outputTokens = 'gen_ai.usage.output_tokens';
  static const toolName = 'gen_ai.tool.name';

  static const invokeAgent = 'invoke_agent';
  static const executeTool = 'execute_tool';
}

/// The benchmark's own span names and attributes.
abstract final class Aib {
  static const episodeSpan = 'aib.episode';

  static const semconvAsOf = 'aib.semconv_as_of';
  static const runId = 'aib.run_id';
  static const episodeId = 'aib.episode_id';
  static const taskId = 'aib.task_id';
  static const environmentId = 'aib.environment_id';
  static const repetition = 'aib.repetition';
  static const envelopeKey = 'aib.envelope.key';
  static const envelopeKind = 'aib.envelope.kind';
  static const payloadBytes = 'aib.payload_bytes';
  static const payload = 'aib.payload';
  static const llmLatencyMs = 'aib.llm_latency_ms';
  static const status = 'aib.status';
  static const handleMs = 'aib.handle_ms';
  static const terminationReason = 'aib.termination_reason';
  static const wallClockMs = 'aib.wall_clock_ms';

  /// A decision span the episode ended before the agent made.
  static const unfinished = 'aib.unfinished';
}
