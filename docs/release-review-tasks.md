# Release Review Tasks

Created from the 2026-05-16 read-only release review. Each item captures the
risk, likely fix direction, and test coverage expected before release.

Baseline at review time:

- `luacheck --codes spec suwayomi main.lua _meta.lua` -> 119 files clean
- `busted spec` -> 451 successes

## P1 Release Blockers

- [x] **Fix IPv6 same-origin auth checks**
  - Files: `suwayomi/api/transport.lua`
  - Risk: `parseOrigin()` can mis-parse bracketed IPv6 hosts, so `downloadBinary()` may send Basic auth to a wrong IPv6 origin.
  - Direction: parse bracketed IPv6 plus port exactly and default-deny auth on parse failure.
  - Test: cover `[::1]:4567` same-origin auth and `[::2]:9999` no-auth behavior.

- [x] **Add byte cap to direct archive downloads**
  - Files: `suwayomi/api/transport.lua`
  - Risk: bad or oversized archive response can fill device storage before timeout.
  - Direction: enforce a maximum byte count in the archive sink and remove partial output on cap hit.
  - Test: stream chunks over the cap and assert failure plus partial cleanup.

- [x] **Preserve source cache when extension refresh partially fails**
  - Files: `suwayomi/browse/extension_worker.lua`, `suwayomi/browse/extensions.lua`
  - Risk: install/update/uninstall success followed by `fetchSources()` failure saves an empty source cache and empties the source menu.
  - Direction: carry source refresh success/error separately and only save/refresh source cache when source refresh succeeds.
  - Test: extension update succeeds, extension refresh succeeds, source refresh times out; assert old source cache/menu remains.

- [x] **Scope thumbnail cache by account**
  - Files: `suwayomi/ui/thumbnail_cache.lua`
  - Risk: switching accounts on the same Suwayomi host can reuse cached covers from the previous account.
  - Direction: include non-secret auth scope such as auth method and username in the thumbnail cache key.
  - Test: same server and thumbnail URL with different usernames produce different cache paths.

- [x] **Run tracked close callbacks during navigation close-all**
  - Files: `suwayomi/navigation.lua`
  - Risk: `closeAll()` can skip original close callbacks, leaving async workers alive after screens close.
  - Direction: avoid recursive navigator pop while still calling the original close callback exactly once.
  - Test: `closeAll()` closes tracked widgets and invokes the original callback.

- [x] **Keep live download queue when changing parallel download count**
  - Files: `suwayomi/plugin/settings_controller.lua`, `suwayomi/downloads/queue.lua`
  - Risk: saving the parallel-download setting drops the live queue while subprocesses may keep running unmanaged.
  - Direction: update the active queue limit in place and call `process()`, or recreate with explicit cancel/recover handoff.
  - Test: changing the setting retains the same queue object and updates `max_active_chapters`.

- [x] **Deduplicate recovered download jobs before starting workers**
  - Files: `suwayomi/downloads/active_jobs.lua`, `suwayomi/downloads/queue.lua`, `suwayomi/downloads/job_store.lua`
  - Risk: duplicate persisted keys can start duplicate subprocesses writing the same progress file, partial archive, and CBZ.
  - Direction: dedupe persisted jobs by key during recovery and skip queued/active duplicates before launch.
  - Test: duplicate persisted `downloading` jobs with `max_active_chapters = 2` start only one subprocess.

- [x] **Normalize missing or malformed network worker results**
  - Files: `suwayomi/network/request_worker.lua`
  - Risk: child crash, missing result file, or partial JSON can close loading UI with no user-facing failure.
  - Direction: convert unreadable or malformed results to `{ ok = false, error = "Could not complete network request." }`.
  - Test: missing file and malformed JSON both surface a normalized error.

- [x] **Fix KOReader metadata sidecar path**
  - Files: `suwayomi/readsync/koreader_metadata.lua`
  - Risk: sidecar writes appear to target `metadata.<ext>.lua`, while KOReader uses `<book>.sdr/metadata.lua`; local read/unread updates can be ignored.
  - Direction: use KOReader docsettings helper or derive `<base>.sdr/metadata.lua`.
  - Test: `/books/ch1.cbz` maps to `/books/ch1.sdr/metadata.lua`.

