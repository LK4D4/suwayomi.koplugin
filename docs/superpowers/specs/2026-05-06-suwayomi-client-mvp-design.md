# Suwayomi Client MVP Design

## Goal

Turn the current KOReader Suwayomi downloader into a small, useful Suwayomi client without trying to clone Suwayomi-WebUI.

The MVP should make remote sources usable from an e-ink device by adding the missing client layer around the already-solid download and read-state flow:

1. open the Suwayomi library
2. choose what to read next
3. refresh manga/chapter state
4. search remote sources
5. add useful manga to the library
6. keep the current KOReader-local download workflow

The intended result is a KOReader-native reading client, not a general Suwayomi administration UI.

This also means the plugin needs a clearer filesystem model than the original Local-source-only downloader had. Once multiple remote sources are involved, manga titles are not globally unique, and downloaded chapters should be grouped by source.

## Current State

Implemented already:

- Basic Auth login and server URL persistence.
- Source listing with language filtering and cached source refresh.
- Source -> manga -> chapter browsing.
- Chapter page fetching and local `.cbz` creation.
- KOReader-local persistent download queue with recovery.
- Chapter actions: open, download, delete from device, mark read/unread, mark selected chapters, mark previous chapters read.
- Bulk policies: download next unread, keep next unread downloaded, delete read chapters from device.
- Read-state reconciliation from Suwayomi, the plugin ledger, and KOReader sidecar metadata.
- Background retry for pending read/unread sync.

The strongest existing behavior is the reading loop after the user has already found a manga. The weakest behavior is the client loop before that point: library navigation, source search, pagination, add/remove library, and source-specific discovery.

## Product Direction

### Recommended direction: library-first client

The plugin should prioritize the everyday device workflow:

```text
Open Suwayomi -> Library -> Manga -> First unread / Download next unread / Keep next unread
```

Discovery should exist, but it should be secondary:

```text
Open Suwayomi -> Browse/Search source -> Manga -> Add to library / Open chapters
```

This matches KOReader's strengths. KOReader already provides a good reader and the plugin already provides local chapter files. The missing value is deciding what belongs on the device and what should be read next.

### Alternatives considered

1. **Discovery-first remote browser**
   - Pros: makes new remote sources immediately more useful.
   - Cons: delays the main reading loop and forces filter complexity early.

2. **WebUI-lite clone**
   - Pros: familiar feature checklist for Suwayomi users.
   - Cons: too much surface for KOReader menus, high implementation cost, and duplicates reader features KOReader already owns.

3. **Downloader-only polish**
   - Pros: smallest scope and low risk.
   - Cons: keeps remote sources awkward because users still need another client to manage library and discovery.

The MVP should use the first option, with enough discovery to add manga without leaving KOReader.

## Live Server Findings

The live Suwayomi instance confirms the MVP can be implemented through GraphQL with the current auth model.

Useful API capabilities:

- Library manga can be queried through `mangas` with `inLibrary` filtering.
- Library manga expose `unreadCount`, `downloadCount`, `firstUnreadChapter`, `latestFetchedChapter`, `source`, and `categories`.
- Categories are queryable and can provide a simple library grouping model.
- Source browsing supports `POPULAR`, `LATEST`, and `SEARCH` through `fetchSourceManga`.
- Source manga results expose `id`, `title`, `inLibrary`, `initialized`, and thumbnail URLs.
- Manga library membership can be changed through `updateManga` with `patch.inLibrary`.
- Manga and chapters can be refreshed through `fetchManga` and `fetchChapters`.
- Source filters are typed filter trees and are applied through positional `FilterChangeInput` values.

The source filter model is powerful but expensive for a KOReader MVP. The first client slice should support search query and browse mode, then defer full filter editing.

## MVP User Flows

### 1. Open library

Add a new top-level menu entry:

```text
Suwayomi
  Library
  Browse sources
  Search a source
  Sync read state now
  Setup...
```

`Library` should be the primary entry point once credentials exist.

The first library screen should show categories when multiple categories exist. If only the default category exists, it may skip the category picker and show manga directly.

Manga rows should be compact and scan-friendly:

```text
Sousou no Frieren                144 unread / Comick EN
Chainsaw Man                      51 unread / Local
```

Use the existing menu row constraints. Avoid cover grids in the MVP; text menus are more predictable on e-ink and cheaper to refresh.

### 2. Open manga from library

Selecting a library manga opens the existing chapter screen, enriched with manga-level context and actions.

