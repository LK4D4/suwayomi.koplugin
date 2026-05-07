# Suwayomi KOReader Plugin Roadmap

This roadmap tracks the next implementation path from the current downloader-oriented plugin to a small KOReader-native Suwayomi client.

The design source for this roadmap is:

- `docs/superpowers/specs/2026-05-06-suwayomi-client-mvp-design.md`

## Direction

The MVP should expose four first-class client surfaces:

```text
Suwayomi -> Library -> Manga -> First unread / Download next unread / Keep next unread
Suwayomi -> Browse -> Source -> Popular / Latest / Search -> Manga -> Add to library / Open chapters
Suwayomi -> Downloads -> Active / Queued / Failed -> Retry / Clear / Open manga
Suwayomi -> Settings -> Connection / Library / Browse / Downloads
```

The plugin should not try to clone Suwayomi-WebUI. KOReader already owns the reading experience, and this plugin already owns the device-local download/read-state loop. The roadmap mirrors WebUI's Library, Browse, Downloads, and Settings information architecture only where it helps e-ink reading.

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
- [x] Manual read-state sync action
- [x] App Store installation path

Current limitations:

- There is no first-class Downloads screen even though a local queue exists.
- Source manga browsing only fetches the first popular page.
- Remote source search, latest, and pagination are missing.
- Library membership cannot be managed from KOReader.
- `main.lua` owns too much orchestration for the next client features to remain comfortable.

## Phase 1: Refactor For Client Work

Goal: create small homes for path and client orchestration before adding more behavior to `main.lua`.

### 1.1 Source-scoped paths

- [x] Add `suwayomi_paths.lua`
- [x] Move path segment sanitization into the path module, or make the downloader delegate to it
- [x] Add source label selection:
  - `manga.source.displayName`
  - `manga.source.name` plus language
  - source id
  - `Unknown source`
- [x] Change new target layout to:

```text
<download_directory>/<source_label>/<manga_title>/<chapter_name>.cbz
```

- [x] Update downloader target path generation
- [x] Update queue/existence/open/delete callers to use the new path logic
- [x] Do not add old unscoped path detection or migration
- [x] Add `spec/suwayomi_paths_spec.lua`
- [x] Update downloader, queue, and main specs for source-scoped paths

Exit criteria:

- New downloads land under source-scoped folders.
- Old unscoped files are not detected automatically.
- Existing read-state and queue behavior remains unchanged apart from target paths.

### 1.2 Client orchestration module

- [x] Add `suwayomi_client.lua`
- [x] Move small existing browse orchestration pieces out of `main.lua` when it reduces pressure
- [x] Keep plugin lifecycle, main menu registration, and KOReader integration in `main.lua`
- [x] Keep API parsing in `suwayomi_api.lua`
- [x] Keep KOReader menu/dialog construction in `suwayomi_ui.lua`
- [x] Keep queue mechanics in `suwayomi_download_queue.lua`
- [x] Avoid extracting read-state reconciliation unless a later slice truly needs it

Exit criteria:

- New Library, Browse, Downloads, and Settings flows have a clear module to grow into.
- `main.lua` remains the top-level plugin coordinator instead of the owner of every client workflow.

## Phase 2: Navigation And Settings Shell

Goal: make the top-level UI match the MVP surfaces before each surface is fully implemented.

- [x] Replace the old top-level submenu with a native Suwayomi hub:
  - Library
  - Browse
  - Downloads
  - Sync
  - Settings
  - Close
- [x] Add title-bar return-to-hub affordance on Suwayomi Library/Browse/Manga list screens
- [x] Use a built-in KOReader icon for the return-to-hub affordance
- [x] Rename `Browse Suwayomi` to `Browse`
- [x] Add `Settings` menu with sections:
  - Connection
  - Library
  - Browse
  - Downloads
- [x] Move login/server URL setup under `Settings -> Connection`
- [x] Move source language setup under `Settings -> Browse`
- [x] Move download directory setup under `Settings -> Downloads`
- [x] Move parallel download setup under `Settings -> Downloads`
- [x] Add placeholder Library settings for category picker behavior and last category, even if only one is wired first
- [x] Keep temporary top-level duplicates only inside narrow transition commits