- [x] **Revalidate reader-return token inside deferred callback**
  - Files: `suwayomi/reader_return.lua`
  - Risk: stale reader-return result can close the current reader and show the wrong manga after user changes book/request between finish and `nextTick`.
  - Direction: keep the token active until deferred callback runs and recheck token plus context before side effects.
  - Test: older request finishes, newer context wins, deferred old callback performs no close/show.

## P2 Important Fixes

- [x] **Reject malformed page URLs without crashing**
  - Files: `suwayomi/api/transport.lua`
  - Risk: non-string page URL can crash download flow.
  - Direction: normalize or validate path before `match()` and return API-style failure for invalid values.
  - Test: non-string page URL returns a download error.

- [x] **Ignore corrupt non-table source rows**
  - Files: `suwayomi/browse/source_catalog.lua`
  - Risk: corrupt source cache/result rows can crash Browse filtering.
  - Direction: reject non-table source values before language and setting checks.
  - Test: mixed invalid rows plus one valid source renders only the valid row.

- [x] **Fence stale source manga worker results**
  - Files: `suwayomi/client/source_manga.lua`
  - Risk: older worker can update an old browse menu after the user starts another source/search/page load.
  - Direction: track current source-load token, cancel previous active job, and ignore non-current finish/timeout.
  - Test: two loads finish out of order; older result does not update the menu.

- [x] **Protect source manga and global search job startup**
  - Files: `suwayomi/client/source_manga.lua`, `suwayomi/client/global_search.lua`
  - Risk: launcher exception can leave loading/search UI stuck or abort queued global sources.
  - Direction: wrap `job.start` in `pcall`, render an error for source manga, and mark failed global sources while continuing.
  - Test: fake `job.start` throws in both flows.

- [ ] **Disable selection on informational rows**
  - Files: `suwayomi/ui/list_rows.lua`, `suwayomi/ui/downloads.lua`
  - Risk: empty/error/searching rows are selectable despite no useful action.
  - Direction: set `select_enabled = false` on non-openable summary and info rows.
  - Test: selecting those rows does not close or navigate the menu.

- [ ] **Clean partial archives on cancel and watchdog failure**
  - Files: `suwayomi/downloads/active_jobs.lua`, `suwayomi/downloads/downloader.lua`
  - Risk: canceled or timed-out downloads leave stale `.part` and `.direct.part` files.
  - Direction: remove both page and direct partial paths when active jobs are terminated as failures.
  - Test: cancel and watchdog paths remove both partial variants.

- [ ] **Strip control characters from path segments**
  - Files: `suwayomi/paths.lua`, `suwayomi/downloads/progress_file.lua`
  - Risk: manga/chapter/source metadata with newlines can corrupt progress files and create hostile filenames.
  - Direction: strip or map control characters in sanitized path segments and keep progress values line-safe.
  - Test: title containing `\nstate=failed\npath=x` cannot alter parsed progress state.

- [ ] **Validate direct archive bytes before final CBZ rename**
  - Files: `suwayomi/downloads/downloader.lua`, `suwayomi/api/transport.lua`
  - Risk: server/proxy can return non-ZIP bytes with `application/zip`, producing a bad downloaded CBZ.
  - Direction: verify ZIP signature/structure before finalize, or expose enough bytes from transport for validation.
  - Test: direct endpoint returns `application/zip` plus non-ZIP body and downloader falls back or fails safely.

- [ ] **Confirm selected-chapter deletion**
  - Files: `suwayomi/chapters/actions.lua`
  - Risk: one bulk-menu tap can delete many local archives, sidecars, and ledger paths.
  - Direction: add confirmation with selected count before `deleteSelectedChapters()`.
  - Test: selected delete does not call `os.remove` until confirmation callback runs.

