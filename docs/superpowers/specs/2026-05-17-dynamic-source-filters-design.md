# Dynamic Source Filters Design

## Goal

Add Suwayomi source filter support for source search so readers can use source-specific fields such as tags, include/exclude switches, text fields, and sort choices before choosing manga.

This is a parity feature with Suwayomi WebUI source browse. Scope is intentionally search-only because Suwayomi Server applies `filters` only to `fetchSourceManga` requests with `type = SEARCH`.

## Current State

The plugin can browse Popular, Latest, and source-specific Search pages. Source manga loading already runs through `suwayomi/browse/source_manga_worker.lua`, so remote source requests stay off the KOReader UI thread.

`suwayomi/api/queries.lua` already passes `options.filters` through to `FetchSourceMangaInput`, but no caller builds filter changes yet. There is no query/parser path for source filter schema, no KOReader UI for dynamic filters, and no persistence for current source filter drafts.

The existing scanlator filter is a different feature. It is applied after manga selection, when chapters are loaded. It persists per manga in `manga_scanlator_filters`, validates that the saved scanlator still exists in the current chapter list, and scopes chapter selection, first-unread, and download actions to visible chapters.

## Product Behavior

Selecting a remote source opens the source mode menu:

- `Popular`
- `Latest`, when supported
- `Search`
- `Source filters`

`Search` remains the fast text-search prompt.

`Source filters` opens a loading screen while the plugin fetches filter schema for the current source. If the server or source does not expose filters, the user sees a short failure or empty-state message. If filters exist, the plugin shows a KOReader-native filter editor with:

- checkbox filters as on/off rows
- tri-state filters as `Ignore`, `Include`, and `Exclude`
- select filters as choice menus
- text filters as input prompts
- sort filters as sort choice plus ascending/descending action
- group filters as nested sections
- header and separator filters as non-selectable labels

The filter editor title menu includes:

- `Apply filters`
- `Reset filters`
- `Search text`
- `Suwayomi home`

`Search text` lets the same editor submit a text query plus filter changes. Applying filters starts source manga loading with `type = SEARCH`, the current query text or an empty query, page `1`, and the selected filter changes. The results screen title uses `Search: <query>` when query text is present and `Filter` when query text is empty. `Next page`, `Previous page`, and retry keep the same query and filters.

## Source Filter Data Model

Add a small normalized runtime shape under a new source-filter module. The local shape should match server concepts while staying easy to render and test:

```lua
{
    type = "CheckBoxFilter",
    name = "Completed",
    default = false,
}
```

Supported filter types:

- `HeaderFilter`
- `SeparatorFilter`
- `SelectFilter`
- `TextFilter`
- `CheckBoxFilter`
- `TriStateFilter`
- `SortFilter`
- `GroupFilter`

Selected values are stored as filter draft entries:

```lua
{
    position = 4,
    type = "checkBoxState",
    state = true,
}
```

Group entries keep the parent position and nested child position:

```lua
{
    position = 7,
    group_change = {
        position = 2,
        type = "triState",
        state = "INCLUDE",
    },
}
```

Before network submit, the source-filter module converts drafts into Suwayomi `FilterChange` objects:

```lua
{
    position = 7,
    groupChange = {
        position = 2,
        triState = "INCLUDE",
    },
}
```

Unknown or unsupported filter types render as read-only rows and are omitted from submitted filter changes.

## API Design

Extend `suwayomi/api/queries.lua` with a source browse query that fetches one source and its filter schema:

```graphql
query GET_SOURCE_FILTERS($id: Long!) {
  source(id: $id) {
    id
    displayName
    name
    filters {
      ... on HeaderFilter { name }
      ... on SeparatorFilter { name }
      ... on SelectFilter { name values default }
      ... on TextFilter { name default }
      ... on CheckBoxFilter { name default }
      ... on TriStateFilter { name default }
      ... on SortFilter { name values default { index ascending } }
      ... on GroupFilter { name filters { ...same filter fragments... } }
    }
  }
}
```

The exact scalar type for `source(id:)` should follow the current server schema used by integration tests. If older servers reject `filters`, the API facade returns `ok = false` with `Source filters are not supported by this server.`

`fetchMangaForSource` continues using the existing `FetchSourceMangaInput` path. Only `SEARCH` requests include `filters`; Popular and Latest request builders do not attach filter changes.

## Persistence

Persist source filter drafts by server/auth scope and source ID. This mirrors source cache scoping and avoids leaking filters between different Suwayomi servers or credentials.

Suggested setting key:

```lua
source_filter_drafts = {
    [scope_key] = {
        [source_id] = {
            query = "",
            filters = { ...draft entries... },
        },
    },
}
```

Draft persistence is convenience state, not user data required for correctness. If a saved draft no longer matches a source filter schema, invalid positions or incompatible types are dropped on load.

