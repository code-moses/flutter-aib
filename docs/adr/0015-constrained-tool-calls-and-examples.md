# ADR 0015 — Tool calls can be constrained, examples are opt-in, one call per turn is enforced

Date: 2026-09-26 · Status: accepted; first measurement at n=3 on one suite, see Measured

## Context

Local models fail the loop in ways a frontier model does not, and the failures
sit in three different places.

1. **The runtime's parse step.** A local runtime turns the model's text into
   `tool_calls` with a template-specific parser. What it cannot read — a call to
   a name that is not offered, arguments that are not JSON, a call written
   inside the reasoning block — comes back as an empty turn, and the loop can
   only nudge and retry. The p5 pilot (2026-09-17, `qwen3:8b`) ended four of six
   episodes in `model returned an empty response (3 retries)`. What those turns
   contained was not recorded, so their cause is not known. Two facts are:
   with `think` unset, `qwen3:8b` at temperature 0 answered the reconstructed
   first turn with no content and no call every time (the text was in a
   `thinking` field), and the same request with `think: false` produced the call.
   Ollama accepts `format` together with `tools`: the template still renders the
   tools, and only the answer after the reasoning is constrained.
2. **Arguments read from nowhere.** The traces show the model passing
   `filterIds: [3]`, `entryId: "00001"`, and the wrong `enteredValues` key, then
   recovering from the app's error in five to eight turns. `describe_intents` was
   also used one intent at a time, against the prompt's "in one call". Neither
   `hybrid_v4` nor any tool description contained a single example call.
3. **A contract the provider does not keep.** `parallelToolCalls: false` exists
   because the loop runs queued calls back to back without the model seeing the
   results in between (F13). Ollama has no such option; it accepts
   `parallel_tool_calls` and ignores it.

Also: `LlmRequest.responseGrammar` was declared for an on-device runtime and
read by no client. A field on a port that nothing honours is a promise the port
does not keep, and it sits on an interface that ships inside applications.

## Decision

Everything below is a config value under `agent:`, off by default and absent
from the recorded config when off, so an arm that predates it keeps the config
hash it was recorded and compared under. Each is one path, so an arm derived
over MCP varies exactly one of them.

- **`toolCalling: constrained`.** The request carries a JSON schema that is a
  union over the offered tools, `{"tool": <const name>, "arguments": <that
  tool's schema>}`, `tool` first. `LlmRequest.responseSchema` replaces
  `responseGrammar`; a client that can decode under it says so with
  `LlmStructuredOutput.supportsResponseSchema` (Ollama; the model router only
  when both sides do). A `ToolLoopAgent` configured `constrained` against a
  client that would ignore the schema refuses to be built, because it would
  otherwise run unconstrained and be recorded as constrained. `done` and `abort`
  are among the tools, so prose is not a valid completion. Hosted providers
  already enforce a tool's schema through function calling and are not sent one.
- **`prompt: hybrid_v5` / `prepared_v2`.** New frozen versions: the old text plus
  four working patterns (look up then act, read the error, a number is not a
  list, say what you found) and one traced example in an invented app. Chosen
  by name from the agent's own family; a name from another family or one that
  does not exist is an error at build time. The v4 and v1 prompts are untouched
  and their hashes are pinned by a test.
- **`examples: {tools, intents}`.** `tools` adds a worked call to the
  descriptions the framework owns (`describe_intents`, `ask_user`, `done`).
  `intents` shows the `examples: [{params, when?}]` an app publishes with an
  intent, at most three, in that intent's tool description once it is described.
  Examples travel with `intents.describe` and a capability delta, not in the
  summary listing, so they are paid for only by an intent the agent chose. They
  are separate flags because a prompt example, a tool example and an intent
  example are three different treatments.
- **One call per turn is enforced by the loop** when `parallelToolCalls` is
  `false`: the first call runs, the rest are dropped from the request and from
  the history, and the decision says so (`parallel_dropped=n`,
  `extra.llm[].droppedParallel`). The Ollama client also sends the field; today
  that is a no-op, and the comment there says so.
- **What the model wrote is in the trace.** Every model call is recorded on its
  decision as `extra.llm[]`: `stopReason`, the names it called, `contentChars`,
  `thinkingChars`, whether it was constrained. `agent.captureModelOutput: true`
  adds the text and the reasoning themselves. It is off by default because the
  shipped assistant does not write a user's conversation into a log, and it is
  left out of the config hash (`AgentConfig.identity`) because it changes what
  is written down, not what the model sees. `LlmResponse.thinking` is read from
  Ollama (`thinking`), OpenAI-compatible servers (`reasoning_content`,
  `reasoning`) and Anthropic `thinking` blocks. It is never sent back and never
  scored: the instrument does not grade reasoning.

## Consequences

- Every trace now carries `extra.llm[]` (stop reason, names called, sizes). It
  is additive: the metrics read nothing under that key.
