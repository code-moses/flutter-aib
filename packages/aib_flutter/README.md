# aib_flutter — Flutter environment adapter (Layer 3)

Implements the `BenchmarkEnvironment` port for Flutter apps. All
Flutter-specific functionality of the benchmark lives exclusively in this
package (spec §1.1); `aib_core` never sees widgets or semantics trees.

## Envelope key conventions (v1)

These keys are **conventions between the reference agents and this adapter**
(spec §4.4) — versioned here, not in the core, not in the wire protocol.
Environments answer unknown keys with a structured `unsupported`.

### SemanticsBridge

| key | kind | payload | result |
|---|---|---|---|
| `semantics.tree` | observe | `{}` | `{tree, nodeCount, prunedCount}` |
| `semantics.tap` | act | `{nodeId}` or `{label}` | `{nodeId, action}` |
| `semantics.setText` | act | `{nodeId|label, text}` | `{nodeId, action, committed}` |
| `semantics.scroll` | act | `{nodeId|label, direction: up\|down\|left\|right}` | `{nodeId, action}` |
| `semantics.showOnScreen` | act | `{nodeId}` or `{label}` | `{nodeId, action}` |

The serialized tree is pruned to interactive and labelled nodes (children of
pruned nodes are hoisted); nodes carry `label`, `tooltip`, `value`, `hint`,
`actions`, `flags`, `rect`, `onScreen`. Node ids are the engine-stable semantics node ids
of the current tree; labels may be used instead — `{label}` matches a node's
`label` *or* `tooltip` (icon buttons expose their accessible name as
tooltip). Ambiguous labels are rejected with `ambiguous_label` listing the
candidate ids.

`onScreen` says whether the node's global bounds overlap the viewport. A
scrollable serializes every *built* child, so without it an agent cannot tell
the row it can tap from the one below the fold; `semantics.showOnScreen`
brings such a node into view (more reliable than guessing a scroll distance).

`semantics.setText` focuses the field, sets the text, and then **releases the
focus**, because a form field commonly reports its value to the form only when
it loses focus. Leaving the field focused changes what is on screen and nothing
else: the tree reports the new text, the result is `ok`, and the app's own
value map never hears about it. No sequence of semantics actions can produce
the blur — `SemanticsAction.tap` is not a pointer event, so an `onTapOutside`
handler never runs — so the bridge does it, and reports `committed`. The cost
is that an overlay tied to the field's focus closes with it; an agent that
wants one taps the field again.

Error codes: `no_semantics`, `not_found`, `ambiguous_label`,
`unsupported_action`, `bad_payload`.

### IntentBridge

| key | kind | payload | result |
|---|---|---|---|
| `intents.catalog` | observe | `{}` | `{intents: [{name, description, kind, paramsSchema, metadata?}]}` |
| `intents.invoke` | act | `{intent, params}` | `{result}` |

Any result may additionally carry `capabilities: {added?, removed?}` — see
below.

