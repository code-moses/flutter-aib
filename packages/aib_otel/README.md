# aib_otel

Episode traces as OpenTelemetry spans, following the GenAI semantic
conventions: `aib.episode` → `invoke_agent` (one per decision) →
`execute_tool` (its envelope). One trace per episode.

```sh
aib run … --otel http://localhost:4318/v1/traces [--otel-capture-content]
```

The JSONL trace stays canonical; this is a second reader of the same events.
Payloads are left out unless asked for.

Caveats: the Dart SDK (`dartastic_opentelemetry`, pinned) is not yet an
official OpenTelemetry SDK, and the GenAI conventions are experimental —
`aib.semconv_as_of` on every episode span says when the names were read.
