# Release Review Task List

Prepared for release hardening on 2026-05-15 from a read-only architect split
and Staff Software Engineer module review. No fixes are included here.

Fresh local verification from the review worktree:

- `luacheck --codes spec suwayomi main.lua _meta.lua`: 119 files clean
- `busted spec`: 451 successes

## P1 Release Blockers

- [x] Fix source fetch timeout cleanup.
  - Area: `suwayomi/browse/controller.lua:83`
  - Risk: a hung source fetch can leave `source_fetch_active` set and keep Browse
    stuck until restart.
  - Direction: add timeout/cleanup callbacks that clear active state, close loading
    UI, and surface a user-visible error.
  - Tests: add a timeout spec covering active-state cleanup and later Browse retry.

- [x] Fix extension worker timeout cleanup.
  - Area: `suwayomi/browse/extensions.lua:123`
  - Risk: timed-out extension fetch/install/update/uninstall can block all later
    extension actions.
  - Direction: add the same cleanup path as source fetch, with action-aware error
    text.
  - Tests: add timeout specs for fetch and one mutation action.

- [x] Prevent duplicate active download jobs for the same chapter.
  - Area: `suwayomi/downloads/active_jobs.lua:173`
  - Risk: duplicate recovered or persisted jobs can launch two subprocesses for
    the same chapter, corrupting `.cbz` or leaving an orphan worker.
  - Direction: de-duplicate recovered queue items by key and skip starting when
    the key is already active.
  - Tests: add recovery specs with duplicate queued/downloading jobs for one key.

- [x] Check archive writer close before final rename.
  - Area: `suwayomi/downloads/downloader.lua:333`
  - Risk: disk-full or zip footer write failure can be reported only by `close()`;
    ignoring it can publish a corrupt final `.cbz`.
  - Direction: make close a checked helper and fail with cleanup when it returns
    false/nil plus error or throws.
  - Tests: add disk-full or close-failure specs.

- [x] Normalize persisted credentials before use.
  - Area: `suwayomi/settings.lua:142`
  - Risk: corrupt or old scalar settings can crash login/read-sync before the UI
    can recover.
  - Direction: type-normalize credentials to the default table and coerce string
    fields.
  - Tests: add invalid persisted credential specs.

- [x] Normalize persisted chapter ledger before use.
  - Area: `suwayomi/settings.lua:319`
  - Risk: non-table or corrupt ledger data can crash chapter menu, close-document
    sync, or pending replay.
  - Direction: normalize ledger to `{}`, drop non-table entries, and coerce key
    fields at the settings/read-sync boundary.
  - Tests: add schema-drift specs for non-table and malformed entries.

- [x] Preserve active queue when changing parallel download setting.
  - Area: `suwayomi/plugin/settings_controller.lua:103`
  - Risk: setting `self.download_queue = nil` can abandon active/queued in-memory
    jobs while subprocesses continue.
  - Direction: mutate the existing queue's `max_active_chapters` in place and
    call `process()`, or migrate/recover active state before replacement.
  - Tests: cover setting change with active and queued jobs.

- [x] Ensure download-open path participates in read-sync ledger.
  - Areas: `main.lua:79`, `suwayomi/readsync/controller.lua:274`
  - Risk: download -> open -> finish before a full chapter rebuild can skip server
    read-sync and delete-while-reading cleanup because `onCloseDocument()` scans
    only ledger entries.
  - Direction: upsert ledger with path and ids when an archive is ready/opened, or
    make close path fall back to reader-return context and create a ledger entry.
  - Tests: add close-document sync spec for downloaded chapter opened directly.

## P2 Important

- [ ] Add legacy fallback for extension GraphQL fields.
  - Area: `suwayomi/api/queries.lua:21`
  - Risk: older Suwayomi schemas can reject `iconUrl`, `apkName`, or `repo` and
    break extension list/install/update.
  - Direction: retry with a lean extension field set on optional-field validation
    errors.

- [ ] Add byte limits to direct archive download.
  - Area: `suwayomi/api/transport.lua:374`
  - Risk: a bad server can fill device storage before cleanup.
  - Direction: reject oversized `Content-Length` and stop file sink after a
    configured maximum byte count.