Error codes: `unknown_intent`, `intent_rejected` (domain validation),
`bad_params` (the parameters do not match the intent's `paramsSchema`).

Three things about the catalog are worth stating plainly, because each of
them is a decision rather than an implementation detail:

- **`kind` is the environment's answer, not the agent's.** An intent declares
  whether invoking it changes the app. `FlutterEnvironment` settles frames
  and the metric layer counts steps based on *this*, never on the kind the
  agent declared on the envelope — the agent's declaration is kept only so
  `kind_integrity_violations` can compare the two. Otherwise an intent that
  mutates while claiming to observe would skip frame settling and the next
  observation would read a half-rendered tree.
- **`metadata` is app-owned and the framework never branches on it.** It is
  published verbatim. SYSco Mobile+ carries `policy`,
  `requiredPermissions`, `requiresConnection`, `scopeId`, `menu` and
  `defaultShortcut` there; another app will carry something else. Keeping
  these out of `AibIntent` is what stops one product's domain model becoming
  a framework concept.
- **The catalog is dynamic.** Construct the bridge with a `catalogProvider`
  and it is called on every `intents.catalog` observation, so the catalog
  reflects the page the user is on, filtered by their permissions, at the
  moment it is read. `register()` still works and is what the todo app uses.
- **A change is announced, not left to be discovered.** When the in-scope set
  differs from what the agent was last told, the *next* result — of any
  envelope, not only `intents.invoke` — carries
  `capabilities: {added: [<catalog entries>], removed: [<name>]}`, once. An
  agent cannot be expected to re-observe a catalog it has no reason to suspect
  has changed, and one that does not re-observe cannot reach a capability
  mounted by an open form at all. ADR 0013 has the run that proved it.

Parameters are validated against `paramsSchema` before the handler runs. The
validator is a documented subset — types, `required`, `enum`, nested objects,
array `items`, numeric and length ranges, `additionalProperties: false` — and
ignores `$ref`, `allOf`/`anyOf`, `format` rather than half-implementing them.
Its job is to keep a model's schema violations out of `handler_error`, where
they would be indistinguishable from a genuine app failure.

### UserBridge

| key | kind | payload | result |
|---|---|---|---|
| `user.ask` | act | `{type: confirm\|choice\|pick\|text, prompt, options?, metadata?}` | `{question, answer}` |

Error codes: `bad_params`, `cancelled` (the user declined or dismissed),
`no_scripted_answer` (the benchmark's scripted user had no answer),
`ask_failed`.

`user.ask` is declared `act` — asking costs a step, which is the pressure
that stops an agent interrogating the user instead of reading the app. It is
also declared `blocksOnUser`, which changes two things: the engine gives it
its own timeout instead of racing a person against the agent's wall-clock
budget, and the time spent waiting is reported as `EnvelopeResult.userWaitMs`
and excluded from `wall_clock_ms`. Without that, an agent that correctly
stops to ask would score worse than one that guessed wrong. Because it
changes no app state, the metric layer keeps `user.*` out of
`redundant_action_ratio` and out of `path_efficiency`'s denominator, and
reports it as `clarification_count` / `confirmation_count` / `user_wait_ms`
instead.

`ScriptedUserAnswerer` is the benchmark's stand-in for a person: answers come
from the task fixture, confirmations default to yes, and a question the
fixture does not cover fails with `no_scripted_answer` rather than a silent
default — a default would let an agent pass a task by asking something the
fixture never anticipated, with nothing in the metrics to show for it. The
refusal is worded for the agent ("nobody is available to answer, decide or
abort"); which fixture entry is missing belongs in the run report, and
`ScriptedUserAnswerer.unanswered` is where it comes from.

The question echoed back in the result carries no id. It is a per-ask counter,
so including it made two identical refusals differ by one character — enough
to hide a loop from the engine's no-progress guard, which is what happened in
the first `sysco_v1` run.

### GenUiBridge

| key | kind | payload | result |
|---|---|---|---|
| `data.context` | observe | `{}` | app-defined data document |
| `genui.catalog` | observe | `{}` | `{catalogId, components, rules?}` |
| `genui.render` | act | `{messages}` (A2UI v0.9) | `{accepted: true, surfaces}` |

The payload is a batch of [A2UI v0.9](https://a2ui.org) messages — the
protocol `package:genui` renders — applied in order; a surface takes a
`createSurface` and an `updateComponents` whose components include one with
id `root`. The bridge validates the batch structurally (`bad_payload`,
`invalid_surface`): message shape, the catalog id, component types and their
properties against the host's `GenUiCatalog`, and the presence of a root.
Content quality is judged from the trace via `artifactRubric` (LLM-as-judge,
k=3 majority).

`GenUiCatalog` maps each component type to the JSON schema of its
properties; `genui.catalog` publishes both so the agent does not have to
guess, and the render check enforces them. A host that declares only names
(the default) gets the name check alone. Property checking is what catches
the document that is structurally perfect A2UI and still renders as an error
box — a `Card` handed `children` where it wanted `child` — which is the case
where the rubric would otherwise read a surface the app never drew. See ADR
0012.

### VisionBridge (M6 validation)

| key | kind | payload | result |
|---|---|---|---|
| `screen.capture` | observe | `{}` | `{image (base64 PNG), format, width, height, scale}` |
| `pointer.tap` | act | `{x, y}` | `{tapped: true, x, y}` |
| `pointer.drag` | act | `{fromX, fromY, toX, toY}` | `{dragged: true}` |
| `pointer.text` | act | `{text}` | `{typed: true}` |

Coordinates are logical pixels of the captured image's space. Screenshot and
gestures are host callbacks (`RenderRepaintBoundary.toImage` under
`flutter_test`, platform APIs on a device); `pointer.drag`/`pointer.text` are
only published when the host supplies them, everything else answers
`unsupported`. This bridge exists for the *external* VisionAgent of the
validation chapter (spec §7, M6) — deliberately not part of the core
strategy comparison.

Error codes: `bad_payload`.

## App integration

```dart
final environment = FlutterEnvironment(
  environmentId: 'todo_app',
  settle: () => pumpUntilSettled(),          // host-specific frame pumping
  onReset: (fixture) => store.seed(fixture), // deterministic fixture reset
  onStateQuery: (q) => store.answer(q),      // ground-truth queries
  fingerprint: () => store.fingerprint(),    // enables state-diff metrics
);
SemanticsBridge().install(environment);
IntentBridge()..registerAll(appIntents)..install(environment);
```

A shipping app wires a few more of these:

```dart
final environment = FlutterEnvironment(
  environmentId: 'sysco',
  settle: () => pumpUntilSettled(),
  // Resolves FixtureRef.path. This package is dart:io-free so an app can
  // depend on it; a widget-test harness passes a File read here, an
  // on-device harness an asset read.
  fixtureLoader: (path) async => jsonDecode(File(path).readAsStringSync()),
  // Cap a single result. Without it one unbounded list query can exceed the
  // context window, and the failure surfaces three turns later as an abort
  // that looks like the agent's fault.
  maxResultBytes: 32 * 1024,
);
IntentBridge(catalogProvider: () => registry.snapshot()).install(environment);
UserBridge(answerer: showDialogForQuestion).install(environment);   // production
UserBridge(answerer: scriptedAnswerer.call).install(environment);   // benchmark
```

## Fixtures that are not a single JSON file

The suite loader inlines fixture JSON, but an app's fixture is often a
configuration *directory* plus overrides. The convention (no loader change
needed) is to put the reference in the fixture data and let the environment
resolve it:

```yaml
fixture:
  id: vendoc_demo
  data:
    config: vendoc_demo          # directory the app knows how to load
    overrides: {...}             # per-task seed adjustments
    userAnswers: {...}           # answers for the ScriptedUserAnswerer
```

`onReset` receives that map and does whatever loading the app needs.

## What ships and what does not

This package is `dart:io`-free and safe to depend on from an application, so
the bridges an app registers in `lib/` are the same bridges the benchmark
drives — the shipped agent is the measured agent. `tool/check_app_safe_entrypoints.dart`
enforces the `dart:io`-freeness in CI; do not add an import without running
it.

