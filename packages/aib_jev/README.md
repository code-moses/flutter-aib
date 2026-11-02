# aib_jev — decision models for Dart

A decision model ("System One", TypeSafe's Jev) reads a **state** — text,
JSON or a conversation — and answers typed **questions** with a
distribution instead of text:

| question | shape | answer |
|---|---|---|
| `JevChoice` | 2–50 named candidates (or an enum) | `choice`, `probabilities`, `margin`, `ties` |
| `JevScore` | 2–50 ordered levels | expected level index (`1.035`), `variance` |
| `JevNoul` | one statement | truth on [0.01, 0.99], rating distribution |

This package is everything around the forward pass, pure Dart and app-safe
(no `dart:io`, no Flutter). It depends on nothing from the benchmark except
`aib_core`'s transport primitives (`CancellationToken`, `RetryPolicy`,
`TransportException`), so an app that wants a decision model takes this
package and none of the agents.

## Backends

One port, `JevClient`. Remote servers get the request as JSON. Local
runtimes get the prompt from Dart and return only the label logits.

| backend | class | where the model runs | notes |
|---|---|---|---|
| hosted TypeSafe API | `HttpJevClient` | remote | `baseUrl: https://api.typesafe.ai`, bearer key |
| System One server | `HttpJevClient` | simple-jev, LiteVar, openjev | `/v1/systemone`; the server builds the prompt |
| Ollama | `LogitJevClient` + `OllamaJevLogits` | local server | ~50–80 ms warm; top-20 logprobs |
| OpenAI `/v1/completions` | `LogitJevClient` + `OpenAiCompletionsJevLogits` | llama-server, vLLM, LM Studio | three reply shapes read |
| in-process llama.cpp | `LogitJevClient` + `LlamaJevLogits` | this process | package `aib_jev_llama` (ffi) |

`LogitJevClient` plans the prompt with the v1 template and scores the
logits the same way simple-jev does. `test/golden_test.dart` checks both
against simple-jev's own code at the pinned commit (`tool/jev_golden.py`):
every prompt string, the Qwen3.5 rendering of every branch, and every
scored answer. A difference there is a different decider.

```dart
// Remote: a local simple-jev, or the hosted API.
final remote = HttpJevClient(model: 'Qwen/Qwen3.5-4B');

// Local, no Python: Dart renders the prompt, Ollama returns the logprobs.
final local = LogitJevClient(
  logits: OllamaJevLogits(model: 'qwen3:8b', renderer: JevChatFormat.qwen3.renderer),
);  // template: v1-noul-decimal (default)
await local.warmUp();

// Or from a config block, the same one the benchmark uses.
final fromYaml = JevConfig.clientFromJson({'backend': 'ollama', 'model': 'qwen3:8b'});
```

## Asking

```dart
final questions = JevQuestionSet();
final route = questions.addEnum('route', JevChoice.ofEnum(Route.values,
    instructions: 'Which model should handle the task?',
    describe: (r) => switch (r) { Route.local => 'a small model is enough',
                                  Route.cloud => 'needs a much stronger model' }));
final done = questions.add('done', const JevNoul(instructions: 'The goal is achieved.'));

final response = await client.decide(JevRequest.of(state: JevState.text(task), questions: questions));
Route r = route.valueIn(response);         // typed, no string compare
double truth = response.get(done).noul;    // a JevNoulAnswer, statically
```

Several questions about one state go in one request, because the branches
share the prefix. On a local backend with a prefix cache, only each
question's suffix is evaluated again.

## Ready-made decisions

| class | question | use |
|---|---|---|
| `JevRouter<R>` | choice over an enum | model routing, queue/handler selection |
| `JevCompletionCheck` | noul "the goal holds in the state" | stop an agent from finishing too early |
| `JevSelector` | noul per candidate | tool preselection, relevance filtering, reranking |
| `JevGuard` | noul "the action is wanted and safe" | allow / confirm / deny before acting |

Each one comes with English and German texts and returns the full
`JevResponse` next to its verdict, so latency, tokens and the answering model
stay recordable.

## Multilingual

The v1 frame is English. That is part of the contract and stays that way.
The instructions, candidate descriptions and rubrics are the caller's, and
`JevLanguagePolicy` picks their language:

- `JevLanguagePolicy.fixed('de')` always asks in German;
- `JevLanguagePolicy.matchState()` asks in the state's language
  (`detectLanguage`, a function-word detector that ignores quoted names),
  falling back to English.

Texts are `JevLocalized` values with an explicit fallback. Labels never carry
language: the model reads `A`–`Z`, `0`–`9` and `1`–`9`, which are single
tokens in every multilingual vocabulary. Canonical JSON keeps umlauts and
other non-ASCII text as written, like the reference's `ensure_ascii=False`,
instead of turning them into `\u00fc` escapes.

## Templates, and the noul finding

`JevTemplate.v1` is the reference exactly. `JevTemplate.v1NoulDecimal`
changes one thing: a noul's answer prefix ends in `0.`.

v1 asks for "the probability … from 0.1 to 0.9" and then reads the digits
`1`–`9` straight after `{"answer": `. A model that follows the instruction
starts with `0`. Measured on 2026-09-23:

- qwen3 1.7b/4b/8b and llama3.1:8b put ≥ 99.9 % of the mass on `0`;
- simple-jev's own Qwen3.5-0.8B gives 0.01 for every probe, true or false.

With `0.` prefilled, qwen3:8b gets all five probes right at 0.01/0.99, so
`v1-noul-decimal` is the default of `LogitJevClient` and of `JevConfig`'s
local backends. Pass `JevTemplate.v1` (or `template: v1`) to reproduce the
reference exactly, e.g. to compare against simple-jev. Choices and scores are
the same under both templates. `metadata.template_version`
records which one produced a number.

## Limits

- **Ollama reports the top 20 tokens only.** A question with more than 20
  labels is refused (`JevUnsupported`); split it with `judgeEach`. A label
  outside the top 20 gets a floor below the lowest reported value and is
  listed in `missing_labels`. If no label appears at all, that throws
  `JevLabelsUnreadable`; the usual cause is a wrong chat format.
- **Logit backends read text only.** Image parts are refused rather than
  dropped; send them to a multimodal System One server via `HttpJevClient`.
- **Choice descriptions are text.** The reference also accepts JSON
  objects as descriptions; `JevRequest.fromJson` serialises them to strings.
- **On the web**, JavaScript numbers do not tell `1.0` from `1`, so a
  float-valued JSON state renders as `1` in the prompt.

## Tests

```sh
fvm dart test                                                # unit + golden
JEV_OLLAMA_MODEL=qwen3:8b fvm dart test -t live --run-skipped  # against Ollama
build/jev/.venv/bin/python tool/jev_golden.py                # regenerate fixtures
```