Expected manga-level actions:

- Refresh manga and chapters.
- Open first unread chapter if downloaded.
- Download first unread chapter.
- Download next 5/10/50 unread chapters.
- Keep next 5/10/50 unread downloaded.
- Delete read downloaded chapters from device.
- Remove from library.

The existing chapter action menu remains the detailed chapter control surface.

### 3. Search a source

From source browse, each source should offer:

- Popular
- Latest, only when `supportsLatest` is true
- Search

Search should use KOReader text input and call `fetchSourceManga` with:

```graphql
type: SEARCH
query: <user text>
page: 1
```

Search results should show whether each manga is already in the library:

```text
[+] Frieren: Beyond Journey's End
[ ] Funeral Frieren Anthology
```

Selecting a result opens a manga action menu:

- Open chapters
- Add to library, if not already in library
- Remove from library, if already in library
- Refresh details/chapters

### 4. Page through source results

Source result screens should support pagination because current browsing only fetches page 1.

If `hasNextPage` is true, append a menu item:

```text
Next page
```

If the current page is greater than 1, append:

```text
Previous page
```

The current page number and mode should be part of the title:

```text
MangaDex (EN) - Search: frieren - Page 1
```

The MVP does not need infinite scroll or background prefetch.

### 5. Add or remove manga from library

Add and remove should use Suwayomi library state, not a KOReader-only favorite list.

Behavior:

- `Add to library` sets `inLibrary = true`.
- `Remove from library` asks for confirmation, then sets `inLibrary = false`.
- After the mutation, the visible row updates if possible.
- Removing a manga from the Suwayomi library must not delete local KOReader `.cbz` files.

Category assignment is deferred. Newly added manga should use Suwayomi's default behavior, which assigns it to the default category unless the server prompts or configuration changes later.

### 6. Keep KOReader-local downloads

The MVP should continue using the existing KOReader-local download queue.

Reasons:

- The user reads on the device, so the device needs local files.
- The current queue already handles local paths, partial files, retry/recovery, and chapter menu state.
- Suwayomi's server download queue solves a different problem: downloading to the server storage, not necessarily to the KOReader device.

The plugin's `Download` action should be explicitly device-local:

- fetch chapter page URLs through Suwayomi
- download page image bytes to the KOReader device
- write a local `.cbz`
- update plugin-local queue/ledger state

It should not enqueue Suwayomi server downloads as a hidden side effect. Suwayomi may still fetch chapter/page data internally in order to serve page URLs, but the plugin should not call server downloader mutations such as `enqueueChapterDownload` or `enqueueChapterDownloads` for the normal KOReader download action.

If server-side downloads become useful later, they should be exposed as a separate action such as `Download on server`, not merged with the device-local `Download`.

## Filesystem Layout

The current downloader writes:

```text
<download_directory>/<manga_title>/<chapter_name>.cbz
```

That was acceptable while the practical target was Local source, but it is not enough for a multi-source client. Different sources can expose the same title, and the same title can exist in both Local source and a remote source.

New downloads should use a source-scoped layout:

```text
<download_directory>/<source_label>/<manga_title>/<chapter_name>.cbz
```

Examples:

```text
Manga/
  Local source/
    Sousou no Frieren/
      Official_Vol. 1 Ch. 1.cbz
  Comick (Unoriginal) (EN)/
    Sousou no Frieren/
      Vol. 1 Ch. 1.cbz
  MangaDex (EN)/
    Frieren: Beyond Journey's End/
      Ch. 1.cbz
```

`source_label` should be:

1. `manga.source.displayName`, when available
2. `manga.source.name` plus language, when display name is missing
3. `source_id`, when only the id is available
4. `Unknown source`, only as a last resort

All path segments should use the existing filename sanitization rules.

### Existing unscoped downloads

The plugin is currently private to one user, so the MVP should not carry compatibility code for the old unscoped layout.

Behavior:

- new downloads write only to the source-scoped path
- open/delete/existence checks use only the source-scoped path
- existing unscoped files can be moved manually if needed

This keeps the implementation simpler and avoids carrying migration logic before the layout has real-world mileage.

### Future source overrides

Per-source directory overrides are a reasonable later feature, especially for workflows where a remote source should sync into a specific downstream tool. They are out of scope for this MVP.

The first version should keep one global download directory and derive source subfolders automatically.

## API Design

