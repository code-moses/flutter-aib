# Spezifikation & Implementierungsplan

## AI Interaction Benchmark Framework für Flutter-Anwendungen

**Arbeitstitel der Masterarbeit:** *Design and Evaluation of a Benchmark Framework for AI-based Interaction with Flutter Applications*

**Dokumentversion:** 1.0

---

## 1 Zweck und Einordnung dieses Dokuments

Dieses Dokument spezifiziert die programmatische Umsetzung des Benchmark-Frameworks, das den zentralen wissenschaftlichen Beitrag der Masterarbeit darstellt. Es übersetzt die Themenspezifikation in eine konkrete Software-Architektur, definiert alle Schnittstellen, Datenmodelle und Metriken formal und legt einen phasenbasierten Implementierungsplan fest.

Leitgedanke (gemäß Themenspezifikation): **Das Forschungsartefakt ist das Benchmark-Framework, nicht die Agenten.** Die Agenten sind Referenzimplementierungen, die das Framework validieren. Jede Architekturentscheidung in diesem Dokument ist diesem Ziel untergeordnet: Das Framework muss reproduzierbare, objektive, vergleichbare Messungen ermöglichen — unabhängig davon, *welcher* Agent, *welches* Modell oder *welche* Zieltechnologie evaluiert wird.

### 1.1 Zentrale Anforderung: Technologieagnostik

Das Framework wird in **Dart** implementiert, seine **Architektur ist jedoch vollständig von Flutter, von konkreten LLMs und von konkreten Interaktionsmustern entkoppelt**. Konkret bedeutet das:

1. Der Benchmark-Core (Task Runner, Metrics Collector, Result Aggregation, Reporting) kennt weder Flutter noch Widgets noch Semantics Trees. Er operiert ausschließlich auf abstrakten Konzepten: *Task*, *Agent*, *Environment*, *Observation*, *Action*, *Metric*, *Verdict*.
2. Alle Grenzen zwischen Core und Außenwelt sind als **Ports** (abstrakte Dart-Interfaces) definiert und zusätzlich als **wire protocol** (JSON über stdio/WebSocket) spezifiziert. Dadurch kann prinzipiell auch ein Python-Agent gegen eine React-Native- oder Web-Anwendung gebenchmarkt werden, sofern die jeweiligen Adapter das Protokoll implementieren.
3. Flutter-spezifische Funktionalität (Semantics-Tree-Zugriff, Intent-Dispatch, Widget-Interaktion, genui-Rendering) lebt ausschließlich in einem separaten Adapter-Package.

Diese Trennung ist nicht nur software-technisch sauber, sondern auch das zentrale wissenschaftliche Argument für die Generalisierbarkeit der Evaluierungsmethodik (-> Kapitel 6 der Arbeit, Validierung).

---

## 2 Design-Prinzipien

| #   | Prinzip                                                  | Konsequenz für die Architektur                                                                                                                                                                                                                                                                    |
| --- | -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P1  | **Hexagonale Architektur (Ports & Adapters)**            | Core ohne Abhängigkeiten auf Flutter, HTTP-Clients oder LLM-SDKs. Alle Abhängigkeiten zeigen nach innen.                                                                                                                                                                                          |
| P2  | **Protocol-first**                                       | Jeder Port existiert doppelt: als Dart-Interface *und* als versioniertes JSON-Protokoll. Das Interface ist die bequeme In-Process-Variante, das Protokoll die technologieübergreifende.                                                                                                           |
| P3  | **Determinismus, wo möglich; Protokollierung, wo nicht** | LLM-Ausgaben sind nicht-deterministisch. Alles andere (App-State, Fixtures, Task-Reihenfolge, Seeds, Zeitmessung) wird deterministisch kontrolliert. Nicht-Determinismus wird über n Wiederholungen pro Task statistisch behandelt und jede Einzelausführung als vollständiger Trace persistiert. |
| P4  | **Messung außerhalb des Messobjekts**                    | Der Metrics Collector instrumentiert den Kommunikationskanal (Protokollebene), nicht den Agenten. Agenten können ihre Messung nicht verfälschen, weil sie sie nicht kontrollieren.                                                                                                                |
| P5  | **Deklarative Tasks**                                    | Tasks sind Daten (YAML/JSON), kein Code. Neue Tasks erfordern keine Neukompilierung; Ground Truth und Erfolgskriterien sind maschinenlesbar.                                                                                                                                                      |
| P6  | **Trennung von Ausführung und Bewertung**                | Ein Benchmark-Lauf produziert zuerst rohe Traces; die Bewertung (Verdicts, Metriken, Aggregation) erfolgt als separater, wiederholbarer Schritt auf den Traces. So können neue Metriken nachträglich auf alte Läufe angewendet werden.                                                            |
| P7  | **Erweiterbarkeit über Registrierung**                   | Agenten, Environments, Metriken, Success-Evaluatoren und Reporter werden über Registries eingebunden (Plugin-Gedanke), nicht über Fallunterscheidungen im Core.                                                                                                                                   |