Saved searches are a follow-up feature, not part of this first implementation. The design keeps query-plus-filter state shaped so saved searches can later persist `{ query, filters }` per source, WebUI-style.

## Module Boundaries

New runtime modules:

- `suwayomi/source_filters.lua`: pure normalization, draft validation, default comparison, and `FilterChange` building.
- `suwayomi/browse/source_filter_worker.lua`: subprocess-safe worker for fetching one source's filter schema.

Existing modules to extend:

- `suwayomi/api/queries.lua`: build source filter schema query.
- `suwayomi/api/parsers.lua`: parse filter schema defensively.
- `suwayomi/api.lua`: expose `fetchSourceFilters`.
- `suwayomi/settings.lua`: persist source filter drafts.
- `suwayomi/client/source_manga.lua`: add source filter flow, carry filters through search result paging, and keep filters in retry callbacks.
- `suwayomi/browse/source_manga_worker.lua`: normalize `browse_options.filters` and pass them to API request options for `SEARCH`.
- `suwayomi/ui/browse.lua`: render the source filter editor using native KOReader menus/dialogs.
- `docs/ARCHITECTURE.md`: update Browse/API/settings ownership after implementation.

The feature must not add top-level runtime files or move behavior into `main.lua`.

## Scanlator Filter Interaction

Source filters and scanlator filters remain independent.

Source filters run before manga selection:

```text
Source -> Search query + source filters -> manga results
```

Scanlator filters run after manga selection:

```text
Manga -> loaded chapters -> scanlator filter -> visible chapter actions
```

Opening manga from filtered search results uses the same manga action and chapter-loading flow as any other browse result. When chapters load, `setCurrentMangaChapterContext()` still calls `getValidMangaScanlatorFilter()`, restores only a valid saved scanlator, and clears stale values. Source filter state does not read or write `current_scanlator_filter`.

Chapter selection, first-unread, download-next, keep-downloaded, mark-read, and delete actions continue to use `getVisibleChapters()`. A source filter can change which manga the user finds, but it must not change which chapters are visible once a manga is open.

Regression tests should prove:

- applying source filters does not change `current_scanlator_filter`
- opening a manga after filtered source search restores the saved scanlator filter normally
- clearing source filters does not clear per-manga scanlator filters
- scanlator-filtered chapter actions still operate only on visible chapters

## Error Handling

Filter schema fetch:

- network failure: keep editor screen open with retry row
- unsupported server schema: show `Source filters are not supported by this server.`
- source with no filters: show `This source has no filters.`
- malformed filter node: ignore that node and log a redacted parse event; fail only when the entire filter list is unusable

Filter submit:

- invalid draft entries are dropped before submit
- server-side filter errors show the same source-search failure screen with retry and edit-filter actions
- retry keeps query and filter state
- edit-filter returns to the editor with the failed draft intact

## Testing

API specs:

- source filter query includes supported filter fragments
- parser normalizes each supported filter type
- parser handles group filters
- parser rejects or omits malformed filter nodes consistently
- optional `filters` schema failure produces the unsupported-server message
- manga query still includes filters when request options include them

Source filter pure module specs:

- default values produce no unnecessary changes
- checkbox, tri-state, select, text, and sort drafts become valid `FilterChange` tables
- group drafts become nested `groupChange` tables
- invalid positions and mismatched types are dropped

Settings specs:

- drafts persist by source ID and server/auth scope
- stale drafts are normalized on load
- clearing one source draft does not clear another source draft

Client/worker specs:

- `Source filters` fetches schema in a worker and renders editor rows
- applying filters starts source manga load with `type = SEARCH`, `query`, and `filters`
- Popular and Latest never submit filters
- next/previous page keep query and filters
- retry/edit-filter preserve failed filter drafts

Scanlator regression specs:

- source filter flow does not mutate `current_scanlator_filter`
- saved scanlator filter restores after opening manga from filtered results
- chapter actions still use visible scanlator-filtered chapters

Manual verification:

- MangaDex or another filter-heavy source can apply at least one tag/filter and return results
- filtered search can page forward and back
- opening a result still shows normal chapter list and scanlator filter behavior
- older server without source filter schema shows a clear unsupported message

## Out Of Scope

- Applying source filters to Popular or Latest
- Server-side downloads
- Source preference/configuration editing
- Saved search management
- Global search filters
- Migration flows
- Any change to per-manga scanlator filter semantics

## Risks

Dynamic filters are source-defined and uneven. Some sources expose many filters, nested groups, or labels that are awkward on e-ink. Keep first implementation native, list-based, and forgiving rather than trying to mirror WebUI layout.

Server schema drift is likely across Suwayomi versions. The API layer should treat missing filter schema as feature absence, not a fatal browse failure.

Filter drafts can go stale when extensions update. Draft validation must compare positions and expected types against the latest schema before submit.
