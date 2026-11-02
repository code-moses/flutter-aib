# aib_cli

The `aib` command of the AI Interaction Benchmark. Execution and evaluation
are separate passes: `run` writes traces, and `evaluate` scores them later,
as often as needed.

```sh
dart pub global activate aib_cli    # or add it as a dev_dependency: dart run aib_cli:aib …

aib validate --suite suites/todo_v1.yaml
aib run      --suite suites/mock_v1.yaml --agents scripted=suites/scripts/mock_scripted.yaml \
             --env mock --out results/demo
aib evaluate --run results/demo
aib report   --run results/demo --format md,csv,json,html,junit
aib compare  --runs results/A --runs results/B --out results/
aib gate     --baseline results/A --run results/B    # exit 1 on a regression
```

Further commands: `route`, `calibrate`, `labelsheet`, `selftest`, `metrics`,
`intents`, `catalog`, `provenance`, `doctor`; `aib <command> --help` lists
their options. `run` resumes an existing output directory and refuses to
when suite, agents, seed or repetitions changed.

The commands are a thin layer over `AibService` (`package:aib_cli/aib_cli.dart`),
which the MCP server and the UI share. The example suites and agent configs
are in [the repository](https://github.com/code-moses/flutter-aib/tree/main/suites).