---

## 3 Systemarchitektur

### 3.1 Schichtenmodell

```
┌─────────────────────────────────────────────────────────────────┐
│  Layer 4 — Tooling                                              │
│  benchmark_cli · CI-Integration · Report-Viewer (HTML)          │
├─────────────────────────────────────────────────────────────────┤
│  Layer 3 — Adapters (austauschbar, technologie-spezifisch)      │
│  ┌──────────────────────┐  ┌─────────────────────────────────┐  │
│  │ Agent Adapters       │  │ Environment Adapters            │  │
│  │ · SemanticsAgent     │  │ · FlutterEnvironment            │  │
│  │ · IntentAgent        │  │   (integration_test / DevTools) │  │
│  │ · GenUiAgent         │  │ · RemoteEnvironment (Protokoll) │  │
│  │ · HybridAgent (opt.) │  │ · MockEnvironment (Tests)       │  │
│  │ · RemoteAgent (Proto)│  │                                 │  │
│  └──────────────────────┘  └─────────────────────────────────┘  │
├─────────────────────────────────────────────────────────────────┤
│  Layer 2 — Protocol                                             │
│  Agent Protocol v1 (JSON) · Environment Protocol v1 (JSON)      │
│  Transport: in-process | stdio | WebSocket                      │
├─────────────────────────────────────────────────────────────────┤
│  Layer 1 — Core (pure Dart, keine Flutter-Abhängigkeit)         │
│  TaskModel · BenchmarkEngine (Runner) · EpisodeTrace            │
│  MetricsCollector · SuccessEvaluator · Aggregator · Reporting   │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 Package-Struktur (Dart Monorepo)

```
ai_interaction_benchmark/
├── packages/
│   ├── aib_core/                 # Layer 1 — pure Dart
│   │   ├── lib/src/task/         #   Taskmodell, Suites, Fixtures
│   │   ├── lib/src/engine/       #   BenchmarkEngine, Scheduler, Retry
│   │   ├── lib/src/trace/        #   EpisodeTrace, Event-Log
│   │   ├── lib/src/metrics/      #   MetricDefinition, Collector, Registry
│   │   ├── lib/src/evaluation/   #   SuccessEvaluator, Verdict, Oracles
│   │   ├── lib/src/aggregation/  #   Statistik, Vergleichstabellen
│   │   └── lib/src/reporting/    #   Reporter-Interface, JSON/CSV/MD/HTML
│   ├── aib_protocol/             # Layer 2 — Protokoll-DTOs, Codecs,
│   │   └── ...                   #   Transporte (stdio, WebSocket), Versionierung
│   ├── aib_flutter/              # Layer 3 — FlutterEnvironment,
│   │   └── ...                   #   Envelope-Handler: Semantics, Intents, genui
│   ├── aib_agents/               # Layer 3 — Referenzagenten + LLM-Clients
│   │   └── ...                   #   (Anthropic/OpenAI/Ollama hinter LlmClient-Port)
│   └── aib_cli/                  # Layer 4 — CLI: run, evaluate, report, compare
├── apps/
│   ├── todo_app/                 # Testanwendung 1 (Varianten: good/bad Semantics)
│   └── sysco_mobile_plus/        # Testanwendung 2 (reale Business-App, Anbindung)
├── suites/                       # Deklarative Task-Suiten (YAML)
│   ├── todo_v1.yaml
│   └── sysco_v1.yaml
└── results/                      # Persistierte Traces & Reports (git-ignoriert)
```

Begründung Monorepo mit `melos`: gemeinsame Versionierung, atomare Refactorings über Package-Grenzen, aber saubere Abhängigkeitsrichtung (`aib_core` hat **keine** Abhängigkeit auf `flutter/*`; erzwungen via CI-Check der `pubspec.yaml`).

### 3.3 Kontrollfluss einer Episode

Eine **Episode** = eine Ausführung eines Tasks durch einen Agenten in einem Environment.

```
BenchmarkEngine                Agent (Port)              Environment (Port)
     │                             │                           │
     │── env.describe() / env.reset(fixture) ───────────────▶ │  Discovery + Ausgangszustand
     │◀───────────────────────────────── ready ────────────────│
     │── agent.startEpisode(taskSpec, descriptor)  ──▶        │
     │                             │                           │
     │        ┌────────── Interaktionsschleife ─────────┐      │
     │        │  agent.next(lastResult) ─▶ Envelope     │      │
     │        │  env.handle(envelope) ─▶ EnvelopeResult │      │
     │        │  (jeder Austausch -> EpisodeTrace-Event) │      │
     │        └──── bis: meta.done|meta.abort | Budget- │      │
     │              Limit | Timeout | Fatal Error ──────┘      │
     │                             │                           │
     │── env.captureFinalState() ─────────────────────────────▶│
     │◀──────────────── FinalStateSnapshot ────────────────────│
     │── SuccessEvaluator.judge(trace, groundTruth) -> Verdict  │
     │── persist(trace, verdict)                               │
```

Wesentlich: Die Engine ist der einzige Taktgeber. Agent und Environment kommunizieren **nie direkt** miteinander, sondern immer durch die Engine — nur so kann der Metrics Collector jeden Austausch lückenlos und manipulationssicher protokollieren (P4).

---

## 4 Ports: Interfaces und Protokoll

### 4.1 Grundsatzentscheidung: Der Core besitzt kein Vokabular

Der Core definiert **keine** Observation-Modalitäten und **keine** Action-Typen. Beides sind Implementierungsdetails der Agent↔Environment-Beziehung, die den Core nichts angehen. Der Core kennt nur einen generischen, inhaltlich opaken Nachrichtenumschlag:

```dart
/// Einzige Datenstruktur, die der Core über den Inhalt der
/// Agent↔Environment-Kommunikation kennt. Inhaltlich opak.
final class Envelope {
  final String key;        // frei wählbar durch den Agenten, z. B. "semantics.tree",
                           // "intents.catalog", "form.fill" — KEIN vom Core
                           // vorgegebener Katalog. Einzige Reservierung: "meta.*"
  final EnvelopeKind kind; // observe | act (deklariert der Agent, s. 4.4)
  final JsonMap payload;   // opak für den Core
}

final class EnvelopeResult {
  final EnvelopeStatus status; // ok | unsupported | failed
  final JsonMap payload;       // opak für den Core
  final EnvelopeError? error;  // strukturiert bei unsupported/failed
}
```

**Reservierter Namespace:** ausschließlich `meta.*` — konkret `meta.done(resultSummary)` und `meta.abort(reason)` als Terminierungssignale. Alles andere ist Konvention zwischen Agent und Environment.

Dass ein Semantics-Agent den Semantics Tree liest und ein Intent-Agent den Intent-Katalog, ist damit vollständig **Verantwortung des Agenten**: Er wählt seine Keys, er interpretiert die Payloads, er weiß, welche Informationen er braucht. Das Environment beantwortet, was es beantworten kann, und lehnt den Rest strukturiert ab (`unsupported`). Der Core misst nur den Austausch selbst — Anzahl, Zeitpunkte, Payload-Größen, Status — ohne dessen Bedeutung zu kennen.

### 4.2 Environment Port

```dart
abstract interface class BenchmarkEnvironment {
  /// Selbstbeschreibung zur Laufzeit (Discovery, analog zum
  /// Tool-Listing im Model Context Protocol): welche Keys versteht
  /// dieses Environment, mit welchen Payload-Schemata?
  /// Der Core interpretiert dieses Dokument NICHT — er reicht es
  /// lediglich an den Agenten durch.
  Future<EnvironmentDescriptor> describe();

  /// Deterministischer Reset auf den Fixture-Zustand.
  Future<void> reset(FixtureRef fixture);

  /// Einziger generischer Kommunikationskanal.
  Future<EnvelopeResult> handle(Envelope envelope);

  /// Snapshot des finalen Zustands für die Ground-Truth-Prüfung.
  Future<FinalStateSnapshot> captureFinalState(List<StateQuery> queries);
}
```

Der `EnvironmentDescriptor` ersetzt die frühere statische Capability-Enumeration durch **Laufzeit-Discovery**: Das Environment publiziert seine unterstützten Keys samt JSON-Schemata (z. B. publiziert `aib_flutter` für die Todo-App u. a. `semantics.tree`, `semantics.tap`, `intents.catalog`, `intents.invoke`, `genui.render` — als *Konvention dieses Adapters*, nicht als Core-Contract). Ein Agent kann den Descriptor nutzen, muss aber nicht — er kann Keys auch spekulativ senden und erhält bei Nichtunterstützung ein sauberes `unsupported`.

### 4.3 Agent Port

```dart
abstract interface class BenchmarkAgent {
  AgentManifest get manifest;

  Future<void> startEpisode(
    TaskSpec task,
    EnvironmentDescriptor environment, // Discovery-Dokument, opak durchgereicht
  );

  /// Kern der Schleife: Der Agent erhält das Ergebnis seines letzten
  /// Envelopes sowie den Budget-Status und emittiert den nächsten Envelope.
  /// Terminierung durch meta.done / meta.abort oder Budget/Timeout.
  Future<Envelope> next(EnvelopeResult? lastResult, BudgetStatus budget);

  Future<void> endEpisode(EpisodeOutcome outcome);
}
```

Der Agent ist damit vollständig selbst für seinen Informationszugriff zuständig: Er entscheidet, *was* er beobachtet, *wann* er es beobachtet und *wie* er handelt. `Envelope.kind` (observe/act) deklariert der Agent selbst — der Core braucht diese Unterscheidung ausschließlich für Effizienzmetriken (`action_count` zählt nur `act`-Envelopes). Ein als `observe` deklarierter Envelope, der nachweislich App-Zustand verändert (State-Diff), wird als Integritätsverletzung gezählt und im Report ausgewiesen — deklarieren statt vorschreiben, aber verifizieren.

`AgentDecision`-Telemetrie (Modell, Token, LLM-Latenz, Roundtrips) bleibt wie gehabt verpflichtender Bestandteil jeder `next()`-Antwort (self-reported, Kennzeichnung im Report).

### 4.4 Das eine Konzept, das bewusst erhalten bleibt: mediierter Austausch

Wichtig zur Abgrenzung, weil hier zwei getrennte Fragen leicht verschwimmen:

1. **Wer definiert das Vokabular?** -> Agent + Environment-Adapter (Konvention/Discovery). Der Core nicht. ✔ Deine Anforderung.
2. **Über welchen Kanal fließt die Kommunikation?** -> Weiterhin ausnahmslos durch die Engine (Agent und Environment kennen einander nicht direkt).

Punkt 2 ist unabhängig von Punkt 1 und bleibt bestehen, denn er ist die Grundlage der Messvalidität (P4): Nur wenn jeder Informationszugriff und jede Aktion als Envelope durch die Engine läuft, kann der Metrics Collector lückenlos und agentenunabhängig messen — Anzahl der Zugriffe, Payload-Größen (Proxy für Kontextlast), Latenzen, Fehlerquoten, State-Diffs. Würde der Semantics-Agent den Semantics Tree *direkt* aus der App lesen (am Framework vorbei), wären genau die Metriken blind, die die Interaktionsstrategien unterscheiden sollen. „Der Agent ist selbst für seinen Informationszugriff zuständig" bedeutet also: **er entscheidet autonom über Inhalt und Strategie des Zugriffs — aber der Zugriff selbst ist beobachtbar.** Das ist dieselbe Trennung wie bei einem Netzwerk-Benchmark: Die Anwendung wählt frei, welche Requests sie sendet; gemessen wird trotzdem am Wire.

Für die Referenzagenten in `aib_agents` gilt entsprechend: Die dort verwendeten Keys (`semantics.*`, `intents.*`, `genui.*`) sind dokumentierte Konventionen zwischen diesen Agenten und dem `aib_flutter`-Adapter — versioniert in dessen README, nicht im Core, nicht im Protokoll.

### 4.5 Wire Protocol (technologieübergreifende Variante)

Beide Ports werden 1:1 als JSON-Protokoll abgebildet (`aib_protocol`). Nachrichtenrahmen:

```json
{
  "aib": "1.0",
  "id": "msg-000042",
  "kind": "request | response | event",
  "method": "agent.next",
  "payload": { "...": "..." }
}
```

- **Transporte:** `stdio` (Zeilen-getrennte JSON-Objekte; einfachster Weg, einen Python-Agenten anzubinden) und `WebSocket` (für Environments auf realen Geräten/Emulatoren).
- **Versionierung:** `aib`-Feld + Capability-Negotiation beim Handshake. Unbekannte Felder werden ignoriert (forward compatibility).
- **Referenz-Konformität:** Ein Conformance-Test (`aib_protocol/test/conformance/`) prüft jede Adapter-Implementierung gegen einen Golden-Message-Katalog. Dieser Test ist gleichzeitig die formale Protokollspezifikation für Dritt-Implementierungen.

Damit ist die Kernanforderung erfüllt: **Ein Agent in beliebiger Sprache** (Python-Skript via stdio) **gegen eine beliebige App** (jedes System, das das Environment-Protokoll spricht — denkbar: Appium-Bridge für native Apps, Playwright-Bridge für Web) kann mit unverändertem Core gebenchmarkt werden.

---

## 5 Taskmodell

### 5.1 Deklarative Task-Definition (YAML)

```yaml
# suites/todo_v1.yaml (Auszug)
suite: todo_v1
schema: aib-task/1.0
defaults:
  repetitions: 5            # n Wiederholungen pro Agent×Task (P3)
  budget:
    maxSteps: 25
    maxWallClockSeconds: 180
    maxTokens: 60000
  fixture: fixtures/todo_seed_baseline.json

tasks:
  - id: todo.create.simple
    title: "Aufgabe erstellen (einfach)"
    instruction: >
      Erstelle eine neue Aufgabe mit dem Titel "Milch kaufen"
      und dem Fälligkeitsdatum 2026-07-10.
    tags: [crud, create, difficulty:easy]
    groundTruth:
      finalState:
        - query: "db.todos.where(title == 'Milch kaufen')"
          expect:
            count: 1
            fields: { dueDate: "2026-07-10", completed: false }
    successCriteria:
      - type: finalStateMatch          # harte, automatische Prüfung
        weight: 1.0
    partialCredit:
      - condition: "count == 1 && fields.dueDate != '2026-07-10'"
        credit: 0.5
        label: "Task angelegt, Datum falsch"

  - id: todo.dashboard.generate
    title: "Dashboard erzeugen"
    instruction: >
      Erstelle eine Übersicht über alle offenen Aufgaben,
      gruppiert nach Fälligkeit.
    tags: [genui, difficulty:medium]
    groundTruth:
      artifact:
        kind: genui.surface
        assertions:
          - "surface enthält alle 7 offenen Tasks"
          - "Gruppierung nach Fälligkeitsdatum erkennbar"
    successCriteria:
      - type: artifactRubric           # LLM-as-Judge mit fixer Rubrik
        rubric: rubrics/dashboard_v1.yaml
        judgeModel: pinned             # Modell + Version im Suite-Manifest fixiert
        weight: 1.0
```

### 5.2 Erfolgsprüfung: Oracle-Hierarchie

Bewertung erfolgt bevorzugt über die **härteste verfügbare Prüfung** (absteigend nach Objektivität):

1. **`finalStateMatch`** — deterministischer Vergleich des `FinalStateSnapshot` gegen Ground Truth (DB-Queries, Screen-Assertions). Für alle CRUD-/Navigations-/Formulartasks. *Vollautomatisch, objektiv.*
2. **`traceAssertion`** — Prädikate über den Event-Trace (z. B. "kein destruktiver Intent wurde aufgerufen"). *Vollautomatisch.*
3. **`artifactRubric`** — LLM-as-Judge mit versionierter Rubrik, gepinntem Judge-Modell, Temperatur 0 und k=3 Judge-Wiederholungen (Mehrheitsentscheid). Nur für inhärent weiche Ziele (genui-Qualität, Zusammenfassungen). Die Judge-Zuverlässigkeit wird einmalig gegen eine kleine, manuell gelabelte Stichprobe kalibriert (Cohen's κ wird in der Arbeit berichtet).
4. **`manualReview`** — Fallback; im Report explizit als solcher markiert.

Ein `Verdict` pro Episode: `success | partial(credit, label) | failure(reason) | error(frameworkFault)`. Framework-Fehler (Environment crasht, Transport bricht ab) werden **nicht** dem Agenten angelastet, sondern führen zur Wiederholung der Episode und werden separat gezählt (`infrastructure_error_rate` — wichtig für die Glaubwürdigkeit der Ergebnisse).

### 5.3 Reproduzierbarkeit — konkrete Maßnahmen

| Quelle von Varianz     | Maßnahme                                                                                                                                                           |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| App-Zustand            | Fixtures: vollständiger Seed-Zustand als Datei, `env.reset()` stellt ihn byte-genau her; Todo-App nutzt In-Memory/SQLite-Seed, SYSco eine dedizierte Testdatenbank |
| LLM-Nichtdeterminismus | temperature=0 wo sinnvoll; n Wiederholungen; Modellversion + Provider + Datum im `RunManifest` gepinnt; vollständige Prompts/Completions im Trace                  |
| Zeitmessung            | Monotonic Clock; LLM-Latenz getrennt von Framework-Overhead und App-Renderzeit ausgewiesen                                                                         |
| Task-Reihenfolge       | Fester Seed für Shuffle; Reihenfolge im RunManifest                                                                                                                |
| Umgebung               | RunManifest erfasst: Framework-Version (git SHA), Dart/Flutter-Version, Gerät/Emulator-Profil, Suite-Version, alle Konfig-Hashes                                   |

Jeder Lauf ist damit über sein `RunManifest` vollständig beschrieben und (bis auf LLM-Antworten) exakt wiederholbar; die LLM-Antworten selbst sind im Trace konserviert, sodass **Re-Evaluation** (P6) jederzeit deterministisch möglich ist.

---

## 6 Metrikkatalog

Alle Metriken werden **pro Episode** aus dem Trace berechnet (P6) und anschließend über Wiederholungen und Tasks aggregiert. Formale Definition je Metrik: Name, Einheit, Erhebungsquelle, Aggregation.

### 6.1 Effektivität

| Metrik                        | Definition                                                                          | Quelle        | Aggregation                                 |
| ----------------------------- | ----------------------------------------------------------------------------------- | ------------- | ------------------------------------------- |
| `success_rate`                | Anteil Episoden mit Verdict `success`                                               | Verdict       | Mittel über Wiederholungen; 95%-CI (Wilson) |
| `weighted_score`              | success=1, partial=credit, failure=0                                                | Verdict       | Mittel + CI                                 |
| `failure_rate` / `abort_rate` | Anteil `failure` bzw. `meta.abort`                                                  | Verdict/Trace | Mittel                                      |
| `unsupported_envelope_count`  | Envelopes mit Status `unsupported` (Agent fordert nicht vorhandene Fähigkeit an)    | Engine        | Median, p95                                 |
| `kind_integrity_violations`   | als `observe` deklarierte Envelopes mit nachweisbarer Zustandsänderung (State-Diff) | Engine        | Summe                                       |

### 6.2 Effizienz

| Metrik                                    | Definition                                                                               | Quelle                 | Aggregation                                 |
| ----------------------------------------- | ---------------------------------------------------------------------------------------- | ---------------------- | ------------------------------------------- |
| `wall_clock_ms`                           | reset-Ende -> Verdict-fähiger Endzustand                                                 | Engine (monotonic)     | Median, p95                                 |
| `llm_latency_ms`                          | Summe gemeldeter LLM-Latenzen                                                            | Agent-Telemetrie       | Median                                      |
| `framework_overhead_ms`                   | wall_clock − llm_latency − app_render                                                    | Engine                 | Median (Sanity-Check des Frameworks selbst) |
| `action_count`                            | Anzahl `act`-Envelopes bis Terminierung                                                  | Trace                  | Median                                      |
| `observation_count` / `observation_bytes` | Anzahl und Payload-Volumen der `observe`-Envelopes (Proxy für Kontextlast der Strategie) | Trace                  | Median                                      |
| `redundant_action_ratio`                  | `act`-Envelopes ohne relevante App-Zustandsänderung / action_count                       | Trace + State-Diffs    | Median                                      |
| `path_efficiency`                         | minimale bekannte Action-Zahl (aus Task-Definition, `optimalSteps`) / action_count       | Task + Trace           | Median                                      |
| `navigation_detours`                      | Screenwechsel, die weder auf dem Optimalpfad liegen noch zum Ziel beitragen              | Trace (`viewMetadata`) | Median                                      |

### 6.3 Ressourcen

| Metrik                                                 | Definition                                                                     | Quelle             |
| ------------------------------------------------------ | ------------------------------------------------------------------------------ | ------------------ |
| `tokens_prompt` / `tokens_completion` / `tokens_total` | Provider-Usage, self-reported (Kennzeichnung, s. 4.2)                          | Agent-Telemetrie   |
| `cost_usd`                                             | tokens × gepinnte Preistabelle (im RunManifest versioniert, da Preise volatil) | Aggregator         |
| `llm_roundtrips`                                       | Anzahl LLM-Aufrufe pro Episode                                                 | Agent-Telemetrie   |
| `peak_memory_mb` (optional)                            | Environment-seitig via VM-Service                                              | FlutterEnvironment |
| `energy` (optional, out of scope für v1)               | —                                                                              | —                  |

### 6.4 Robustheit & Recovery

| Metrik                        | Definition                                                                        | Quelle                                 |
| ----------------------------- | --------------------------------------------------------------------------------- | -------------------------------------- |
| `cross_model_variance`        | Streuung von `weighted_score` desselben Agenten über ≥2 Modelle                   | Aggregator                             |
| `semantics_degradation_delta` | Score(good semantics) − Score(bad semantics) auf identischer Task-Suite           | Aggregator (Todo-Varianten)            |
| `retry_count`                 | erkannte Wiederholungsversuche nach fehlgeschlagener Action                       | Trace-Heuristik + `ActionResult.error` |
| `recovery_success_rate`       | Anteil der Fehler-Situationen, nach denen die Episode dennoch mit success endet   | Trace                                  |
| `recovery_time_ms`            | Zeit von erstem Fehler bis erster wieder zustandsverändernder Action              | Trace                                  |
| `self_correction_count`       | Actions, die eine vorherige eigene fehlerhafte Zustandsänderung rückgängig machen | State-Diff-Analyse                     |

### 6.5 Vergleichs- und Berichtsebene

- **Primärvergleich:** Agent × Task-Suite-Matrix mit `weighted_score`, `wall_clock_ms` (Median), `tokens_total` (Median), `cost_usd`.
- **Sekundäranalysen:** pro Tag/Difficulty, pro Modalität, Degradationsanalyse (good vs. bad Semantics), Pareto-Front Kosten↔Erfolg.
- **Statistik:** Wiederholungen n≥5; Konfidenzintervalle immer mitberichten; für paarweise Agentenvergleiche auf identischen Tasks: Permutationstest bzw. Bootstrap (keine Normalverteilungsannahme). Signifikanzniveau und Verfahren im Methodikkapitel der Arbeit fixieren.

---

## 7 Referenzagenten (Layer 3, `aib_agents`)

Alle Agenten teilen sich eine gemeinsame Basis (`LlmClient`-Port mit Anthropic/OpenAI/Ollama-Implementierungen, Tool-Calling-Loop, Telemetrie-Erfassung). Unterschiede liegen ausschließlich in verwendeten Envelope-Keys + Tool-Set + System-Prompt (Keys = Konvention mit `aib_flutter`, s. 4.4) — dadurch ist der Vergleich fair (gleiches Prompt-Gerüst, gleiche Loop-Logik).

| Agent                                | genutzte observe-Keys          | genutzte act-Keys           | Besonderheiten                                                                                                                                                                                                                                                           |
| ------------------------------------ | ------------------------------ | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **SemanticsAgent** (P2)              | `semantics.tree`               | `semantics.*`, `meta.*`     | Baum-Serialisierung mit Pruning (nur interaktive + Label-Knoten) und stabilen IDs; orientiert an `flutter_ai_assistant`                                                                                                                                                  |
| **IntentAgent** (P2)                 | `intents.catalog`, `view.meta` | `intents.invoke`, `meta.*`  | Intents werden dem LLM als Tools (Function Calling) präsentiert; eigene Intent-API-Bridge in `aib_flutter` mappt Flutter `Actions`/`Intents` auf das Protokoll                                                                                                           |
| **GenUiAgent** (P3)                  | `data.context`                 | `genui.render`, `meta.done` | Keine UI-Steuerung; Bewertung über `artifactRubric`                                                                                                                                                                                                                      |
| **HybridAgent** (P4, optional)       | alle                           | alle                        | Strategie-Router; nur bei Zeitreserve                                                                                                                                                                                                                                    |
| **VisionAgent** (Kap. 6 Validierung) | `screen.capture`               | `pointer.*`, `meta.*`       | Bewusst NICHT Teil der Kernvergleiche — dient als "fremder" Agent zum Nachweis, dass das Framework unveränderte Aufnahme neuer Ansätze erlaubt. Idealerweise als **externes Python-Skript via stdio-Protokoll** implementiert -> stärkster Generalisierbarkeits-Nachweis |

---

## 8 Testanwendungen

### 8.1 Todo-App (kontrollierte Bedingungen)

- Feature-Set exakt entlang der Benchmark-Aufgaben: CRUD, Suche, Filter, Dashboard-Surface für genui.
- **Build-Varianten über Compile-Flag:** `--dart-define=SEMANTICS_QUALITY=good|bad`. `bad` = fehlende Labels, generische Buttons, unbeschriftete Icons, tief verschachtelte Merge-Knoten — realistisch schlechte Accessibility.
- Persistenz: SQLite (drift) mit Seed-Fixture; `env.reset()` = DB drop + seed + Navigation auf Root.
- Vollständige Intent-API parallel zur UI (Parität sichergestellt durch gemeinsame UseCase-Schicht — UI und Intents rufen denselben Code).

### 8.2 SYSco Mobile+ (externe Validität)

- Reale Business-App: komplexe Formulare, Navigation, Tabellen, Suche, Filter, Informationsabfragen.
- Anbindung ausschließlich über `aib_flutter`-Instrumentierung (Package-Import + Registrierung im `main()` der Debug-Flavor) — **keine invasiven Änderungen** an der App; das ist selbst ein Ergebnis (Aufwand der Anbindung wird dokumentiert, -> Erweiterbarkeitsnachweis).
- Fixture über dedizierte Testdatenbank/Mock-Backend; destruktive Tasks nur gegen Testdaten.
- Risiko-Fallback: Falls SYSco-Anbindung scheitert oder zu aufwendig wird (Backend-Abhängigkeiten!), Ersatz durch zweite selbst kontrollierte App mit Business-Charakter (Formular-/Tabellen-lastig). Entscheidung bis Ende Phase 3 (s. u.).

---

## 9 CLI & Reporting (Layer 4)

```
aib run      --suite suites/todo_v1.yaml --agents semantics,intent --env todo:good \
             --models claude-sonnet,gpt-4o --reps 5 --out results/2026-07-15/
aib evaluate --run results/2026-07-15/          # (Re-)Bewertung der Traces
aib report   --run results/2026-07-15/ --format html,csv,md
aib compare  --runs results/A results/B         # Vergleich zweier Läufe
aib validate --suite suites/todo_v1.yaml        # Schema-Check der Task-Definitionen
```

**Report-Artefakte:** `run_manifest.json`, `traces/*.jsonl` (ein Event pro Zeile), `verdicts.json`, `metrics.csv` (long format, direkt in Python/R analysierbar), `report.html` (Vergleichstabellen, CI-Fehlerbalken, Pareto-Plot), `report.md` (zum direkten Einbinden in die Arbeit). Alle Zahlen in der Masterarbeit sollen aus diesen Artefakten generierbar sein (ein Notebook/Skript `analysis/` reproduziert jede Abbildung).

---

## 10 Teststrategie für das Framework selbst

Das Framework misst — also muss das Framework selbst validiert sein:

1. **Unit-Tests** für Metrik-Berechnungen mit synthetischen Traces (bekannte Erwartungswerte).
2. **`MockEnvironment` + `ScriptedAgent`:** deterministische Agenten mit vordefinierten Action-Sequenzen (perfekt / mit Umwegen / mit Fehlern+Recovery / abbrechend) -> Ende-zu-Ende-Prüfung, dass Engine, Collector und Evaluator exakt die erwarteten Metriken liefern. Dies ist zugleich das zentrale Argument für die Messvalidität in der Arbeit.
3. **Protocol-Conformance-Tests** (s. 4.3) für jeden Adapter.
4. **Overhead-Messung:** `framework_overhead_ms` mit ScriptedAgent quantifiziert, dass das Framework die Messung nicht dominiert.

## 11 Abgrenzung

Kein Modelltraining, keine LLM-Entwicklung, keine Optimierung einzelner Modelle, keine produktionsreife Plattform, keine vollständige ERP-Integration, keine großen Benutzerstudien. Agenten sind Referenzimplementierungen.

---

## Anhang A — Zuordnung zu den Forschungsfragen

| Forschungsfrage                                  | Beantwortet durch                                                                        |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| Hauptfrage: reproduzierbares Benchmark-Framework | Gesamtarchitektur (Kap. 3–5 dieses Dokuments), Reproduzierbarkeitsmaßnahmen (5.3), M1/M2 |
| Relevante Qualitätskriterien                     | Qualitätsmodell -> Metrikkatalog (Kap. 6), Begründung je Dimension in Arbeit Kap. 3.2    |
| Geeignete Metriken                               | Kap. 6 inkl. formaler Definitionen + Validierung über ScriptedAgent (Kap. 10)            |
| Reproduzierbare Task-Beschreibung                | Deklaratives Taskmodell + Fixtures + Oracles (Kap. 5)                                    |
| Unterschiede der Strategien                      | Evaluationsläufe M3–M5, Vergleichsebene 6.5                                              |
| Modell-/Agenten-Unabhängigkeit                   | Ports & Protokoll (Kap. 4), Validierung M6 (Core-Diff = leer)                            |
