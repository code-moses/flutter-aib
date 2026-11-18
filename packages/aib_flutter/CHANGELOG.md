## 1.1.0

- `GenUiBridge.prepare`: an optional host step between validation and display,
  e.g. to build a chart a component names by its data. Its result is added to the
  render result; a `FormatException` rejects the batch.
- `intents.describe` results are never capped.
- A2UI 1.0: `GenUiCatalog.protocolVersion` (`v0.9` by default, or `1.0`),
  `GenUiCatalog.basicNoAssetsV1` and `basicV1CatalogId`. The bridge checks each
  message's version against the catalog and publishes it in `genui.catalog` and
  in the `genui.render` payload schema.

## 1.0.0

- First published release.
