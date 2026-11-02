# ADR 0009 — Transport selection: in-process by default, stdio for foreign agents, WebSocket for remote environments; brokers rejected

Date: 2026-08-29 · Status: accepted

## Context

Spec §4.5 names `stdio` and `WebSocket` as the transports of the wire
protocol, but never argues *why* — and never says what is deliberately not
used. The supervisor asked whether the message exchange is state of the art
and whether a message broker (Kafka, RabbitMQ) would be the better carrier,
partly with an eye on OpenTelemetry integration.

The question is worth answering precisely because it conflates two concerns
that this framework keeps apart:

- **Transport** — how bytes move between two peers of one episode.
- **Event log** — what is durably recorded so the run can be measured,
  re-evaluated and audited later.

AIB already separates them. `EpisodeTrace` (ADR 0003) is an append-only
JSONL event log with a monotonic clock, and evaluation is a separate pass
over it. A broker would merge the two concerns back together: it would
become both the carrier and the log, and every property of the log would
then depend on the delivery semantics of the carrier.

Three facts about the exchange constrain the answer:

1. It is **strictly synchronous and 1:1**. `BenchmarkEngine.runEpisode`
   alternates `agent.next()` → `env.handle()` and awaits each call. There is
   at most one message in flight, exactly two peers, and the engine is the
   only clock source (spec §3.3).
2. The **default deployment is in-process**. stdio is not the normal path —
   it is the escape hatch used once, for the foreign-language VisionAgent
   (ADR 0007).
3. Every exchange is already recorded on the wire, by the engine, outside
   the agent's control (P4).

## Decision

The protocol stays transport-pluggable behind `AibTransport`, with exactly
three transports supported and one class explicitly rejected.

### Supported

| Transport | When | Status |
| --- | --- | --- |
| **in-process** (direct port calls) | default for every run: todo_app M2–M4, dynamate M5 | in use |
| **stdio** (`LineJsonTransport`, `SubprocessTransport`) | foreign-language agents; the M6 generalizability proof | in use (ADR 0007) |
| **in-memory pair** (`InMemoryTransportPair`) | conformance tests: identical verdicts in-process vs. over the wire | in use |
| **WebSocket** | environments on real devices/emulators, where a process boundary is unavoidable | planned, Phase 5+ |

### Rejected: message brokers (Kafka, RabbitMQ, NATS, MQTT) as the
### agent ↔ environment carrier

Four reasons, in order of weight:

1. **Delivery semantics break the measurement.** Brokers are at-least-once
   by default (`kreps2011kafka`, `vinoski2006amqp`). A duplicated or
   reordered envelope silently changes `action_count`,
   `redundant_action_ratio`, `retry_count` and every state-diff-derived
   metric. Exactly-once is reachable — transactional producers, offset
   management — but that machinery would itself have to be validated before
   any number measured through it could be trusted, which contradicts §10:
   the framework measures, so the framework must be validated, and the
   validation instrument (`ScriptedAgent` × `MockEnvironment`, M1) must stay
   small enough to be verifiable by inspection.
2. **Broker latency lands in `framework_overhead_ms`.** That metric exists
   to demonstrate that the framework does not dominate the measurement. A
   broker hop plus serialization plus partition assignment, on each of the
   ~25 exchanges of an episode, inflates precisely the number that is
   supposed to prove the framework unobtrusive.
3. **Reproducibility loses a guarantee.** §5.3 pins every source of variance
   except LLM output. Queue depth, consumer lag and rebalance timing are not
   capturable in the `RunManifest`, so a broker would introduce variance the
   manifest cannot describe.
4. **The evidence bar for agent harnesses is rising.**
   `zhang2026harnessdisclosure` and `yao2026harnessbench` show that the
   harness — context construction, tool interaction, orchestration,
   verification — accounts for up to 15 percentage points of variation on
   SWE-bench Verified with the model held fixed. The correct response is a
   simpler, fully disclosed harness, not a richer one.

A broker is the right answer to a problem AIB does not have: n:m
coordination between many long-lived, independently scaled agents. That is
the setting of the event-driven multi-agent patterns
(`adimulam2026orchestration`), of AutoGen v0.4's actor model and of
LangGraph's Pregel/BSP execution. AIB is 1:1, synchronous, single-episode.

### Alignment with the protocol landscape

None of the four agent protocols that converged in 2025–2026 specifies a
broker (`ehtesham2025protocolsurvey`):