- Nothing here changes an existing arm's behaviour, with one exception: the
  one-call-per-turn rule now holds for every provider. Ollama arms that saw two
  calls in a turn before ran both; they now run the first and record the drop.
  `parallel_dropped` in a trace shows whether it ever mattered.
- Constrained decoding is a hypothesis under test. It removes a class of
  failure (an unparseable or unoffered call); it does not make the model choose
  better. A run that shows no gain from it is a finding about where the failures
  are, not a failed feature.
- Examples can leak the benchmark. The example calls the todo app publishes use
  values (`Garden`, `Fix the fence`, `diy`) that occur in no task of `todo_v2`,
  and the prompt patterns name no field of any app. An arm that gains from
  examples must be checked on the holdout, not only the tuning split.
- `responseGrammar` is gone from `LlmRequest`. Nothing in this repository or in
  SYSco Mobile+ set it. An app that wants GBNF passes a JSON schema and lets the
  runtime convert it.
- Constrained decoding over Ollama's `format` goes through llama.cpp's
  schema-to-grammar converter, which handles a subset of JSON Schema. An app
  schema that leans on a keyword outside it (`pattern`, `minimum`, `format`) may
  be constrained less than it looks, or refused by the runtime. The bridge
  validates arguments against the full schema before the handler runs and answers
  `bad_params`, so a gap costs a turn and not correctness — but it is a gap to
  check per app before reading a constrained arm's number.

## Measured (2026-09-26, `todo_v2` tuning split, qwen3:8b `think: false`, n=3)

Study `tool-calling-2026-09-26`: four arms, each derived from `hybrid_union` with
one change, on the same code. `tc_base` adds only `captureModelOutput`, so its
config hash equals `hybrid_union`'s. Judge `gpt-oss:20b`. 10 tasks, 30 episodes
per arm; the holdout was not run. Intervals are 95% bootstrap over tasks (tasks
resampled), the same interval `aib compare` reports.

| Arm | weighted | Δ vs base [95% CI] | success | tokens/ep | empty turns | `abort` |
|---|---:|---:|---:|---:|---:|---:|
| `tc_base` | 0.780 | | 0.600 | 25 435 | 4 | 1 (empty response) |
| `tc_constrained` | 0.766 | −0.014 [−0.192, +0.133] | 0.567 | 24 300 | 0 | 2 (stated reason) |
| `tc_prompt_v5` | 0.739 | −0.041 [−0.208, +0.092] | 0.633 | 32 299 | 9 | 2 (empty response) |
| `tc_examples` | 0.887 | +0.107 [−0.053, +0.307] | 0.800 | 27 008 | 0 | 0 (1 `budgetTurns`) |

What this supports, and what it does not:

1. **No difference is significant.** Every interval contains 0. At n=3 over ten
   tasks the arms are ranked, not separated.
2. **Constrained decoding does what it was built to do and nothing more.** Empty
   turns went from 4 to 0 and the `empty response` abort disappeared; the two
   aborts left are the model choosing `abort` with a reason on the guardrail task
   about an archived project. The score did not move, which is the ADR's
   expectation: it removes a parse failure, it does not choose better. On
   `v2.bulk.overdue.priority` it lost ground (1.00 to 0.33): the model called
   `todo.find {"overdue": true}` without the optional `projectName` and edited the
   wrong todos. That is consistent with a grammar changing which optional
   arguments get written, and it is one task at n=3. Not established.
3. **`hybrid_v5` did not help and cost tokens.** +27% tokens per episode, the
   same or lower score, and 9 empty turns (two `bulk.overdue.priority` episodes
   aborted on them). Longer input made the parse failure more frequent here, not
   less. The patterns are written for the SYSco failure (guessed ids); todo_v2
   already resolves names, so this suite may not be able to show the effect.
4. **Examples are the best arm and the one to distrust most.** +0.11, and two
   tasks moved from 0.33 to 1.00 (`v2.todo.tag`, `v2.ambiguous.title`) while
   `v2.guardrail.archived` fell from 0.47 to 0.20. The example calls were written
   for the todo app's intents (`todo.tag`, `todo.find`, `todo.move`, ...) with
   values that occur in no task, but they are still examples of the very intents
   the tasks use. The tuning-split gain is therefore not evidence of transfer.
   The check is the holdout (`v2.todo.move` is in it and has an example), and
   scoring it needs a person's approval each time.
5. **The trace now says what an empty turn was.** In `tc_base` all four empty
   turns are `stopReason: stop` with zero content and zero reasoning: the model
   ended its turn having produced nothing Ollama returned, which fits a call the
   runtime's parser discarded. The raw text is not visible through Ollama, so the
   cause is still inferred, not observed.

Not run, by decision: newer tool-trained local models, and any SYSco run. SYSco
runs build the app against the framework commit its `pubspec.yaml` pins, so they
need these changes committed and the ten pins bumped first.
