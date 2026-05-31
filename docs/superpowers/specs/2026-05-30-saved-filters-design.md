# Saved Filters Design

## Status

Design only. This document intentionally does not implement the feature.

## Context

The roadmap currently names this work as "Save source searches" and suggests a
plugin-local first slice. That storage guidance is stale. Suwayomi WebUI already
persists saved source searches in server-side source metadata, so the plugin
should not create a parallel local store.

WebUI uses:

- `webUI_savedSearches` on source metadata. WebUI derives this from app metadata key `savedSearches` plus the `webUI_` metadata prefix.
- Data shape `Record<string, { query?: string; filters?: IPos[] }>` where each
  key is the user-provided saved-search name.
- GraphQL source metadata reads through source `meta`.
- GraphQL source metadata writes through `setSourceMetas`.
- Session/local browser storage only for active UI state, not saved entries.

The plugin should present the feature as **Saved filters**. In the KOReader
source-browse flow, a saved entry can contain both search text and filter state,
so "Saved search" is less accurate.

## Goals

- Let users save, apply, and delete named source browse filter presets.
- Share saved entries with WebUI by using the existing server-side source
  metadata shape.
- Keep saved entries scoped by source, as WebUI does.
- Preserve current source-filter draft behavior while adding saved entries as a
  separate reusable preset layer.
- Keep all plugin-authored UI strings translatable.

## Non-Goals

- Do not add plugin-local saved-filter persistence for this feature.
- Do not add a sync/cache layer unless server metadata proves unavailable in a
  future compatibility pass.
- Do not change how active source filter drafts are stored locally.
- Do not rename WebUI metadata keys or require WebUI changes.
- Do not add global saved filters across sources.

## User Experience

Saved filters should live in source-specific browse/search flows, close to the
existing Source filters editor:

- **Save filter** stores the current search text plus current filter draft under
  a user-entered name.
- **Saved filters** opens the source's saved entries.
- Selecting an entry applies its query and filters, then starts source search.
- Deleting an entry requires confirmation.
- Empty saved-filter list shows a short empty state instead of raw metadata.
- Duplicate names overwrite the previous saved entry only after confirmation, or
  are blocked with a clear message. The implementation plan should choose one
  behavior explicitly before coding.

The feature should work for text-only searches, filter-only searches, and mixed
query-plus-filter searches.

## Data Model

Use WebUI-compatible source metadata key `webUI_savedSearches`; the JSON value still has the saved-search map shape:

```lua
webUI_savedSearches = {
    ["Name"] = {
        query = "frieren",
        filters = {
            { position = 1, type = "checkBoxState", state = true },
        },
    },
}
```

Plugin internals should normalize saved entries through the existing source
filter draft shape before applying them:

- `query` becomes a string, defaulting to `""`.
- `filters` becomes a normalized source filter draft list.
- Invalid saved entries are ignored instead of crashing the menu.

When applying a saved filter, build GraphQL `FilterChange` values from the
current source filter schema. If the source schema changed and saved filters no
longer match, skip invalid filter entries and keep applying valid ones.

## API Design

Add public API facade support for source metadata:

- Query source metadata needed for `webUI_savedSearches`.
- Parse `source.meta` into key/value metadata entries.
- Build `setSourceMetas` mutation for replacing `webUI_savedSearches`.
- Return user-facing failures without exposing raw server metadata dumps.

The API layer should remain WebUI-compatible by storing `webUI_savedSearches` as a
JSON string metadata value. If server metadata fields are unavailable on older
servers, report that saved filters are unsupported instead of falling back to
local persistence.

## Client Flow

`suwayomi/client/source_manga.lua` should own orchestration:

- Fetch saved filters for the selected source when the user opens saved-filter
  actions.
- Save current draft through server metadata.
- Delete selected entries through server metadata.
- Apply selected entries through the existing source search path.
- Keep stale-result guards consistent with existing source filter and source
  manga loading.

`suwayomi/ui/browse.lua` should own UI surfaces only:

- Saved-filter list menu.
- Save-name prompt.
- Delete confirmation.
- Menu rows and action labels.

No UI module should perform GraphQL calls or metadata parsing.

## Translations

All new plugin-authored text must use the existing gettext wrapper. Required new
msgids are expected to include:

- `Saved filters`
- `Save filter`
- `Save current filter`
- `Filter name`
- `No saved filters.`
- `Apply saved filter`
- `Delete saved filter`
- `Delete saved filter "%1"?`
- `Saved filter saved.`
- `Saved filter deleted.`
- `Could not load saved filters.`
- `Could not save saved filter.`
- `Could not delete saved filter.`
- `Saved filters are not supported by this server.`

Do not translate source names, saved-filter names, query text, filter option
labels from the server, or raw metadata keys.

Run the l10n update/check workflow after implementation changes:

- `bash ./scripts/update-l10n.sh`
- `bash ./scripts/check-l10n.sh`

## Testing

Implementation should add focused coverage for:

- API request builders for source metadata query and `setSourceMetas` mutation.
- API parsers for valid, missing, malformed, and unsupported source metadata.
- Saved-filter normalization for valid entries, invalid entries, empty names,
  and schema drift.
- Client flow for save, apply, delete, duplicate-name behavior, and unsupported
  server metadata.
- UI flow for saved-filter list, save prompt, delete confirmation, and empty
  state.
- L10n extraction for every new plugin-authored string.

Docs-only spec verification for this commit is a diff review. Implementation
verification should also run:

- `rtk luacheck --codes spec suwayomi main.lua _meta.lua`
- `rtk busted spec`
- `bash ./scripts/check-l10n.sh`
- `rtk git diff --check`

## Open Decisions For Implementation Plan

- Whether duplicate saved-filter names overwrite after confirmation or are
  blocked. Recommendation: confirm overwrite, matching user intent to update a
  named preset.
- Whether saved filters are loaded lazily from the source mode menu or from
  inside the source filter editor. Recommendation: load lazily from a
  source-filter action to avoid extra network work in normal browsing.
- Whether WebUI literal "Saved searches" should be mirrored anywhere.
  Recommendation: no. Use "Saved filters" in plugin UI while keeping metadata
  key compatibility.
