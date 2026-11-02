# AIB Framework — Architecture Diagrams

Status and results are in [`overview.md`](overview.md); the reasons behind
each shape are in the ADRs.

## 1. System overview — layers and packages

Hexagonal architecture (P1): every dependency points inward to the core; the
core knows neither Flutter nor LLMs nor concrete interaction patterns.

```mermaid
graph TB
    subgraph L4["Layer 4 — Tooling"]
        CLI["aib_cli<br/>validate · run (resumable) · evaluate · report<br/>compare · route · calibrate · labelsheet · selftest · doctor"]
        SVC["AibService<br/>typed results, shared by both front ends"]
        MCP["aib_mcp<br/>the CLI over MCP (stdio · Streamable HTTP)<br/>jobs · host queue · budget · splits · study journal"]
    end

    subgraph L3["Layer 3 — Adapters (exchangeable, technology-specific)"]
        subgraph AG["aib_agents — reference agents"]
            TLA["ToolLoopAgent (shared skeleton)"]
            SA["SemanticsAgent"]
            IA["IntentAgent"]
            GA["GenUiAgent"]
            HA["HybridAgent · PreparingAgent"]
            MRT["ModelRouter<br/>local · cloud · rules · self · jev"]
            LLMC["LlmClient port<br/>Anthropic · OpenAI · Azure · Ollama"]
            LJ["LlmJudge"]
        end
        subgraph JEV["decision models"]
            JC["aib_jev<br/>JevClient · v1 template · backends"]
            JL["aib_jev_llama<br/>llama.cpp in process"]
        end
        OT["aib_otel<br/>OpenTelemetry spans"]
        subgraph FL["aib_flutter — environment adapter"]
            FE["FlutterEnvironment"]
            SB["SemanticsBridge<br/>semantics.tree/tap/setText/scroll"]
            IB["IntentBridge<br/>intents.catalog/invoke"]
            GB["GenUiBridge<br/>data.context · genui.catalog · genui.render"]
            VB["UserBridge · VisionBridge<br/>user.ask · screen.capture · pointer.*"]
        end
    end

    subgraph L2["Layer 2 — Protocol"]
        PROT["aib_protocol<br/>JSON-RPC 2.0 frames · handshake<br/>stdio · TCP · in-memory transports<br/>RemoteAgent · RemoteEnvironment"]
    end

    subgraph L1["Layer 1 — Core (pure Dart, no Flutter/LLM deps)"]
        CORE["aib_core<br/>TaskModel · BenchmarkEngine · EpisodeTrace<br/>Metrics · Evaluation · Aggregation · Reporting<br/>+ MockEnvironment / ScriptedAgent (testing)"]
    end

    subgraph APPS["Apps under test"]
        TODO["todo_app<br/>(controlled conditions,<br/>good/bad semantics)"]
        SYSCO["dynamate / SYSco Mobile+<br/>(real business app,<br/>demo-mode instrumentation)"]
    end

    SUITES[("suites/*.yaml<br/>tasks · fixtures · rubrics")]

    CLI --> SVC
    MCP --> SVC
    SVC --> CORE
    SVC --> AG
    SA & IA & GA & HA --> TLA
    TLA --> LLMC
    TLA --> MRT
    MRT --> LLMC
    MRT --> JC
    AG --> JC
    JL --> JC
    OT --> CORE
    LJ --> LLMC
    AG -->|"BenchmarkAgent port"| CORE
    FL -->|"BenchmarkEnvironment port"| CORE
    PROT --> CORE
    SB & IB & GB & VB --> FE
    TODO --> FL
    SYSCO --> FL
    SUITES -.->|"SuiteLoader"| CORE
```

## 2. aib_core — detailed component view

The core owns no vocabulary (ADR 0002): agents and environments exchange
opaque envelopes; only `meta.*` is reserved. Execution and evaluation are
separate passes over persisted traces (P6, ADR 0003).

