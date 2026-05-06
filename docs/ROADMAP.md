# Suwayomi KOReader Plugin Roadmap

This roadmap tracks the next implementation path from the current downloader-oriented plugin to a small KOReader-native Suwayomi client.

The design source for this roadmap is:

- `docs/superpowers/specs/2026-05-06-suwayomi-client-mvp-design.md`

## Direction

The plugin should become a library-first Suwayomi client for KOReader:

```text
Suwayomi -> Library -> Manga -> First unread / Download next unread / Keep next unread
```

Source browsing and search should exist, but they serve the reading workflow:

```text
Suwayomi -> Browse/Search source -> Manga -> Add to library / Open chapters
```

The plugin should not try to clone Suwayomi-WebUI. KOReader already owns the reading experience, and this plugin already owns the device-local download/read-state loop.

## Current Baseline

Already implemented:

- [x] Basic Auth login and server URL persistence
- [x] Source listing with language filtering
- [x] Cached source refresh
- [x] Source -> manga -> chapter browsing
- [x] Chapter page fetching through Suwayomi
- [x] Local `.cbz` creation on the KOReader device
- [x] Persistent device-local download queue
- [x] Download queue recovery after interruption
- [x] Chapter actions: open, download, delete from device, mark read/unread
- [x] Chapter selection mode
- [x] Bulk chapter actions
- [x] Bulk policies: download next unread, keep next unread downloaded, delete read downloaded chapters
- [x] Read-state reconciliation from Suwayomi, KOReader metadata, and the plugin ledger
- [x] Background retry for pending read/unread sync
- [x] Manual `Sync read state now`
- [x] App Store installation path

Current limitations:

- The UI is still browse-first, not library-first.
- Source manga browsing only fetches the first popular page.
- Remote source search, latest, and pagination are missing.
- Library membership cannot be managed from KOReader.
- Download paths are still shaped by the original Local-source-only layout.
- `main.lua` owns too much orchestration for the next client features to remain comfortable.

## Phase 1: Refactor For Client Work

Goal: create small homes for path and client orchestration before adding more behavior to `main.lua`.

### 1.1 Source-scoped paths

- [ ] Add `suwayomi_paths.lua`
- [ ] Move path segment sanitization into the path module, or make the downloader delegate to it
- [ ] Add source label selection:
  - `manga.source.displayName`
  - `manga.source.name` plus language
  - source id
  - `Unknown source`
- [ ] Change new target layout to:

```text
<download_directory>/<source_label>/<manga_title>/<chapter_name>.cbz
```

- [ ] Update downloader target path generation
- [ ] Update queue/existence/open/delete callers to use the new path logic
- [ ] Do not add old unscoped path detection or migration
- [ ] Add `spec/suwayomi_paths_spec.lua`
- [ ] Update downloader, queue, and main specs for source-scoped paths

Exit criteria:

- New downloads land under source-scoped folders.
- Old unscoped files are not detected automatically.
- Existing read-state and queue behavior remains unchanged apart from target paths.

### 1.2 Client orchestration module

- [ ] Add `suwayomi_client.lua`
- [ ] Move small existing browse orchestration pieces out of `main.lua` when it reduces pressure
- [ ] Keep plugin lifecycle, main menu registration, and KOReader integration in `main.lua`
- [ ] Keep API parsing in `suwayomi_api.lua`
- [ ] Keep KOReader menu/dialog construction in `suwayomi_ui.lua`
- [ ] Keep queue mechanics in `suwayomi_download_queue.lua`
- [ ] Avoid extracting read-state reconciliation unless a later slice truly needs it

Exit criteria:

- New library/search flows have a clear module to grow into.
- `main.lua` remains the top-level plugin coordinator instead of the owner of every client workflow.

## Phase 2: API Foundation For Client MVP

Goal: expose the Suwayomi GraphQL operations needed by library, source search, pagination, and library membership.

- [ ] Add library manga query builder/parser/fetch helper
- [ ] Add category query builder/parser/fetch helper
- [ ] Add parameterized `fetchMangaForSource` input:
  - source id
  - page
  - type: `POPULAR`, `LATEST`, `SEARCH`
  - query text
  - filters, reserved for later
- [ ] Preserve `hasNextPage` in source manga responses
- [ ] Preserve `inLibrary`, `initialized`, thumbnail URL, and source metadata in manga responses
- [ ] Replace the old fixed `fetchMangaForSource(credentials, source_id)` calling style
- [ ] Add manga add/remove library mutation helper
- [ ] Add manga/chapter refresh helper
- [ ] Keep full dynamic source filters out of the MVP UI

Tests:

- [ ] Library manga query and parser
- [ ] Category query and parser
- [ ] Source manga query for `POPULAR`, `LATEST`, and `SEARCH`
- [ ] Source manga parser with `hasNextPage` and `inLibrary`
- [ ] Manga library mutation builder and parser
- [ ] Refresh helper response parsing
- [ ] Malformed response and GraphQL error handling

Exit criteria:

- API helpers can drive the library and source-search UI without schema guessing.
- Existing source/chapter/download APIs still pass their tests.

## Phase 3: Library-First Entry Point

Goal: make `Library` the primary reading entry point.

