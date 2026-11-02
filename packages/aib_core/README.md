# aib_core

The core of the AI Interaction Benchmark: task model, benchmark engine,
episode traces, metrics, evaluation, aggregation and reporting. Pure Dart,
no Flutter. It knows only abstract concepts (task, agent, environment,
envelope, metric, verdict); adapters live in other packages.

## Libraries

| import | what | safe in an app |
|---|---|---|
| `package:aib_core/aib_core.dart` | everything: engine, runner, run store, evaluation, metrics, reports | no (`dart:io`) |
| `package:aib_core/ports.dart` | what an agent implementation needs, and nothing else | yes |
| `package:aib_core/transport.dart` | cancellation, error classification, retry policy for model clients | yes |
| `package:aib_core/field.dart` | traces, so a shipped assistant records in the benchmark's format | yes |
| `package:aib_core/catalog.dart` | the intent catalogue lint | yes |
| `package:aib_core/testing.dart` | `MockEnvironment` and `ScriptedAgent`, test doubles for the framework | no |

## Related packages

- [`aib_flutter`](https://pub.dev/packages/aib_flutter): the environment for Flutter apps
- [`aib_agents`](https://pub.dev/packages/aib_agents): LLM reference agents and the judge
- [`aib_protocol`](https://pub.dev/packages/aib_protocol): agents and environments in other processes or languages
- [`aib_cli`](https://pub.dev/packages/aib_cli): the `aib` command

Concepts, specification and design decisions:
[overview](https://github.com/code-moses/flutter-aib/blob/main/docs/overview.md),
[specification](https://github.com/code-moses/flutter-aib/blob/main/docs/specification.md),
[ADRs](https://github.com/code-moses/flutter-aib/tree/main/docs/adr).