Tests:

- [x] Main menu opens the Suwayomi hub with `Library`, `Browse`, `Downloads`, `Sync`, `Settings`, and `Close`
- [x] Settings menu routes to Connection, Library, Browse, and Downloads
- [x] Existing login, source language, download directory, and parallel-download settings still work from their new homes
- [x] Hub navigation verified on Boox Palma

Exit criteria:

- The plugin presents the same top-level shape as the MVP spec.
- Existing setup behavior is still available through grouped Settings.
- Library/Browse screens can return to the hub without stacking stale menus underneath.

## Phase 3: API Foundation For Client MVP

Goal: expose the Suwayomi GraphQL operations needed by Library, Browse, pagination, and library membership.

- [x] Add library manga query builder/parser/fetch helper
- [x] Add category query builder/parser/fetch helper
- [x] Add parameterized `fetchMangaForSource` input:
  - source id
  - page
  - type: `POPULAR`, `LATEST`, `SEARCH`
  - query text
  - filters, reserved for later
- [x] Preserve `hasNextPage` in source manga responses
- [x] Preserve `inLibrary`, `initialized`, thumbnail URL, and source metadata in manga responses
- [x] Replace the old fixed `fetchMangaForSource(credentials, source_id)` calling style
- [x] Add manga add/remove library mutation helper
- [x] Add manga/chapter refresh helper
- [x] Keep full dynamic source filters out of the MVP UI

Tests:

- [x] Library manga query and parser
- [x] Category query and parser
- [x] Source manga query for `POPULAR`, `LATEST`, and `SEARCH`
- [x] Source manga parser with `hasNextPage` and `inLibrary`
- [x] Manga library mutation builder and parser
- [x] Refresh helper response parsing
- [x] Malformed response and GraphQL error handling

Exit criteria:

- API helpers can drive the Library and Browse UI without schema guessing.
- Existing source/chapter/download APIs still pass their tests.

## Phase 4: Library Surface

Goal: make `Library` the primary reading entry point.

- [x] Fetch categories when opening Library
- [x] If multiple categories exist, show a category picker
- [x] If only the default category exists, go directly to manga list
- [x] Fetch library manga for the selected category or all manga
- [x] Add compact library manga rows with:
  - title
  - unread count
  - source label
  - optional KOReader-local availability computed from source-scoped paths
- [x] Open selected library manga through the existing chapter screen
- [x] Keep pending read-state sync scheduling on Library entry
- [x] Wire Library settings that are cheap after the menu exists:
  - remember last selected category, optional
  - category picker behavior

Tests:

- [x] Empty library shows a friendly message
- [x] Category selection works when categories are present
- [x] Single/default category can skip category picker
- [x] Library manga rows format correctly
- [x] Selecting a library manga opens chapter flow
- [x] Existing chapter actions work for library-opened manga

Exit criteria:

- A user can open KOReader, enter Suwayomi Library, choose manga, and use existing chapter actions.

## Phase 5: Downloads Surface

Goal: make the existing KOReader-local download queue inspectable and manageable from the top level.

- [x] Add top-level `Downloads` menu implementation
- [x] Read active and queued items from `suwayomi_download_queue.lua`
- [x] Surface failed items with last error where available
- [ ] Surface completed history only if current state persists it or adding it is small
- [x] Add compact rows with status, manga title, and chapter name
- [x] Add retry for failed local downloads
- [x] Add clear failed
- [ ] Add cancel queued item when supported by the queue
- [ ] Add clear completed history if completed history exists
- [ ] Add open manga/chapter context for queue items when enough metadata exists
- [ ] Keep Suwayomi server downloader mutations out of this surface
- [ ] Wire Downloads settings:
  - KOReader download directory
  - max parallel device downloads
  - read-only source-scoped layout explanation

Tests:

