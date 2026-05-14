# Suwayomi KOReader Plugin Roadmap

This roadmap tracks the next implementation path from the current downloader-oriented plugin to a small KOReader-native Suwayomi library, download, and sync client.

## Direction

The MVP should expose four first-class client surfaces:

```text
Suwayomi -> Library -> Manga -> First unread / Download next / Download ahead
Suwayomi -> Browse -> Search all / Source -> Popular / Latest / Search -> Manga -> Add to library / Open chapter list
Suwayomi -> Downloads -> Active / Queued / Failed -> Retry / Clear / Open manga
Suwayomi -> Settings -> Connection / Library / Browse / Downloads
```

The plugin should not try to clone Suwayomi-WebUI, and it should not try to become a custom manga reader. KOReader already owns the reading experience, including CBZ rendering, page navigation, zoom/crop behavior, bookmarks, history, gestures, and file-manager access. This plugin owns the Suwayomi-side client work around library navigation, source discovery, device-local downloads, and read-state reconciliation.

For the first remote-source release, prioritize this scenario:

1. Remote sources are already installed and enabled on the Suwayomi server.
2. The reader searches across enabled sources, or searches/browses within one source.
3. The reader opens a manga chapter list.
4. The reader filters the chapter list by scanlator/translation group when duplicate translations exist.
5. The reader marks already-read chapters as read, either selected chapters or everything before/through a chapter.
6. The reader downloads the whole manga, all unread chapters, or a one-shot next-chapter batch.
7. The reader can enable a download-ahead buffer that queues only missing downloads for the next unread window.
8. After reading, the plugin best-effort syncs read state.

## Reading Boundary

The intended reading model is:

```text
Suwayomi plugin chooses and downloads manga -> KOReader file manager / reader opens local CBZ files
```

The plugin may keep small convenience actions such as `Open`, `Open first unread`, or `Open manga folder`, but those actions should only hand a local file or folder to KOReader. They should not grow into an in-plugin reader, page streaming UI, reader event loop, custom navigation stack, or replacement for KOReader's document features.

This boundary is intentional. Earlier experiments toward a full manga-reader experience proved expensive, and other KOReader plugins show the same split: catalog/download plugins hand files to KOReader, while true reader plugins patch KOReader's reader modules directly. For this plugin, the lower-risk path is to make local files, queue state, and sync state reliable, then let KOReader do what it already does well.

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
- [x] Chapter actions: open local CBZ in KOReader, download, delete from device, mark read/unread
- [x] Chapter selection mode
- [x] Bulk chapter actions
- [x] Bulk policies: one-shot download next batches, download-ahead missing-buffer refills, delete read downloaded chapters
- [x] Read-state reconciliation from Suwayomi, KOReader metadata, and the plugin ledger
- [x] Background retry for pending read/unread sync
- [x] Manual read-state sync action
- [x] App Store installation path

Current limitations:

- Downloads is first-class for active, queued, and failed KOReader-local jobs, but it does not persist completed history.
- Source manga browsing supports Popular, Latest where available, Search, and result pagination.
- Global search and source search are implemented for visible Browse sources.
- Library membership can be managed from KOReader through manga actions.
- Manga-level actions expose chapter-list, refresh, library membership, and existing download/read helpers.
- Chapter API requests preserve scanlator data, and chapter lists can be filtered by scanlator/translation group.
- Read-download cleanup is available as an explicit local action rather than an automatic delete-while-reading toggle.
- Full dynamic source filter editing is deferred.
- Remote source workflow verification has started. A Boox Palma live pass verified Comick Latest -> chapter list -> scanlator filter -> read-state toggles -> local CBZ download/open. Source-specific result loading is now cancellable in unit-covered flows, but slow source/search behavior still needs device validation against real extensions.
- The codebase is now split into facades/controllers/submodules; the next risk is validating the unit-covered remote-source flows on real sources and devices.

## Suwayomi-WebUI Alignment Review