```mermaid
graph LR
    subgraph PORTS["ports/"]
        ENV1["Envelope<br/>key · kind(observe|act) · payload · decision"]
        BA["BenchmarkAgent<br/>startEpisode · next · endEpisode"]
        BE["BenchmarkEnvironment<br/>describe · reset · handle · captureFinalState"]
        SFP["StateFingerprintProvider<br/>(optional capability)"]
    end

    subgraph TASK["task/"]
        TS["TaskSpec · Budget · GroundTruth<br/>(finalState · milestones)<br/>SuccessCriterion · PartialCreditRule"]
        SL["SuiteLoader<br/>YAML -> validated suite,<br/>fixtures + rubrics inlined"]
    end

    subgraph ENGINE["engine/"]
        BEng["BenchmarkEngine<br/>episode loop · budgets · timeouts"]
        RUN["BenchmarkRunner<br/>suite × agents × reps, seeded shuffle"]
        RM["RunManifest / RunStore"]
    end

    subgraph TRACE["trace/"]
        ET["EpisodeTrace (JSONL)<br/>envelope/result/fingerprint events<br/>+ state.probe (milestone timeline)"]
    end

    subgraph EVAL["evaluation/"]
        EE["EpisodeEvaluator -> Verdict"]
        FSM["finalStateMatch"]
        SS["stateSequence<br/>(essential states)"]
        TA["traceAssertion"]
        AR["artifactRubric<br/>(k majority, default 3)"]
        AJ["ArtifactJudge port"]
    end

    subgraph METRICS["metrics/"]
        MR["MetricsRegistry<br/>effectiveness · efficiency · resources<br/>termination quality · recovery (§6.4)<br/>cost_usd via pinned PriceTable<br/>+ providers (intents, prefetch, …)"]
    end

    subgraph AGGR["aggregation/ + reporting/"]
        AGG["Aggregator<br/>median · p95 · pass^k<br/>Wilson CI per task, clustered across"]
        CMP["RunComparator<br/>bootstrap Δ-CIs"]
        REP["Reporters: csv · json · md · html"]
    end

    SL --> TS
    TS --> BEng
    BA & BE --> BEng
    BEng -->|"records every exchange"| ET
    RUN --> BEng
    RUN --> RM
    ET --> EE
    ET --> MR
    EE --> FSM & SS & TA & AR
    AR --> AJ
    EE & MR --> AGG
    AGG --> REP
    AGG --> CMP
```

## 3. Episode control flow — mediated exchange

The engine is the single clock source (spec §3.3): agent and environment
never talk directly; every exchange flows through the engine and lands in
the trace — measurement happens on the wire (P4).

```mermaid
sequenceDiagram
    participant E as BenchmarkEngine
    participant A as Agent (port)
    participant V as Environment (port)
    participant T as EpisodeTrace

    E->>V: reset(fixture)
    V-->>E: ready
    E->>T: env.reset + state.fingerprint + state.probe
    E->>V: describe()
    V-->>E: EnvironmentDescriptor (key discovery)
    E->>A: startEpisode(task, descriptor)

    loop until meta.done / meta.abort / budget / timeout
        E->>A: next(lastResult, budgetStatus)
        A-->>E: Envelope {key, kind, payload, decision}
        E->>T: agent.envelope (payload bytes, telemetry)
        alt meta.done / meta.abort
            Note over E: terminate episode
        else regular envelope
            E->>V: handle(envelope)
            V-->>E: EnvelopeResult {ok | unsupported | failed}
            E->>T: env.result (+ handleMs)
            E->>T: state.fingerprint (if supported)
            opt task declares groundTruth.milestones
                Note over E,V: wall clock paused — probing is
                E->>V: captureFinalState(milestoneQueries)
                V-->>E: FinalStateSnapshot
                E->>T: state.probe (+ probeMs)
                Note over E,V: instrumentation, not agent behaviour
            end
        end
    end

    E->>V: captureFinalState(groundTruth queries)
    V-->>E: FinalStateSnapshot
    E->>T: final.state + episode.end (wallClockMs)
    E->>A: endEpisode(outcome)
```

## 4. Run pipeline — trace-first artifacts (ADR 0003)

`aib run` produces raw traces only; verdicts, metrics and reports are a
separate, repeatable pass — new metrics apply to old runs.