Extend `suwayomi_api.lua` while keeping the current pattern of query builders, parsers, and fetch helpers.

### Library queries

Add a library manga query:

```graphql
query GET_LIBRARY_MANGAS($filter: MangaFilterInput, $first: Int, $offset: Int, $order: [MangaOrderInput!]) {
  mangas(filter: $filter, first: $first, offset: $offset, order: $order) {
    totalCount
    nodes {
      id
      title
      inLibrary
      unreadCount
      downloadCount
      initialized
      thumbnailUrl
      source { id displayName name lang }
      categories { nodes { id name order } }
      firstUnreadChapter { id name chapterNumber sourceOrder isRead }
      latestFetchedChapter { id name chapterNumber sourceOrder isRead }
    }
  }
}
```

The default MVP filter should be:

```graphql
filter: { inLibrary: { equalTo: true } }
```

Sorting should start with title ascending unless live testing shows server/category ordering is more useful on device.

Add category query support:

```graphql
query GET_LIBRARY_CATEGORIES {
  categories {
    nodes {
      id
      name
      order
      mangas(condition: { inLibrary: true }) { totalCount }
    }
  }
}
```

If the exact category-to-manga filter shape differs during implementation, use the shape verified against the live schema and preserve the product behavior.

`downloadCount` is Suwayomi server state. It must not be presented as KOReader-local availability. If the UI shows local availability counts, those counts should come from the existing KOReader-local ledger or filesystem checks.

### Source manga query

Replace the fixed popular page-1 helper with a parameterized helper:

```lua
fetchMangaForSource(credentials, {
    source_id = source.id,
    page = 1,
    type = "POPULAR", -- POPULAR, LATEST, SEARCH
    query = nil,
    filters = nil,
})
```

The parser should preserve:

- `has_next_page`
- manga `id`
- `title`
- `in_library`
- `initialized`
- `thumbnail_url`
- source metadata when returned by the query

The old `fetchMangaForSource(credentials, source_id)` calling style should be replaced during the implementation slice instead of preserved as a wrapper. This keeps the API surface smaller while the plugin is still private.

### Manga membership mutations

Add:

```lua
updateMangaLibraryState(credentials, manga_id, in_library)
```

GraphQL shape:

```graphql
mutation UPDATE_MANGA_LIBRARY($input: UpdateMangaInput!) {
  updateManga(input: $input) {
    manga { id inLibrary inLibraryAt }
  }
}
```

Variables:

```json
{
  "input": {
    "id": 123,
    "patch": { "inLibrary": true }
  }
}
```

### Manga refresh

Add:

```lua
refreshManga(credentials, manga_id)
```

This should call both:

- `fetchChapters(input: { mangaId })`
- `fetchManga(input: { id })`

The UI can use this before opening a remote manga that is not initialized, or when the user explicitly selects refresh.

### Full filters deferred

The API can expose raw source filters for later, but the MVP should not build a full dynamic filter editor.

Allowed MVP additions:

- fetch source filter definitions for debugging or future support
- define a small internal representation for filters
- add tests around positional `FilterChangeInput` if a simple preset is implemented

Deferred:

- group filter editor
- tri-state tag include/exclude UI
- saved source searches
- source preference editor

## UI Design

The MVP should stay menu-based.

### Main menu

Recommended order:

1. Library
2. Browse sources
3. Search a source
4. Sync read state now
5. Setup login information
6. Setup source languages
7. Setup download directory
8. Setup parallel downloads

`Browse Suwayomi` can be renamed to `Browse sources` once `Library` exists.

### Library manga menu

Add `showLibraryMangaMenu(mangas, onSelect, options)`.

Rows should be built by API/UI helpers so tests can assert row text independently from KOReader widgets.

Example row status markers:

- `12 unread`
- `5 local`
- `Comick EN`
- `Local`

Avoid dense symbolic status until the text behavior is proven.

If local availability is displayed at manga level, it should be computed from source-scoped KOReader paths, not from Suwayomi `downloadCount`.

### Source mode menu

Selecting a source should show a small mode menu when useful:

```text
MangaDex (EN)
  Popular
  Latest
  Search
```

For Local source, the UI may keep the current direct manga list behavior if that remains faster and clearer.

### Manga action menu

Add `showMangaActionsMenu(manga, actions, onSelect)` or reuse `showChapterActionsMenu` with a neutral name later.

The first implementation can reuse the existing two-column button dialog, but action names must remain short:

