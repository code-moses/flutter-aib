# ADR 0018 — The environment can instruct the agent about its instance

Date: 2026-10-05 · Status: accepted, unmeasured

## Context

Every prompt in `Prompts` is frozen and app-agnostic, which is what makes two
runs comparable. SYSco Mobile+ is one app with very different installations:
a customer that mostly works with service orders and one that mostly signs
invoices and wants ad-hoc dashboards use the same intents for different
things, under different names. Until now an instance could say something
about itself only through observations — `scope` (ADR 0017), intent
descriptions — which a model reads as data about one call rather than as
standing guidance, and which arrive after the first decision.

The benchmark harness builds its agents from suite YAML before the app
environment exists, so instance text cannot travel in the agent config:
only the environment knows which instance it is.

## Decision

`EnvironmentDescriptor` gains an optional `instructions` string, and
`FlutterEnvironment` an `instructions` provider read on every `describe()`
(an instance's configuration can change between episodes). `ToolLoopAgent`
appends it to the frozen prompt under a fixed heading
(`ToolLoopAgent.instanceHeading`) that says who wrote it and that tool
results stay authoritative.

Appended, never substituted: the frozen prompt stays a byte-identical
prefix, so `promptHash` still names it and a provider's prompt cache still
hits up to the instance part.

`AgentConfig.environmentInstructions` (default on) lets an ablation arm run
the same agent without the instance text; it enters `identity` only when
switched off, so existing arms keep their `agentConfigHash`.

`RunManifest` records `environmentInstructionsHash` (from the descriptor at
run start) and refuses a resume across a change. A release gate that compares
a shipped build with a benchmarked run compares this hash too: instance text
that was not benchmarked is not the measured agent.

## Consequences

- Free for an environment that publishes none: no key in the descriptor JSON,
  no change to the system message, no field in the manifest.
- Every run against an app that starts publishing instructions is a
  different experiment from the runs before, and says so in its manifest.
- Instructions cost their tokens on every request of every episode. They
  should stay short and derived from what the instance actually is; per-user
  content would make the hash per-user and the gate meaningless.
- Whether instance text lowers the first-wrong-tool or premature-`done`
  rate is unmeasured; `environmentInstructions: false` is the arm to compare
  against.