- [x] Downloads menu groups active, queued, and failed items where state exists
- [x] Failed rows expose retry
- [x] Clear failed calls local queue cleanup only
- [ ] Cancel queued item calls local queue cancellation only
- [ ] Downloads settings route to existing local directory and parallel-download settings
- [ ] Suwayomi server `downloadCount` is not used as KOReader-local availability

Exit criteria:

- A user can inspect the local queue, retry failed local downloads, and adjust local download settings without opening manga chapters first.

## Phase 6: Manga-Level Client Actions

Goal: add manga-level actions that fit the Library and Browse workflow.

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

- Library and Browse entries are useful without drilling into individual chapters first.
- Library membership can be managed from KOReader.

## Phase 7: Browse Surface

Goal: make remote source discovery usable enough to add manga without leaving KOReader.

- [ ] Selecting Browse opens enabled sources grouped or filtered by language
- [ ] Apply Browse settings:
  - source languages
  - show/hide NSFW sources when metadata exists
  - hide in-library manga from source results, optional
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

- [ ] Browse source list respects language settings
- [ ] Source mode menu construction
- [ ] Search prompt calls `SEARCH`
- [ ] Popular and latest call the correct modes
- [ ] Latest is hidden or rejected when unsupported
- [ ] Next/previous page update result context
- [ ] Search results show library state
- [ ] Optional hide-in-library setting filters visible results only where intended
- [ ] Add/remove from source results updates visible state

Exit criteria:

- A user can search a remote source, page results, add a manga to the library, and open its chapters.

## Phase 8: Remote Source Verification

Goal: prove the client MVP works with real remote source flows.

- [ ] Verify MangaDex search, library add/remove, refresh, chapter listing, and download
- [ ] Verify Comick search, library add/remove, refresh, chapter listing, and download
- [ ] Verify Local source still works with source-scoped paths
- [ ] Confirm Downloads shows KOReader-local queue state
- [ ] Confirm KOReader-local download does not call Suwayomi server download queue mutations
- [ ] Confirm server-side downloaded state is not treated as KOReader-local availability
- [ ] Confirm Settings exposes Connection, Library, Browse, and Downloads on device
- [ ] Document any source-specific quirks in debug notes or README
- [ ] Add regression tests for any live-server bug that can be reasonably reproduced in unit tests

Exit criteria:

- Remote source support can be described as usable for the tested sources.
- The README no longer needs to say the practical flow is Local-source-only.

## Phase 9: Documentation And Release Polish

Goal: keep public documentation aligned with the client MVP.

- [ ] Update README feature list
- [ ] Update README usage flow to start with Library, Browse, and Downloads
- [ ] Document grouped Settings
- [ ] Document source-scoped download layout
- [ ] Document that KOReader downloads are device-local, not Suwayomi server downloads
- [ ] Document unsupported/deferred features:
  - full source filters
  - source preferences
  - extension management
  - server-side download queue management
  - server-side download settings
  - per-source download directory overrides
- [ ] Add screenshots or short demo media if useful
- [ ] Improve debug logging guidance for remote source failures
- [ ] Add release notes/changelog entry

Exit criteria:

- The shipped behavior, README, spec, and roadmap tell the same story.

## Deferred Ideas

These are intentionally outside the client MVP:

- Full dynamic source filter editor
- Saved source searches
- Category assignment during add-to-library
- Category create/rename/reorder/delete
- Per-source download directory overrides
- Server-side `Download on server` action
- Server-side download queue inspection/management
- Server-side download settings, including Suwayomi server download path
- Extension install/update/uninstall
- Extension repository management
- Server local-source path management
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
3. Navigation and grouped Settings shell
4. Client API foundation
5. Library surface
6. Downloads surface
7. Manga-level actions
8. Browse surface
9. Live remote-source verification
10. README and release polish

## Current Next Step

Continue the Downloads surface. The hub action now exposes the existing KOReader-local queue with active, queued, and failed rows plus retry and clear-failed actions. The next slice should add queued cancellation or completed history only if the queue state supports it without broad queue changes.