- Open
- Add
- Remove
- Refresh
- First unread
- Download next

For destructive actions like removing from library, reuse `showConfirm`.

## State and Persistence

Do not introduce a separate local library.

Persist only lightweight device preferences:

- last selected library category, optional
- last selected source mode, optional
- last source search query per source, optional

These are conveniences, not required for the MVP.

Existing persistent state remains:

- credentials
- source language filter
- source cache
- download directory
- download queue
- chapter ledger
- parallel download setting

The chapter ledger remains local because it reconciles KOReader state with Suwayomi state. Library membership remains server-owned.

The download directory setting remains global in the MVP. Source-scoped subfolders are derived, not stored as separate source settings.

## Refactoring Direction

The MVP should start with a small structure cleanup before adding library and source-search behavior. `main.lua` is already the orchestration point for menu registration, source browsing, chapter menus, download policies, read-state reconciliation, KOReader metadata, and background workers. Adding library and client discovery directly to it would make iteration harder.

Refactoring should be behavior-preserving and test-backed. The goal is not a broad rewrite; it is to create a few narrow homes for new client work.

Recommended module boundaries:

### `suwayomi_paths.lua`

Own path and filesystem naming decisions:

- source label selection
- source-scoped manga/chapter target path construction
- path segment sanitization, moved from the downloader if practical
- optional helpers for local availability checks

This lets future source directory overrides land in one place.

### `suwayomi_client.lua`

Own library/source-search orchestration that is not chapter-menu-specific:

- load library categories
- load library manga
- open source browse modes
- run source search
- maintain source result pagination context
- call manga add/remove/refresh API helpers

`main.lua` should call this module from menu callbacks and keep KOReader plugin lifecycle concerns.

### Existing modules

Keep these responsibilities where they are:

- `suwayomi_api.lua`: GraphQL query builders, parsers, and network helpers
- `suwayomi_ui.lua`: KOReader menu/dialog construction
- `suwayomi_downloader.lua`: page download and archive creation
- `suwayomi_download_queue.lua`: persistent queue, progress, and recovery
- `suwayomi_read_sync_worker.lua`: read-state sync worker behavior

Do not extract read-state reconciliation or KOReader sidecar handling as part of the first client MVP unless a concrete implementation slice needs it.

## Data Flow

### Library entry

1. User opens `Library`.
2. Plugin loads credentials.
3. Plugin schedules pending read-state sync, as browse already does.
4. Plugin fetches categories.
5. Plugin fetches library manga for the selected category or all manga.
6. UI shows compact manga rows.
7. Selecting a manga opens the chapter screen using existing `showChaptersForManga`.

### Source search entry

1. User selects source.
2. User selects `Search`.
3. Plugin shows a text input.
4. Plugin calls parameterized `fetchMangaForSource`.
5. UI shows page 1 results with library markers.
6. User can page forward/backward, add/remove library, or open chapters.

### Open uninitialized manga

If a manga is not initialized:

1. show a loading message
2. call `refreshManga`
3. then open chapters

If refresh fails, show the error and keep the user on the current menu.

## Error Handling

Handle these cases with user-visible messages:

- no credentials configured
- library is empty
- selected category is empty
- source search returns no results
- source does not support latest
- search query is empty
- GraphQL schema mismatch
- malformed server response
- network/auth failures
- refresh fails for an uninitialized manga
- add/remove library mutation fails

For library removal:

- ask for confirmation
- make clear that local downloaded files are not deleted

For search pagination:

- if page fetch fails, keep the previous page visible when possible
- otherwise show an error message and let the user retry from the source menu

## Testing Strategy

### API tests

Add coverage in `spec/suwayomi_api_spec.lua` for:

- library manga query builder
- library manga parser
- category parser
- parameterized source manga query for `POPULAR`, `LATEST`, and `SEARCH`
- source manga parser preserving `hasNextPage` and `inLibrary`
- update manga library mutation builder/parser
- refresh manga mutation/query parser
- malformed response handling for new endpoints

### Path tests

Add coverage in `spec/suwayomi_paths_spec.lua` for:

- source label selection from `displayName`, name/language, source id, and fallback
- source-scoped target path generation
- path segment sanitization
- no legacy unscoped fallback behavior

### UI tests

Add coverage in `spec/suwayomi_ui_spec.lua` for:

- library manga menu row construction
- source mode menu
- source result pagination rows
- manga action menu
- confirmation for remove-from-library

### Plugin flow tests