Reviewed upstream [Suwayomi-WebUI](https://github.com/Suwayomi/Suwayomi-WebUI) at commit `f7801de750e24722a2d95398df12205a677fcb42`.

Use WebUI actions and naming as the default reference when the action makes sense on an e-ink KOReader device, but keep KOReader-specific ownership explicit:

- Library and manga cards: WebUI exposes category tabs, search/global search, filter/sort/display controls, selection mode, and manga actions for download, delete downloaded chapters, mark read/unread, migrate, track, change categories, and remove from library. For the KOReader release, mirror the useful reading/offline actions first: download variants, mark read/unread, add/remove library, refresh, and device-local cleanup. Defer migrate, tracker, category editing, and full library filter/sort/display parity.
- Browse and sources: WebUI exposes enabled/language-filtered source lists, global search, source pinning, source Popular/Latest/Filter modes, source filters, saved searches, extension management, and in-library result markers. For the KOReader release, implement global search, one-source search, Popular/Latest, pagination, language/NSFW visibility, in-library markers, and basic extension install/update/uninstall. Defer source pinning, saved searches, source configuration, extension repository management, and the full dynamic filter editor.
- Manga details and chapters: WebUI refreshes uninitialized manga, has a refresh action, shows the first unread/continue affordance, filters chapters by unread/downloaded/bookmarked/scanlator, sorts by source/chapter/upload/fetched, and exposes chapter actions for download, delete, bookmark, mark read/unread, mark previous as read, and browser/webview opens. For KOReader, prioritize refresh, first unread/open local CBZ, scanlator filtering, read/unread actions, selected/bulk actions, and local download/delete. Defer server-side bookmarks and browser/webview actions.
- Downloads: WebUI manages Suwayomi's server-side queue with start/stop, clear all, reorder, remove, retry, server download settings, download-ahead, and delete-while-reading settings. This plugin's Downloads surface remains KOReader-device-local. Mirror the intent of download-ahead and delete-while-reading through local policies, but do not mutate or present Suwayomi server downloads as KOReader-local availability.

## Phase 1: Refactor For Client Work

Goal: create small homes for path and client orchestration before adding more behavior to `main.lua`.

### 1.1 Source-scoped paths

- [x] Add `suwayomi/paths.lua`
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

- [x] Add `suwayomi/client.lua`
- [x] Move small existing browse orchestration pieces out of `main.lua` when it reduces pressure
- [x] Keep plugin lifecycle, main menu registration, and KOReader integration in `main.lua`
- [x] Keep API parsing in `suwayomi/api/parsers.lua` behind the `suwayomi/api.lua` facade
- [x] Keep KOReader menu/dialog construction in `suwayomi/ui.lua` and its `suwayomi/ui/` submodules
- [x] Keep queue mechanics behind the `suwayomi/downloads/queue.lua` facade
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

Goal: make `Library` the primary manga selection and local-download entry point.

- [x] Fetch categories when opening Library
- [x] If multiple categories exist, show a category picker
- [x] If only the default category exists, go directly to manga list
- [x] Fetch library manga for the selected category or all manga
- [x] Add compact library manga rows with:
  - title
  - unread count
  - source label
  - optional KOReader-local availability computed from source-scoped paths
- [x] Open selected library manga through the existing chapter list screen
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

- A user can open KOReader, enter Suwayomi Library, choose manga, and use existing chapter/download actions.

## Phase 5: Downloads Surface

Goal: make the existing KOReader-local download queue inspectable and manageable from the top level.

- [x] Add top-level `Downloads` menu implementation
- [x] Read active and queued items from `suwayomi/downloads/queue.lua`
- [x] Surface failed items with last error where available
- [x] Skip completed history because completed jobs are not persisted
- [x] Add compact rows with status, manga title, and chapter name
- [x] Add retry for failed local downloads
- [x] Add clear failed
- [x] Add cancel queued item when supported by the queue
- [x] Skip clear completed history because completed history is not tracked
- [x] Add open manga/chapter-list context for queue items when enough metadata exists
- [x] Keep Suwayomi server downloader mutations out of this surface
- [x] Keep Downloads settings out of this surface by product choice:
  - KOReader download directory remains under Settings -> Downloads
  - max parallel device downloads remains under Settings -> Downloads
  - source-scoped layout remains documented/read-only outside the queue screen

Tests:

- [x] Downloads menu groups active, queued, and failed items where state exists
- [x] Failed rows expose retry
- [x] Clear failed calls local queue cleanup only
- [x] Cancel queued item calls local queue cancellation only
- [x] Skip Downloads settings routing because settings stay out of the queue screen
- [x] Suwayomi server `downloadCount` is not used as KOReader-local availability

Exit criteria:

- A user can inspect the local queue, retry failed local downloads, cancel queued local downloads, clear failed items, and jump from queued items back to manga context without drilling into manga chapter lists first. Download settings intentionally remain under Settings -> Downloads.

## Phase 6: Manga And Chapter-Level Client Actions

Goal: add WebUI-inspired manga and chapter actions that fit the Library, Browse, and KOReader-local reading workflow.

- [x] Add manga action menu
- [x] Reuse the same manga action menu from Library rows, Browse results, Downloads context jumps, and manga detail/chapter-list entry points
- [x] Group actions with short labels that resemble WebUI where they fit:
  - Open
  - Refresh
  - Library
  - Read state
  - Downloads
  - Device cleanup
- [x] Add `Open chapter list`
- [x] Add `Refresh manga and chapters`
- [x] Refresh uninitialized manga before opening chapters when possible
- [x] Add `Add to library`
- [x] Add `Remove from library` with confirmation
- [x] Add `Open first unread in KOReader` when the first unread chapter is locally available
- [x] Add `Download first unread`
- [x] Add one-shot `Download next 5/10/50`, preserving the existing queue cap behavior
- [x] Add `Download all unread` with confirmation and queue cap/chunking feedback
- [x] Add `Download all chapters` / whole manga with confirmation and queue cap/chunking feedback
- [x] Add `Keep next 5/10/50 downloaded` download-ahead queue actions
- [x] Add `Delete read downloaded chapters from device`
- [x] Add explicit removal of read local downloads without deleting active downloads
- [x] Preserve scanlator on parsed chapter nodes
- [x] Add chapter-list filter by scanlator/translation group
- [x] Keep existing selected-chapter and mark previous/through-here actions available because they cover the "already read this far" setup flow
- [ ] Consider manga-level `Mark all read` / `Mark all unread` only if it can share existing selected/bulk read-state helpers safely
- [x] Refresh visible row state after add/remove/refresh when possible

Tests:

- [x] Manga action menu construction
- [x] Remove-from-library confirmation
- [x] Add/remove library calls the mutation helper
- [x] Uninitialized manga refreshes before chapter open
- [x] First-unread actions select the expected chapter
- [x] Existing bulk policies can be triggered from manga-level actions
- [x] `Download all unread` and whole-manga downloads respect confirmation and queue cap/chunking behavior
- [x] `Download ahead` actions persist per manga and refill missing unread-buffer downloads after chapters are marked read
- [x] Explicit read-download removal deletes only read KOReader-local files and skips active downloads
- [x] Chapter parser preserves scanlator
- [x] Chapter-list scanlator filter hides only matching translation groups

Exit criteria:

- [x] Library and Browse entries are useful without drilling into individual chapters first.
- [x] Library membership can be managed from KOReader.
- [x] The basic release flow can set read state, filter duplicate translations, queue offline reading, and clean up read local files.
- [x] Reader-like behavior remains limited to opening already-downloaded local files in KOReader.

## Phase 7: Browse And Search Surface

Goal: make remote source discovery usable enough to find manga, add it, and open its chapter list without leaving KOReader.

- [x] Selecting Browse opens enabled sources grouped or filtered by language
- [x] Apply Browse settings:
  - source languages
  - show/hide NSFW sources when metadata exists
  - hide in-library manga from source results, optional
- [x] Add global search across enabled visible sources:
  - ask for one query
  - search sources allowed by Browse settings
  - show per-source result groups, or per-source rows with first results and error/empty state
  - allow opening a source-specific result page for more matches
- [x] Keep global search requests cancellable or bounded so slow sources do not freeze the device
- [x] Selecting a source opens a mode menu:
  - Popular
  - Latest, only when supported
  - Search
- [x] Keep direct Local source listing if it remains clearer
- [x] Add text input for global search and source search
- [x] Fetch source manga with selected mode and page
- [x] Add result rows with library markers
- [x] Add `Next page` when `hasNextPage` is true
- [x] Add `Previous page` when page is greater than 1
- [x] Preserve current source/mode/query/page context while paging
- [x] Selecting a result opens manga actions:
  - Open chapter list
  - Add to library
  - Remove from library
  - Refresh details/chapters
  - Download/read-state actions through the shared manga action menu when chapter data is available
- [x] Keep title-bar home behavior on Browse source menu, source mode menu, source result pages, and global search result pages
- [x] Keep chapter/list/download/read-state actions unchanged once manga actions open
- [x] Keep full source filter editing deferred; source-specific search may pass no filters until a small KOReader-friendly filter subset is designed
- [ ] Add a KOReader-friendly source filter subset after remote-source behavior is verified

Tests:

- [x] Browse source list respects language settings
- [x] Global search respects language, enabled-source, and NSFW visibility settings
- [x] Global search keeps per-source errors isolated
- [x] Global search result opens source-specific results or manga actions
- [x] Source mode menu construction
- [x] Search prompt calls `SEARCH`
- [x] Popular and latest call the correct modes
- [x] Latest is hidden or rejected when unsupported
- [x] Next/previous page update result context
- [x] Search results show library state
- [x] Optional hide-in-library setting filters visible results only where intended
- [x] Add/remove from source results updates visible state
- [x] Title-bar home behavior remains available on Browse source, source mode, source result, and global search result menus
- [x] Manga actions continue to own chapter/list/download/read-state behavior after opening from Browse results

Exit criteria:

- A user can search across sources or within one source, page results, add a manga to the library, and open its chapter list in unit-covered flows. Global search is cancellable and isolates per-source failures. Source-specific result loading is also cancellable in unit-covered flows, while live remote-source verification still needs to cover slow extensions.

## Phase 8: Remote Source Verification

Goal: prove the client MVP works with real remote source flows and the first release scenario.

- [ ] Verify end-to-end release scenario:
  - [ ] global search or source search
  - [x] open manga chapter list
  - [x] filter by scanlator/translation group
  - [x] mark individual chapters read/unread
  - [ ] mark selected/previous chapters read
  - [ ] download whole manga or all unread chapters
  - [ ] queue missing downloads for a download-ahead unread window
  - [x] read/open local CBZ in KOReader
  - [ ] best-effort read sync
- [ ] Verify MangaDex search, library add/remove, refresh, chapter listing, and download
  - [x] Search returned results quickly on the tested server.
  - [x] Add/remove library worked for the tested MangaDex result.
  - [ ] Refresh/chapter listing/download remain source-data blocked for one tested result: direct GraphQL returned `No chapters found`.
- [ ] Verify Comick search, library add/remove, refresh, chapter listing, and download
  - [ ] Text search timed out on the tested server after about 60 seconds with `wantread` in KOReader and HTTP 504 through direct GraphQL.
  - [x] Latest returned 54 results over 4 pages.
  - [x] A manga selected from Latest refreshed/opened chapters successfully.
  - [x] Scanlator filter exposed duplicate translation groups.
  - [x] Single-chapter download completed and opened in KOReader.
- [ ] Verify Local source still works with source-scoped paths
- [ ] Confirm Downloads shows KOReader-local queue state
- [x] Confirm KOReader-local download does not call Suwayomi server download queue mutations
- [x] Confirm server-side downloaded state is not treated as KOReader-local availability
- [x] Confirm downloaded CBZ chapters can be opened from KOReader's normal file manager
- [x] Confirm plugin `Open` actions remain shortcuts into KOReader rather than custom reader flows
- [x] Confirm Settings exposes Connection, Library, Browse, and Downloads on device
- [x] Document any source-specific quirks in debug notes or README
- [ ] Add regression tests for any live-server bug that can be reasonably reproduced in unit tests

Exit criteria:

- Remote source browse/latest support can be described as usable for the tested Comick flow.
- The release scenario works on at least one remote source with duplicate scanlator/translation choices for chapter listing, filtering, read-state toggles, single-chapter download, and open-local-CBZ.
- The README no longer describes the practical flow as limited to Local Source, but it documents remote source quirks and the distinction between cancellable global search and source-specific timeouts.

## Phase 9: Documentation And Release Polish

Goal: keep public documentation aligned with the client MVP.

- [x] Update README feature list
- [x] Update README usage flow to start with Library, Browse, and Downloads
- [x] Document grouped Settings
- [x] Document source-scoped download layout
- [x] Document that KOReader downloads are device-local, not Suwayomi server downloads
- [x] Document that normal reading happens through KOReader's file manager/reader, not inside the plugin
- [x] Document unsupported/deferred features:
  - full source filters
  - source preferences
  - custom in-plugin manga reader
  - extension repository management
  - server-side download queue management
  - server-side download settings
  - per-source download directory overrides
- [ ] Add screenshots or short demo media if useful
- [x] Improve debug logging guidance for remote source failures
- [ ] Add release notes/changelog entry

Exit criteria:

- The shipped behavior, README, spec, and roadmap tell the same story.

## Deferred Ideas

These are intentionally outside the client MVP:

- Full dynamic source filter editor
- Saved source searches
- Source pinning and WebUI-style source enable/disable management
- Source configuration/preferences UI
- Category assignment during add-to-library
- Manga category editing from KOReader
- Category create/rename/reorder/delete
- Per-source download directory overrides
- Server-side `Download on server` action
- Server-side download queue inspection/management
- Server-side download queue reorder/start-stop/clear-all controls
- Server-side download settings, including Suwayomi server download path
- Extension repository management
- Server local-source path management
- Source preference editor
- Migration between sources
- Duplicate manga manager
- Tracker integration
- Server-side chapter bookmark/unbookmark actions
- Full Library filter/sort/display parity with WebUI
- Cover grid UI
- OPDS support
- Custom in-plugin manga reader
- Page streaming reader
- ReaderUI end-of-book automation beyond lightweight read-state reconciliation
- Backup/restore

## Recommended Order

1. Source-scoped path module
2. Thin client orchestration module
3. Navigation and grouped Settings shell
4. Client API foundation
5. Library surface
6. Downloads surface
7. Manga/chapter-level actions, scanlator filtering, and local download policies
8. Browse and search surface
9. Live remote-source release-scenario verification
10. README and release polish

## Current Next Step

Validate source-specific remote search timeout and cancellation behavior on device with slow extensions, and keep validating cancellable global search. One source timeout should not block the KOReader UI for about a minute. Keep full source filters deferred until the tested remote-source behavior is stable.