- [ ] **Avoid stale scanlator filter for manga-level download actions**
  - Files: `suwayomi/chapters/context.lua`
  - Risk: manga-level "Download next" and "Download ahead" can silently skip unread chapters outside a previous scanlator filter.
  - Direction: add an unfiltered helper or `ignore_filter` option for manga-level actions.
  - Test: active `current_scanlator_filter` does not scope manga-level download actions.

- [ ] **Check subprocess JSON write and close failures**
  - Files: `suwayomi/subprocess/job.lua`
  - Risk: disk-full or close errors can publish empty/truncated JSON.
  - Direction: check `handle:write()` and `handle:close()` results, remove temp output on failure, and return false.
  - Test: simulated write and close failures do not leave final result files.

- [ ] **Bound UI-thread result decode cost**
  - Files: `suwayomi/subprocess/job.lua`, `suwayomi/network/request_worker.lua`, library request callers
  - Risk: huge worker result files can still freeze KOReader while the UI thread reads and decodes JSON.
  - Direction: cap result payload size, chunk large library results, or add measured decode guardrails.
  - Test: large-result stress test verifies payload size or decode-time bound.

- [ ] **Harden debug redaction**
  - Files: `suwayomi/debug.lua`
  - Risk: QA debug logs can leak search terms, paths, URLs, server URL, titles, tokens, cookies, or secrets.
  - Direction: prefer safe-field allowlist or redact/hash user-data fields.
  - Test: `query`, `path`, `server_url`, `token`, `secret`, and `cookie` are redacted while counts/status remain visible.

- [ ] **Normalize credentials on load and save**
  - Files: `suwayomi/settings.lua`
  - Risk: corrupt `credentials` shape can crash startup, and unsupported `auth_method` can silently disable Basic Auth.
  - Direction: add shared credential normalization with table guard, URL/string normalization, and auth enum defaulting.
  - Test: non-table credentials and `auth_method = "bad"` load safely with expected defaults.

- [ ] **Reload credentials during read-sync retries**
  - Files: `suwayomi/readsync/controller.lua`
  - Risk: retry loop can keep an empty credentials table captured before login and never pick up later saved settings.
  - Direction: reload settings on each retry or stop retrying when server URL is missing.
  - Test: first retry sees empty URL, second retry sees saved valid URL and starts worker.

- [ ] **Clear pending read-sync when remote already matches**
  - Files: `suwayomi/readsync/ledger.lua`
  - Risk: pending read-sync state can linger when fresh Suwayomi chapter state already equals desired state.
  - Direction: clear pending fields during merge when remote state matches `pending_read_state`.
  - Test: merge with matching remote read state removes pending flags.

- [ ] **Gate release upload on lint and specs**
  - Files: `.github/workflows/release.yml`, `.github/workflows/test.yml`
  - Risk: tag release can publish `suwayomi_dl.koplugin.zip` without running the same checks as PR/branch CI.
  - Direction: add a test job to the release workflow or share the test workflow before build/upload.
  - Test: release workflow fails before upload when lint/spec fails.

## P3 Polish

- [ ] **Ignore late global-search finish after timeout**
  - Files: `suwayomi/client/global_search.lua`
  - Risk: future or fake job helper can flip a timed-out summary back to success.
  - Direction: return from finish when active job is canceled or summary no longer says `searching`.
  - Test: timeout then finish leaves row in timed-out state.

- [ ] **Wire or remove title-bar left-hold plumbing**
  - Files: `suwayomi/ui/browse.lua`, `suwayomi/ui/menu_utils.lua`
  - Risk: callers can pass `on_title_bar_left_hold`, but no UI binding appears to invoke it.
  - Direction: wire the KOReader hold hook if supported, or remove the dead option path.
  - Test: title-bar hold callback is invoked, or API no longer advertises it.

- [ ] **Report skipped and failed delete-read cleanup counts**
  - Files: `suwayomi/chapters/actions.lua`
  - Risk: cleanup message can say only "Deleted N chapters" even when active, missing, or failed paths were skipped.
  - Direction: include skipped, active, missing, and failed counts in the user message.
  - Test: failed `os.remove` and active download cases produce accurate summary text.