- [ ] Validate page URLs before URL joining.
  - Area: `suwayomi/api/transport.lua:147`
  - Risk: malformed or non-string page entries can crash a worker instead of
    producing a clean download error.
  - Direction: validate in parser or `downloadBinary()` before `buildRequestURL()`.

- [ ] Make chapter archive filenames collision-safe.
  - Area: `suwayomi/paths.lua:61`
  - Risk: duplicate chapter names under one manga/source can collide, causing
    skipped, overwritten, or wrong opened chapters.
  - Direction: include a stable id/order suffix on collision, or use an id-aware
    naming rule with migration care.

- [ ] Make progress filenames collision-safe.
  - Area: `suwayomi/downloads/progress_file.lua:14`
  - Risk: sanitizer collisions for Unicode or no-id jobs can make active jobs read
    each other's progress.
  - Direction: encode or hash the full queue key and clean up old paths if needed.

- [ ] Protect archive writer close on failure paths.
  - Area: `suwayomi/downloads/downloader.lua:303`
  - Risk: a throwing `close()` can skip partial cleanup and progress error writes.
  - Direction: wrap `close()` in `pcall`, always cleanup partial on failure, and
    surface the close error.

- [ ] Release subprocess slots only after child cleanup.
  - Areas: `suwayomi/client/global_search.lua:242`,
    `suwayomi/client/browse_chapter_counts.lua:114`
  - Risk: repeated slow sources can exceed configured subprocess caps on device.
  - Direction: keep timed-out jobs counted until cleanup/reap, or start the next
    job from cleanup callback.

- [ ] Normalize source fetch worker errors.
  - Area: `suwayomi/browse/source_fetch_worker.lua:36`
  - Risk: thrown API/client errors can produce no result file and lose root cause.
  - Direction: wrap the worker body in `pcall` and always write a normalized
    `{ ok = false, error = ... }` result.

- [ ] Normalize extension worker errors.
  - Area: `suwayomi/browse/extension_worker.lua:106`
  - Risk: server/client exceptions after partial actions can produce no precise
    recovery state.
  - Direction: wrap fetch/install/update/uninstall paths and include action in the
    error result.

- [ ] Avoid retrying read-sync when credentials are missing.
  - Area: `suwayomi/readsync/controller.lua:73`
  - Risk: pending ledger can retry forever with no usable server URL.
  - Direction: classify missing credentials as blocked until settings change or
    manual sync.

- [ ] Reload credentials for read-sync retry.
  - Area: `suwayomi/readsync/controller.lua:189`
  - Risk: automatic retries can keep using stale credentials after the user fixes
    server/auth settings.
  - Direction: reload credentials per retry or cancel scheduled retry on settings
    save.

- [ ] Expand debug redaction for release QA logs.
  - Areas: `suwayomi/debug.lua:93`, `suwayomi/client/global_search.lua:286`
  - Risk: debug logs can persist server URLs, usernames, filesystem paths, titles,
    source names, and search queries.
  - Direction: expand key denylist, redact URL/path-like scalar values, and avoid
    logging raw global-search queries.

- [ ] Resume thumbnail queue after thumbnail timeout.
  - Area: `suwayomi/ui/list_menu.lua:663`
  - Risk: slow first visible thumbnail jobs can stall later visible thumbnail
    loading until user forces redraw.
  - Direction: mirror finish path by marking failure and calling `updateItems()`.

- [ ] Schedule Back action through `nextTick`.
  - Area: `suwayomi/ui.lua:189`
  - Risk: nested action menus can reopen parent while `ButtonDialog` focus/close
    is still settling.
  - Direction: use the same `UIManager:nextTick` pattern as normal actions.

- [ ] Stop silent source refresh from reopening closed Sources UI.
  - Area: `suwayomi/browse/source_catalog.lua:357`
  - Risk: cached source refresh can pop Sources back onto screen after user has
    navigated away.
  - Direction: for silent refresh, save cache/log but only update an existing menu.

- [ ] Ignore stale source refresh results after credential/server changes.
  - Area: `suwayomi/browse/source_catalog.lua:357`
  - Risk: old worker results can redraw wrong sources and thumbnail credentials
    after server/settings switch.
  - Direction: compare worker credentials/server generation before UI update.