Add coverage in `spec/main_spec.lua` for:

- main menu includes `Library`
- library opens manga list from API results
- empty library message
- category selection, if categories are shown
- source search prompts for query and calls `SEARCH`
- source popular/latest call correct modes
- next/previous page update the results
- add-to-library updates visible state
- remove-from-library confirms first
- uninitialized manga refreshes before chapter open
- existing chapter actions continue to work for library-opened manga

### Live verification

Manual verification against the real Suwayomi instance should cover:

- Library loads and shows the observed library manga.
- A Local source manga still opens and downloads normally.
- A remote-source manga opens, refreshes, and downloads through the existing KOReader-local queue.
- A new remote-source download is written under `<download_directory>/<source_label>/<manga_title>/`.
- Unscoped pre-MVP downloads are not detected automatically.
- A KOReader-local download does not mark the chapter as server-downloaded in Suwayomi unless Suwayomi itself changes that behavior as part of page fetching.
- Source search for `frieren` returns remote MangaDex results.
- Add/remove library works and is reflected in WebUI.
- Pagination does not duplicate or lose the current search context.

## Out of Scope

The MVP intentionally excludes:

- full source filter editor
- saved source searches
- category assignment during add-to-library
- category create/rename/reorder/delete
- extension install/update/uninstall
- source preference editor
- source migration
- duplicate manga manager
- tracking integrations
- WebUI/server update notifications
- server-side download queue management
- per-source download directory overrides
- automatic detection or migration of existing unscoped downloads
- cover grid UI
- thumbnail caching
- OPDS support
- backup/restore

These can be revisited after the library/search loop proves useful on device.

## Risks

### `main.lua` size

`main.lua` already owns a lot of orchestration and read/download policy. Adding library and search flows directly to it will make it harder to maintain.

Mitigation:

- Keep API parsing in `suwayomi_api.lua`.
- Keep menu construction in `suwayomi_ui.lua`.
- Add `suwayomi_paths.lua` before changing the download layout.
- Add `suwayomi_client.lua` before implementing library and source-search orchestration.
- Keep `main.lua` as plugin lifecycle and top-level menu wiring where possible.

### Source filters

Remote source filters are complex and source-specific.

Mitigation:

- Treat filter editing as explicitly deferred.
- Start with search text, popular/latest mode, and pagination.
- Only add simple presets after real use shows which filters matter on e-ink.

### Remote source reliability

Some sources may be slow, blocked, Cloudflare-protected, or return unusual page URLs.

Mitigation:

- Keep the existing timeout and debug logging approach.
- Ensure errors name the operation that failed.
- Validate at least MangaDex and Comick paths against the live instance before declaring remote-source support.

### Library and local downloads can diverge

Removing manga from Suwayomi library should not remove local KOReader downloads, and deleting local files should not remove library entries.

Mitigation:

- Make ownership explicit in action labels and confirmation text.
- Keep library membership server-owned and local files device-owned.

## Success Criteria

The MVP is successful when:

1. A user can open Suwayomi Library from KOReader and choose a manga.
2. Library rows show enough state to pick what to read next.
3. Existing chapter actions work from library-opened manga.
4. A user can search a remote source from KOReader.
5. Search results can be paged.
6. A user can add a search result to the Suwayomi library.
7. A user can remove a manga from the Suwayomi library with confirmation.
8. Uninitialized manga can be refreshed before opening chapters.
9. KOReader-local downloads remain the active offline-reading path.
10. New downloads use source-scoped directories without legacy unscoped path compatibility.
11. Unit tests cover the new API, UI, path, and plugin flow behavior.

## Recommended Implementation Slices

This spec should be implemented in separate, reviewable steps:

1. Extract source-scoped path construction into `suwayomi_paths.lua` and update downloader/queue callers to use it.
2. Add `suwayomi_client.lua` as a thin orchestration home for upcoming library/search flows, initially by moving small existing browse orchestration pieces where that reduces `main.lua` pressure.
3. Add API support for library, source search pagination, manga library mutation, and refresh.
4. Add library menu and library-to-existing-chapter-screen flow.
5. Add manga-level action menu for refresh, add/remove library, and first-unread helpers.
6. Add source browse mode menu with popular/latest/search.
7. Add source result pagination and add/remove state refresh.
8. Run remote-source live verification and update README/roadmap.

The first slice should change download paths intentionally, but should not change read-state behavior or queue policy beyond the new source-scoped target paths.