| Protocol | Scope | Transports |
| --- | --- | --- |
| MCP `mcpSpec`, `mcpTransports` | client ↔ tool server, 1:1 | **stdio** and Streamable HTTP — exactly two, normative |
| A2A `a2aSpec` | peer agent ↔ peer agent | JSON-RPC 2.0 / HTTP+JSON / gRPC |
| ACP | agent ↔ agent | REST, multi-part, async streaming |
| AG-UI `aguiProtocol` | agent → frontend | typed event stream over SSE/WebSocket |

MCP is the closest analogue to the AIB agent/environment boundary — 1:1,
request/response, capability discovery by listing, which is exactly what
`EnvironmentDescriptor` models (spec §4.2) — and it names stdio as the
transport clients should support whenever possible. The MCP transport
working group's published direction for 2026 is a *more stateless*
protocol, not a more broker-like one.

No agent benchmark of record places a broker between agent and environment.
AndroidWorld (`rawles2024androidworld`) uses gRPC, but only because the
accessibility tree must cross a device boundary — the same reason WebSocket
is planned here for variant V3. OpenHands (`wang2025openhands`) uses an
in-process event stream and reports negligible event-sourcing overhead.
Inspect (`inspectAi`) and τ-bench (`yao2024taubench`) are in-process.

### Consequence for observability

Rejecting the broker does **not** reject OpenTelemetry. OTel needs a span
seam in the engine, not a carrier: the engine already produces every event a
`gen_ai.*` span tree needs. See
[`docs/overview.md`, Observability](../overview.md#observability).
`aib_core` must stay dependency-free, so any exporter lives in a separate
`aib_otel` package.

## Consequences

- The transport decision is now arguable in the thesis as a *finding*
  ("no agent benchmark of record uses a broker at this boundary; the
  protocols that converged specify stdio/HTTP") rather than defensible only
  as taste.
- If a future deployment genuinely needs n:m coordination — several agents
  against one environment, or a distributed environment fleet — this ADR is
  superseded rather than violated: `AibTransport` is the seam, and a broker
  transport would be an additional implementation of it. The determinism
  cost above would then have to be paid and documented.
- The rejection is falsifiable: if `framework_overhead_ms` were shown to be
  negligible *and* exactly-once delivery were validated by the conformance
  suite, reason 1 and 2 would fall. Reason 3 would remain.

## References

`ehtesham2025protocolsurvey` · `mcpSpec` · `mcpTransports` · `a2aSpec` ·
`aguiProtocol` · `kreps2011kafka` · `vinoski2006amqp` · `hohpe2003eip` ·
`bellifemine1999jade` · `fipaAcl` · `zhang2026harnessdisclosure` ·
`yao2026harnessbench` · `wang2025openhands` · `rawles2024androidworld` ·
`inspectAi` · `adimulam2026orchestration`

## Amendment 2026-09-17 — JSON-RPC 2.0, and the transport table corrected

The decision above is unchanged: in-process by default, a stream transport
for foreign agents, no broker. Two things were wrong in the record.

1. **The table omitted TCP.** `SocketTransport` has been in use since the
   ARTEMIS baseline (§P): a sandboxed macOS test build may open a socket but
   may not spawn a process, so the engine connects out to an agent that
   listens. Same line-delimited framing as stdio.
2. **The framing is now JSON-RPC 2.0** (protocol 2.0), the framing MCP uses
   and the one this ADR argues the field converged on. The custom
   `{aib, id, kind, method, payload}` envelope said the same things in its own
   words and had no place for errors that are not strings.

What the migration buys beyond conformity:

- **Capability negotiation.** `aib.handshake` carries the AIB version and the
  optional methods a peer serves (`env.stateFingerprint`,
  `env.sampleResources`, `agent.warmUp`, `agent.modelIdentity`). A remote
  environment therefore keeps its state-diff metrics, which protocol 1 could
  not carry at all — the conformance test asserted the loss.
- **Errors are typed.** Standard codes for parse, invalid request, method not
  found and internal errors; `-32001` version mismatch, `-32002` handshake
  rejected, `-32003` connection closed, `-32004` timeout.
- **A malformed line no longer kills the engine.** It is answered with a parse
  error and the connection keeps serving — one stray `print` in an agent used
  to raise an unhandled stream error. A dead peer fails its pending requests
  at once instead of hanging until the five-minute timeout.

Protocol 1 peers are refused with `invalid request` naming the version. Both
Python agents, the golden catalogue and the conformance suite moved with it.