- [ ] Thread `onMangaUpdated` through chapter refresh action.
  - Area: `suwayomi/manga/controller.lua:523`
  - Risk: refreshed title/chapter metadata can leave browse/library/search parent
    rows stale.
  - Direction: pass options through refresh helpers and notify parent after result
    application.

- [ ] Make scanlator-filtered "mark previous" respect visible chapters.
  - Area: `suwayomi/chapters/context.lua:292`
  - Risk: filtered view can mark hidden scanlator chapters read and sync wrong
    server state.
  - Direction: compute before/through over visible chapters or pass visible list
    from menu action.

- [ ] Partition source and thumbnail caches by auth identity.
  - Areas: `suwayomi/ui/thumbnail_cache.lua:80`, `suwayomi/settings.lua:214`
  - Risk: same server URL with different Basic Auth user can show stale protected
    covers/icons/sources.
  - Direction: include stable auth identity hash in cache keys or clear caches
    when connection credentials change.

- [x] Harden release workflow permissions.
  - Area: `.github/workflows/release.yml:23`
  - Risk: hardened repo/org defaults can make release asset upload fail.
  - Direction: add explicit `permissions: contents: write`.

- [ ] Run lint/tests before release artifact publish.
  - Area: `.github/workflows/release.yml:16`
  - Risk: a bad tag can publish an unverified zip because `test.yml` does not run
    on tag push.
  - Direction: run the same LuaJIT `luacheck` and `busted` checks in the release
    job, or gate release on a proven Test workflow for the tag SHA.

- [ ] Fix Android performance doc push command.
  - Area: `docs/android-performance-testing.md:15`
  - Risk: `adb push .` can copy `.git`, specs, docs, CI, scratch files, or user
    data to the device plugin directory.
  - Direction: stage `_meta.lua`, `main.lua`, `README.md`, and `suwayomi/` into a
    clean temp directory before pushing.

- [ ] Fix README path for source-language filtering.
  - Area: `README.md:74`
  - Risk: users cannot find the control described under Settings > Browse because
    implementation keeps it in the Browse source-list title menu.
  - Direction: update README to actual Browse title-menu path or add a Settings
    entry.

## P3 Minor / Polish

- [ ] Validate malformed manga nodes more explicitly.
  - Area: `suwayomi/api/parsers.lua:70`
  - Risk: malformed partial GraphQL data can create bad rows or crash instead of
    producing a parser error.

- [ ] Cap or replace `loadstring` metadata/history parsing.
  - Areas: `suwayomi/readsync/koreader_metadata.lua:73`,
    `suwayomi/readsync/koreader_metadata.lua:227`
  - Risk: corrupt or huge KOReader metadata/history files can freeze plugin work.

- [ ] Bind title-bar left hold if kept as an option.
  - Area: `suwayomi/ui/menu_utils.lua:37`
  - Risk: callers can wire hold behavior that silently never fires.

- [ ] Refresh manga action menu after add/remove library.
  - Area: `suwayomi/manga/controller.lua:388`
  - Risk: open action menu can still show the old Add/Remove Library action.

- [ ] Improve delete-read-downloads result text.
  - Area: `suwayomi/chapters/actions.lua:340`
  - Risk: partial failures, active jobs, or missing files are hidden behind
    `Deleted N`.

- [ ] Update architecture map for source language ownership.
  - Area: `docs/ARCHITECTURE.md:115`
  - Risk: future changes may miss `suwayomi/source_languages.lua`.

- [ ] Update stale Android performance weak-spot notes.
  - Area: `docs/android-performance-testing.md:148`
  - Risk: QA guidance still mentions synchronous GraphQL paths that have moved to
    async workers/request jobs.

## Suggested Order

1. Fix P1 blockers that can corrupt downloads or permanently wedge UI state.
2. Fix P1 persisted-state recovery issues before broader release testing.
3. Fix P2 release workflow and Android push docs before tagging.
4. Fix P2 privacy/cache issues before sharing QA logs or multi-user servers.
5. Sweep remaining P2/P3 UX and documentation polish.
