# aib_mcp

The AI Interaction Benchmark as an MCP server, so an agent can discover
suites, configure agents, run benchmarks as jobs and score them.

```sh
dart run aib_mcp:server --config aib_mcp.yaml            # stdio
AIB_MCP_TOKEN=… dart run aib_mcp:server --http           # Streamable HTTP, bearer token
```

The server works on a benchmark workspace: `aib_mcp.yaml` sets its root,
runners, hosts, budget and pinned judges. Without `--config` it uses
`./aib_mcp.yaml` if present, else the current directory. Agent configs live
in `suites/agents/`, derived ones in `suites/agents/experiments/`, and run
results in `results/`.

Rules the tools enforce:

- A new agent config is derived from an existing one with one change and a
  hypothesis.
- `aib_compare` refuses runs that differ in more than the names it is told
  to vary.
- Where a suite has a holdout split, every tool sees only the tuning split;
  `aib_holdout_score` needs a person's approval each time.
- Jobs are capped per job and per day by the budget in the config.

See [the overview](https://github.com/code-moses/flutter-aib/blob/main/docs/overview.md) and the example
[`aib_mcp.yaml`](https://github.com/code-moses/flutter-aib/blob/main/aib_mcp.yaml).
