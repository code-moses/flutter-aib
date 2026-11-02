# ADR 0012 — `genui.render` speaks A2UI, not a schema of our own

Date: 2026-09-06 · Status: accepted

## Context

The generative-UI strategy rendered the **AIB surface schema v1**: one JSON
document, `{type, title, sections: [{heading, items: [{title, subtitle,
badge}]}]}`. It was written to be minimal so that a rubric could be checked
against it, and for the todo reference app — where the surface is a list of
todos and the host renderer is forty lines — that was the right size.

SYSco Mobile+ is where it stopped being the right size. The app renders v1 as a
`Card` of `ListTile`s and can render nothing else, because nothing else is in
the schema: no grouping that is not a heading, no emphasis, no action but the
one deep link the app bolted on as an item field. An assistant that answers
"zeig mir die offenen Anforderungen" with a flat list is not showing the
capability the strategy exists to demonstrate.

Meanwhile Flutter's own `package:genui` renders [A2UI](https://a2ui.org): a
message protocol with a component catalog, a data model, and bindings, with a
tested widget set behind it. Adopting it as the app's renderer is
straightforward. Adopting it *only* as the app's renderer is not: the benchmark
judges the `genui.render` envelope from the trace, so the app would render A2UI
while the rubric read surface v1, and the shipped surface and the measured
surface would be two different documents. That divergence is the single thing
the environment-is-the-instrumentation design exists to prevent — the whole
argument for measuring through the product's own interface is that there is
only one interface.

So the schema and the renderer had to move together, and the plan reserved this
for a point where the suites are re-baselined anyway.

## Decision

`genui.render` carries a batch of A2UI v0.9 messages,
`{messages: [{version, createSurface|updateComponents|updateDataModel|
deleteSurface}, …]}`, applied in order. Surface schema v1 is gone; there is no
translation layer and no dual support.

- It is a **batch**, not a message, because a surface needs at least two
  messages to exist and an agent billed one act-envelope per message would pay
  three steps for one answer.
- The host declares a `GenUiCatalog` — catalog id, component types with the
  JSON schema of each one's properties, its own rules — which `genui.catalog`
  publishes as an observation and which `genui.render` enforces. A component
  the renderer cannot draw is now an error the agent can read, where before it
  would have been a blank box.
- `GenUiBridge` validates only what fails *silently* otherwise: message shape,
  the catalog id, unknown component types, missing required properties, a
  surface addressed before it was created, a batch with no `root`. Everything
  else is `package:genui`'s business at render time, and content is the
  rubric's.

  The property half was added after the first live Sonnet run, which produced
  a batch that passed every structural check and would have rendered as two
  error boxes: its root `Card` carried `children` where a Card takes one
  `child`, and its `Button` carried `text` where it takes a `child`. Nothing
  in the trace said so. That is precisely the divergence this ADR exists to
  close, so the check that closes it belongs here rather than in the app.
- The framework does not depend on `package:genui`. The bridge is protocol
  only; the host brings its renderer. `aib_flutter` stays a benchmark adapter
  rather than acquiring a widget set, and a host on another renderer — or on
  A2UI over the wire — is still a host.

Prompts and agent ids move with it: `genui_v2` and `hybrid_v2`, both frozen
alongside their predecessors, and the tools are `observe_ui_catalog` and
`render_ui`.

## Consequences

- **Every suite that judges a rendered surface is re-baselined.** The artifact
  the judge reads changed shape, the agent ids changed, and the sysco suite
  gained a task (`genui.render.articleKinds`) that exercises the strategy
  end to end. No number from before this ADR is comparable with one after it,
  which is the reason it landed before the first run anyone intends to quote.
- The app renders the same document the rubric reads. `AssistantGenUiSurface`
  hands the trace's messages to a `genui` `SurfaceController` verbatim.
- The surface is interactive for the first time — buttons, choice pickers,
  text fields — which raises a question surface v1 could not: what a generated
  control is allowed to *do*. The answer for now is deliberately narrow: the
  app handles one action, `app.open` with a `route`, which is the deep link
  surface v1 had as an item field. Everything else reaches the host as an
  unhandled event and is ignored.
- The cost is a heavier prompt. A2UI needs the catalog explained; surface v1
  fitted in four lines. `observe_ui_catalog` keeps it off the prompt and out
  of the episodes that never render anything, at the price of one observation
  in the ones that do.