- [ ] Add top-level `Library` menu item before `Browse sources`
- [ ] Fetch categories when opening library
- [ ] If multiple categories exist, show a category picker
- [ ] If only the default category exists, go directly to manga list
- [ ] Fetch library manga for the selected category or all manga
- [ ] Add compact library manga rows with:
  - title
  - unread count
  - source label
  - optional KOReader-local availability computed from source-scoped paths
- [ ] Open selected library manga through the existing chapter screen
- [ ] Keep pending read-state sync scheduling on library entry

Tests:

- [ ] Main menu includes `Library`
- [ ] Empty library shows a friendly message
- [ ] Category selection works when categories are present
- [ ] Single/default category can skip category picker
- [ ] Library manga rows format correctly
- [ ] Selecting a library manga opens chapter flow
- [ ] Existing chapter actions work for library-opened manga

Exit criteria:

- A user can open KOReader, enter Suwayomi Library, choose manga, and use existing chapter actions.

## Phase 4: Manga-Level Client Actions

Goal: add manga-level actions that fit the library-first workflow.

- [ ] Add manga action menu
- [ ] Add `Refresh manga and chapters`
- [ ] Add `Add to library`
- [ ] Add `Remove from library` with confirmation
- [ ] Add `Open first unread` when the first unread chapter is locally available
- [ ] Add `Download first unread`
- [ ] Add `Download next 5/10/50 unread`
- [ ] Add `Keep next 5/10/50 unread downloaded`
- [ ] Add `Delete read downloaded chapters from device`
- [ ] Refresh visible row state after add/remove/refresh when possible

Tests:

- [ ] Manga action menu construction
- [ ] Remove-from-library confirmation
- [ ] Add/remove library calls the mutation helper
- [ ] Uninitialized manga refreshes before chapter open
- [ ] First-unread actions select the expected chapter
- [ ] Existing bulk policies can be triggered from manga-level actions

Exit criteria:

- Library entries are useful without drilling into individual chapters first.
- Library membership can be managed from KOReader.

## Phase 5: Source Browse, Search, And Pagination

Goal: make remote source discovery usable enough to add manga without leaving KOReader.

- [ ] Rename `Browse Suwayomi` to `Browse sources`
- [ ] Selecting a source opens a mode menu:
  - Popular
  - Latest, only when supported
  - Search
- [ ] Keep direct Local source listing if it remains clearer
- [ ] Add text input for source search
- [ ] Fetch source manga with selected mode and page
- [ ] Add result rows with library markers
- [ ] Add `Next page` when `hasNextPage` is true
- [ ] Add `Previous page` when page is greater than 1
- [ ] Preserve current source/mode/query/page context while paging
- [ ] Selecting a result opens manga actions:
  - Open chapters
  - Add to library
  - Remove from library
  - Refresh details/chapters

Tests:

- [ ] Source mode menu construction
- [ ] Search prompt calls `SEARCH`
- [ ] Popular and latest call the correct modes
- [ ] Latest is hidden or rejected when unsupported
- [ ] Next/previous page update result context
- [ ] Search results show library state
- [ ] Add/remove from source results updates visible state

Exit criteria:

- A user can search a remote source, page results, add a manga to the library, and open its chapters.

## Phase 6: Remote Source Verification

Goal: prove the client MVP works with real remote source flows.

- [ ] Verify MangaDex search, library add/remove, refresh, chapter listing, and download
- [ ] Verify Comick search, library add/remove, refresh, chapter listing, and download
- [ ] Verify Local source still works with source-scoped paths
- [ ] Confirm KOReader-local download does not call Suwayomi server download queue mutations
- [ ] Confirm server-side downloaded state is not treated as KOReader-local availability
- [ ] Document any source-specific quirks in debug notes or README
- [ ] Add regression tests for any live-server bug that can be reasonably reproduced in unit tests

Exit criteria:

- Remote source support can be described as usable for the tested sources.
- The README no longer needs to say the practical flow is Local-source-only.

## Phase 7: Documentation And Release Polish

Goal: keep public documentation aligned with the client MVP.

- [ ] Update README feature list
- [ ] Update README usage flow to start with Library
- [ ] Document source-scoped download layout
- [ ] Document that KOReader downloads are device-local, not Suwayomi server downloads
- [ ] Document unsupported/deferred features:
  - full source filters
  - source preferences
  - extension management
  - server-side download queue management
  - per-source download directory overrides
- [ ] Add screenshots or short demo media if useful
- [ ] Improve debug logging guidance for remote source failures
- [ ] Add release notes/changelog entry

Exit criteria:

- The shipped behavior, README, and roadmap tell the same story.

## Deferred Ideas

These are intentionally outside the client MVP:

- Full dynamic source filter editor
- Saved source searches
- Category assignment during add-to-library
- Category create/rename/reorder/delete
- Per-source download directory overrides
- Server-side `Download on server` action
- Server-side download queue inspection/management
- Extension install/update/uninstall
- Source preference editor
- Migration between sources
- Duplicate manga manager
- Tracker integration
- Cover grid UI
- Thumbnail caching
- OPDS support
- Backup/restore

## Recommended Order

1. Source-scoped path module
2. Thin client orchestration module
3. Client API foundation
4. Library entry point
5. Manga-level actions
6. Source search and pagination
7. Live remote-source verification
8. README and release polish