```mermaid
flowchart LR
    SUITE["suite YAML<br/>+ fixtures + rubrics"] --> RUNC

    subgraph RUNC["aib run (resumable)"]
        RUNNER["BenchmarkRunner<br/>seeded task shuffle, n repetitions<br/>reuses complete episodes;<br/>repeats framework faults (§5.2)"]
    end

    RUNC --> MAN["run_manifest.json<br/>(suite hash, agents, models, seed,<br/>platform, price table, resumes)"]
    RUNC --> TR["traces/*.jsonl<br/>(one event per line)"]

    TR --> EVALC
    SUITE --> EVALC
    subgraph EVALC["aib evaluate (repeatable)"]
        RE["RunEvaluation"]
        EE2["EpisodeEvaluator<br/>finalStateMatch · stateSequence ·<br/>traceAssertion · artifactRubric (--judge)"]
        MET["MetricsRegistry"]
        RE --> EE2 & MET
    end

    EVALC --> VD["verdicts.json<br/>{judge: id · k · pin · rubric hashes,<br/>verdicts: …}"]
    EVALC --> MC["metrics.csv (long format)"]

    VD & MC --> REPC["aib report<br/>report.md · report.html ·<br/>report.json"]
    VD & MC --> CMPC["aib compare<br/>comparison.md<br/>(bootstrap Δ-CIs)"]
    VD --> CALC["aib calibrate<br/>calibration.md/.json<br/>(κ · F1 · confusion ·<br/>judge split rate)"]
    VD --> LSH["aib labelsheet<br/>seeded sample of judged criteria"]
    LSH --> LAB[("manual labels<br/>episode,criterion,label")]
    LAB --> CALC
    VD & MC --> ROUTE["aib route<br/>routed arms vs the per-task oracle<br/>of an always-local and an always-cloud run"]
```

## 5. Core ports — class diagram

```mermaid
classDiagram
    direction LR

    class Envelope {
        +String key
        +EnvelopeKind kind
        +JsonMap payload
        +AgentDecision? decision
        +isMeta / isDone / isAbort
    }
    class EnvelopeResult {
        +EnvelopeStatus status
        +JsonMap payload
        +EnvelopeError? error
    }
    class AgentDecision {
        +model, tokensPrompt, tokensCompletion
        +llmLatencyMs, llmCalls
    }

    class BenchmarkAgent {
        <<interface>>
        +AgentManifest manifest
        +startEpisode(task, descriptor)
        +next(lastResult, budget) Envelope
        +endEpisode(outcome)
    }
    class BenchmarkEnvironment {
        <<interface>>
        +describe() EnvironmentDescriptor
        +reset(fixture)
        +handle(envelope) EnvelopeResult
        +captureFinalState(queries) FinalStateSnapshot
    }
    class StateFingerprintProvider {
        <<interface>>
        +stateFingerprint() String
    }
    class ArtifactJudge {
        <<interface>>
        +judgeId
        +judge(request) JudgeAnswer
    }

    class ToolLoopAgent {
        <<abstract>>
        +systemPrompt / promptVersion
        +strategyTools
        +bootstrapEnvelope()
        +mapToolCall(call) Envelope
    }
    class FlutterEnvironment {
        +registerHandler(spec, handler)
        +settle / onReset / onStateQuery
    }
    class MockEnvironment
    class ScriptedAgent
    class RemoteAgent
    class RemoteEnvironment
    class LlmJudge

    BenchmarkAgent <|.. ScriptedAgent
    BenchmarkAgent <|.. ToolLoopAgent
    BenchmarkAgent <|.. RemoteAgent
    ToolLoopAgent <|-- SemanticsAgent
    ToolLoopAgent <|-- IntentAgent
    ToolLoopAgent <|-- GenUiAgent
    BenchmarkEnvironment <|.. MockEnvironment
    BenchmarkEnvironment <|.. FlutterEnvironment
    BenchmarkEnvironment <|.. RemoteEnvironment
    StateFingerprintProvider <|.. MockEnvironment
    StateFingerprintProvider <|.. FlutterEnvironment
    ArtifactJudge <|.. LlmJudge

    BenchmarkAgent ..> Envelope : emits
    BenchmarkEnvironment ..> EnvelopeResult : answers
    Envelope *-- AgentDecision
```

## 6. LLM agent — tool-calling loop (aib_agents)

All strategies share this skeleton; they differ only in envelope keys, tool
set and frozen system prompt — the fairness basis of the comparison (§7).

```mermaid
flowchart TB
    START(["startEpisode(task, descriptor)"]) --> BRIEF["conversation := system prompt (frozen, versioned)<br/>+ task briefing + discovered keys + budget"]
    BRIEF --> BOOT["emit deterministic bootstrap observation<br/>(semantics.tree / intents.catalog / data.context)<br/>— no LLM call"]
    BOOT --> FEED

    FEED["feed result of last envelope back<br/>(tool-result message + budget note)"] --> QUEUE{queued tool calls left?}
    QUEUE -- yes --> EMIT["map next tool call -> Envelope<br/>(attach telemetry: tokens, latency, calls)"]
    EMIT --> ENGINE(["engine: env.handle(envelope)"])
    ENGINE --> FEED

    QUEUE -- no --> CALL["LLM turn (temperature 0)<br/>tools = strategy tools + done + abort"]
    CALL --> KIND{response}
    KIND -- "tool calls" --> MAP{known tool?}
    MAP -- yes --> EMIT
    MAP -- "no (bounded retries)" --> ERRRES["append error tool-result<br/>'unknown tool'"] --> CALL
    KIND -- "plain text" --> NUDGE["nudge: one tool call, or done<br/>(ADR 0011); after the retries<br/>the text is the answer"] --> CALL
    KIND -- "done tool" --> DONE
    KIND -- "abort tool / LLM failure after retry" --> ABORT(["meta.abort (reason)"])
```

## 7. Deployment variants — same core, different wiring

The engine cannot tell the difference between these setups; the conformance
suite proves identical verdicts/metrics in-process vs over the wire (M6 goal).

```mermaid
graph TB
    subgraph V1["In-process (todo_app M2–M4, dynamate M5)"]
        E1["BenchmarkEngine"] --- A1["ScriptedAgent /<br/>ToolLoopAgents"]
        E1 --- F1["FlutterEnvironment<br/>(widget-test harness,<br/>bounded frame pumping)"]
    end

    subgraph V2["Remote agent (Phase 6: VisionAgent)"]
        E2["BenchmarkEngine"] --- RA["RemoteAgent"]
        RA <-->|"Agent Protocol 2.0<br/>JSON-RPC 2.0 over stdio"| PY["external agent process<br/>(e.g. Python)"]
        E2 --- F2["FlutterEnvironment"]
    end

    subgraph V4["Over MCP (an agent operates the benchmark)"]
        CL["MCP client<br/>(Claude Code, a tuning agent)"] <-->|"stdio or Streamable HTTP<br/>+ bearer token"| MS["aib_mcp server"]
        MS --> SV["AibService"]
        MS -->|"runner recipes"| JOB["jobs: mock in process,<br/>flutter test subprocesses"]
    end

    subgraph V3["Remote environment (device/emulator, later)"]
        E3["BenchmarkEngine"] --- A3["Agents"]
        E3 --- RE["RemoteEnvironment"]
        RE <-->|"Environment Protocol 2.0<br/>(JSON-RPC 2.0 over TCP)"| DEV["app on device with<br/>EnvironmentProtocolServer"]
    end
```

## 8. SYSco Mobile+ — the shipped agent is the measured agent

The assistant ships inside the app and is built by the same
`AgentProfile.build` the benchmark uses. The benchmark harness lives in the
app repository (`integration_test/aib/`) and copies the suite in before a run
and out again after it, so a release build never carries a task suite.

```mermaid
graph LR
    subgraph MA["framework repo"]
        CORE2["aib_core / aib_agents / aib_flutter<br/>(app-safe entry points only)"]
        SUITE2[("suites/sysco_v1.yaml<br/>agents · fixtures · rubrics")]
    end

    subgraph DY["app repo (dynamate)"]
        subgraph APPF["lib/features/assistant (ships)"]
            RT["assistant runtime<br/>AgentProfile.build(...)"]
            ENVA["FlutterEnvironment + bridges<br/>intents · semantics · user"]
        end
        subgraph IT["integration_test/aib (not shipped)"]
            PREP["prepare_benchmark_inputs<br/>suites → assets"]
            LIVE["m5_live_benchmark_test<br/>BenchmarkRunner in the app"]
            DISC["discard_benchmark_inputs"]
        end
    end

    CORE2 --> RT
    CORE2 --> ENVA
    SUITE2 -.-> PREP
    PREP --> LIVE
    LIVE --> ENVA
    LIVE --> DISC
    LIVE -->|"run dir in ~/Downloads,<br/>collected into results/"| OUT[("results/")]
```

## 9. aib_mcp — jobs, tuning and the holdout

```mermaid
flowchart LR
    AGT["tuning agent"] -->|"aib_study"| J[("experiments/&lt;study&gt;/journal.jsonl")]
    AGT -->|"aib_derive_agent_config<br/>(one config path per arm)"| ARM[("suites/agents/experiments/")]
    AGT -->|"aib_run_start"| Q["JobManager<br/>one run per model host;<br/>budget and elicitation for priced models"]
    Q --> RUNS[("results/&lt;out&gt;")]
    AGT -->|"aib_compare · aib_replay_thresholds"| SPLIT{"suites/splits/<br/>tuning split only"}
    SPLIT --> RUNS
    AGT -->|"aib_holdout_score"| ASK{"a person approves<br/>every call"}
    ASK --> HOLD["run on the held-out tasks,<br/>suite-level score only"]
    HOLD --> J
    Q --> J
```
