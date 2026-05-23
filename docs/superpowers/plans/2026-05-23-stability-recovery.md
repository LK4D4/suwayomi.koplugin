# Stability And Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Priority 1 from `docs/superpowers/specs/2026-05-22-plugin-roadmap.md` concrete: golden-flow QA, documented stale-async audit, focused recovery regression pins, and normal pre-release smoke verification.

**Architecture:** Keep behavior fixes at existing owner boundaries: plugin-wide close in `main.lua`, Library async request ownership in `suwayomi/client/library.lua`, browse chapter-count state in `suwayomi/client/browse_chapter_counts.lua`, and menu thumbnail cancellation in `suwayomi/ui/list_menu.lua`. Persist human-device coverage in `docs/qa/stability-recovery-golden-flow.md` and the audit snapshot in `docs/superpowers/audits/2026-05-23-stability-recovery.md` so later parity work can check whether it is reopening known route-close, stale-worker, or queue-recovery risks.

**Tech Stack:** LuaJIT/Lua 5.1, KOReader plugin runtime, existing Suwayomi subprocess and network request helpers, Busted specs, Luacheck, release payload staging script.

---

## File Map

- Create `docs/qa/stability-recovery-golden-flow.md`: manual e-ink QA checklist for setup, Library, Browse, downloads, reader return, read sync, route close, timeout, retry, and release payload smoke.
- Create `docs/superpowers/audits/2026-05-23-stability-recovery.md`: stale async and route-close coverage map for Priority 1 surfaces, including exact specs that already protect each surface and the gaps this plan closes.
- Modify `main.lua`: cancel active Library network work when closing the whole plugin stack.
- Modify `suwayomi/client/library.lua`: add a Library request cancellation method and make Library timeout copy action-aware.
- Modify `spec/main_spec.lua`: prove plugin close cancels Library client work while `suwayomi_plugin_closing` is set.
- Modify `spec/suwayomi_client_library_spec.lua`: prove Library cancellation ignores late worker completions and Library timeout copy gives the user a next action.
- Modify `suwayomi/client/browse_chapter_counts.lua`: store a timeout-specific chapter-count error string on timed-out browse rows.
- Modify `suwayomi/ui/list_rows.lua`: display the chapter-count error string when present.
- Modify `spec/suwayomi_client_source_manga_spec.lua`: prove browse chapter-count timeout stores the action-aware error string and keeps the next worker moving.
- Modify `spec/suwayomi_ui_list_rows_spec.lua`: prove row formatting surfaces a chapter-count error string.
- Review only `suwayomi/ui/list_menu.lua` and `spec/suwayomi_ui_list_menu_spec.lua`: thumbnail timeout and close cancellation are already covered; this task adds no runtime code unless the focused test fails.

---

### Task 1: Add Golden-Flow QA Checklist

**Files:**
- Create: `docs/qa/stability-recovery-golden-flow.md`

- [ ] **Step 1: Create the QA checklist document**

Create `docs/qa/stability-recovery-golden-flow.md` with this content:

```markdown
# Stability And Recovery Golden-Flow QA

Use this checklist before large parity work and before release candidates. Keep entries factual and short. Redact server URLs, source names tied to private libraries, manga titles, chapter titles, credentials, local paths, and screenshots that expose user data.

## Environment

- [ ] KOReader device or emulator:
- [ ] Suwayomi server version:
- [ ] Plugin commit:
- [ ] Network condition: normal / slow / disconnected / reconnected
- [ ] Notes file contains no credentials, tokens, local paths, or private library names.

## Setup And Connection

- [ ] Open Suwayomi from KOReader menu.
- [ ] Complete first-run setup with valid server settings.
- [ ] Run connection test and confirm success message.
- [ ] Change server settings to an unreachable endpoint, run connection test, and confirm timeout or failure message names the connection action.
- [ ] Restore valid server settings and confirm Browse or Library can load again.

## Library Flow

- [ ] Open Library.
- [ ] Switch category when categories are present.
- [ ] Open a manga from Library.
- [ ] Refresh chapters.
- [ ] Close chapter screen with the title-bar close action.
- [ ] Reopen Library and confirm no stale chapter screen or loading result reopens.
- [ ] While Library is loading, close the plugin stack and confirm no Library result screen appears later.

## Browse And Extensions

- [ ] Open Browse with cached sources.
- [ ] Trigger source cache refresh.
- [ ] Install an extension and confirm extension list refresh plus source cache refresh result.
- [ ] Update an extension when an update is available.
- [ ] Uninstall an extension and confirm focus stays in the extension list.
- [ ] Search extensions and repeat one install or uninstall while search remains active.
- [ ] Close Browse during source loading and confirm no stale source list appears later.

## Source Search And Filters

- [ ] Open a source.
- [ ] Run source search.
- [ ] Open source filters, change one filter, and run filtered search.
- [ ] Trigger Popular and Latest for a source that supports them.
- [ ] Trigger Popular or Latest for a source that does not support the mode and confirm unsupported-flow message is specific.
- [ ] Simulate timeout or disconnected network during source search and confirm retry/edit actions are visible.
- [ ] Page through source results until chapter-count workers start and confirm stale count rows do not update after changing pages.

## Downloads And Queue Recovery

- [ ] Enqueue one chapter.
- [ ] Confirm active progress appears.
- [ ] Cancel queued download.
- [ ] Cancel active download and confirm no failed job is left for the canceled chapter.
- [ ] Enqueue a chapter, force a network failure, and confirm failed state appears.
- [ ] Retry failed download and confirm status updates.
- [ ] Clear failed downloads.
- [ ] Start a download, close KOReader or restart plugin before completion, reopen plugin, and confirm queue recovery leaves a queued/failed/recovered state instead of wedging.
- [ ] Confirm recovered archive opens when a completed CBZ exists on disk.

## Reader Return And Stack Close

- [ ] Open a downloaded CBZ from a chapter row.
- [ ] Use Suwayomi reader-return shortcut to return to the originating chapter list.
- [ ] Close the chapter list.
- [ ] Close the full plugin stack from title menu.
- [ ] Confirm no stale reader-return request reopens a chapter list after close.

## Read Sync

- [ ] Mark one chapter read.
- [ ] Mark one chapter unread.
- [ ] Trigger manual read sync.
- [ ] Disconnect network, mark a chapter read, trigger sync, and confirm pending retry remains.
- [ ] Reconnect network and confirm retry clears the pending sync state.
- [ ] Close a document and confirm document-close sync does not block KOReader.

## Pre-Release Local Gates

Run from repository root:

```bash
rtk luacheck --codes spec suwayomi main.lua _meta.lua
rtk busted spec
rtk git diff --check
bash .github/scripts/stage-release-payload.sh
```

Expected:

- Luacheck succeeds with no warnings.
- Busted suite succeeds.
- Diff check succeeds.
- Release payload contains only `_meta.lua`, `main.lua`, `README.md`, and `suwayomi/`.
- Remove generated `suwayomi.koplugin/` after staging before committing.

## Device QA Notes

Record only non-sensitive facts:

- [ ] Behavior that specs cannot cover:
- [ ] Device-only issue found:
- [ ] Follow-up issue or commit:
```

- [ ] **Step 2: Review docs diff**

Run:

```bash
rtk git diff -- docs/qa/stability-recovery-golden-flow.md
```

Expected: checklist includes every Priority 1 golden flow from `docs/superpowers/specs/2026-05-22-plugin-roadmap.md` and contains no local filesystem paths, server URLs, credentials, or private manga/source names.

- [ ] **Step 3: Commit Task 1**

Run:

```bash
rtk git add docs/qa/stability-recovery-golden-flow.md
rtk git commit -m "docs: add stability recovery QA checklist"
```

---

### Task 2: Persist The Async Stability Audit

**Files:**
- Create: `docs/superpowers/audits/2026-05-23-stability-recovery.md`

- [ ] **Step 1: Create the audit document**

Create `docs/superpowers/audits/2026-05-23-stability-recovery.md` with this content:

```markdown
# Stability And Recovery Async Audit

Scope: Priority 1 from `docs/superpowers/specs/2026-05-22-plugin-roadmap.md`.

## Summary

Most stale-result protections already live at controller/client boundaries, not in pure worker modules. The remaining concrete Priority 1 gaps are:

- Library network requests can finish after full plugin close unless the client cancels them.
- Library timeout copy is generic and does not tell the user what action to take.
- Browse chapter-count timeout state is boolean-only, so rows cannot explain that the chapter count failed while manga remains tappable.
- Golden-flow device QA existed only in roadmap prose, not in a reusable checklist.

## Coverage Map

| Surface | Owner | Existing coverage | Priority 1 action |
| --- | --- | --- | --- |
| Source manga and filters | `suwayomi/client/source_manga.lua` | `spec/suwayomi_client_source_manga_spec.lua` covers stale source-filter results, cancellable source manga load, timeout retry rows, stale source manga results, append retry, append close, and chapter-count page switch cancellation. | Keep controller-level stale tests; do not add worker-only stale tests. |
| Global search | `suwayomi/client/global_search.lua` | `spec/suwayomi_client_global_search_spec.lua` covers timeout cleanup, late finish handling, cancel active and pending jobs, and retry summary behavior. | No code change planned. |
| Library | `suwayomi/client/library.lua` | `spec/suwayomi_client_library_spec.lua` covers stale category request cancellation. | Add explicit `cancelLibraryNetworkRequests()` and plugin-close coverage; improve timeout copy. |
| Manga actions and chapter loads | `suwayomi/manga/controller.lua` | `spec/suwayomi_manga_controller_spec.lua` covers stale chapter loads, active request cancellation, route-close targets, and source-only close target branches. | No code change planned. |
| Reader return | `suwayomi/reader_return.lua` | `spec/suwayomi_reader_return_spec.lua` covers stale reader-return results after document/context changes and cancel paths. | No code change planned. |
| Read sync | `suwayomi/readsync/controller.lua` | `spec/suwayomi_readsync_controller_spec.lua` covers stale/failed entry preservation, timeout cleanup, failure backoff, manual sync, and document-close sync. | No code change planned. |
| Source fetch | `suwayomi/browse/controller.lua` | `spec/suwayomi_browse_controller_spec.lua` covers timeout cleanup, silent timeout cleanup, stale credential result drop, and silent refresh cancellation. | No code change planned. |
| Extension mutations | `suwayomi/browse/extensions.lua` | `spec/suwayomi_browse_extensions_spec.lua` covers timeout cleanup, stale worker drops, action-aware mutation timeouts, refresh warnings, close state, and focus after actions. | No code change planned. |
| Thumbnail jobs | `suwayomi/ui/list_menu.lua` | `spec/suwayomi_ui_list_menu_spec.lua` covers stale thumbnail generation and timeout refresh; close cancellation is implemented by `cancelThumbnailJobs(menu)`. | Run focused spec; add no new code unless it fails. |
| Download queue recovery | `suwayomi/downloads/queue.lua`, `suwayomi/downloads/active_jobs.lua`, `suwayomi/downloads/job_store.lua` | `spec/main_spec.lua`, `spec/suwayomi_download_queue_spec.lua`, and `spec/suwayomi_downloads_active_jobs_spec.lua` cover recovery on init, interrupted recovery, corrupt records, dedupe, archive-exists cleanup, failed-job recovery, and watchdog failure. | Keep existing specs and include recovery steps in golden-flow QA. |
| Release payload smoke | `.github/scripts/stage-release-payload.sh`, `.github/workflows/test.yml`, `.github/workflows/release.yml` | CI already runs release payload staging; local release workflow also uses it. | Include smoke command in golden-flow/pre-release gates. |

## Worker-Level Decision

Do not add stale-result tests to pure worker specs such as `spec/suwayomi_source_fetch_worker_spec.lua`, `spec/suwayomi_extension_worker_spec.lua`, `spec/suwayomi_source_manga_worker_spec.lua`, `spec/suwayomi_global_search_worker_spec.lua`, or `spec/suwayomi_ui_thumbnail_worker_spec.lua`. Those workers normalize request/result files and do not own UI route lifetime. Stale gating belongs to the caller that owns active tokens, close callbacks, and credentials.

## Verification Commands

Run after implementing this plan:

```bash
rtk busted spec/main_spec.lua spec/suwayomi_client_library_spec.lua spec/suwayomi_client_source_manga_spec.lua spec/suwayomi_ui_list_rows_spec.lua spec/suwayomi_ui_list_menu_spec.lua
rtk luacheck --codes spec suwayomi main.lua _meta.lua
rtk busted spec
rtk git diff --check
bash .github/scripts/stage-release-payload.sh
```
```

- [ ] **Step 2: Review audit diff**

Run:

```bash
rtk git diff -- docs/superpowers/audits/2026-05-23-stability-recovery.md
```

Expected: audit names concrete owners, concrete existing specs, and the exact Priority 1 gaps closed by later tasks.

- [ ] **Step 3: Commit Task 2**

Run:

```bash
rtk git add docs/superpowers/audits/2026-05-23-stability-recovery.md
rtk git commit -m "docs: record stability recovery audit"
```

---

### Task 3: Cancel Library Requests On Full Plugin Close

**Files:**
- Modify: `main.lua`
- Modify: `suwayomi/client/library.lua`
- Test: `spec/main_spec.lua`
- Test: `spec/suwayomi_client_library_spec.lua`

- [ ] **Step 1: Add failing Library client cancellation spec**

Append this test after `ignores stale library manga loads when a newer category wins` in `spec/suwayomi_client_library_spec.lua`:

```lua
    it("cancels active library requests and ignores late completions", function()
        local requests = {}
        local canceled = {}
        local shown_manga
        local client = newClient({
            network_request_job = {
                start = function(options)
                    table.insert(requests, options)
                    return {
                        pid = #requests,
                        on_cancel = options.on_cancel,
                    }
                end,
                cancel = function(active)
                    table.insert(canceled, active)
                    if active.on_cancel then
                        active.on_cancel()
                    end
                end,
            },
            ui = {
                showLibraryMangaMenu = function(manga)
                    shown_manga = manga
                    return { name = "library-menu" }
                end,
            },
        })

        assert.is_true(client:showLibraryManga(nil))
        assert.are.equal(1, #requests)

        client:cancelLibraryNetworkRequests()

        assert.are.equal(1, #canceled)
        assert.is_nil(client.active_library_network_requests)

        requests[1].on_finish({
            ok = true,
            manga = {
                { id = "late", title = "Late Manga" },
            },
        })

        assert.is_nil(shown_manga)
    end)
```

- [ ] **Step 2: Run failing Library spec**

Run:

```bash
rtk busted spec/suwayomi_client_library_spec.lua
```

Expected: FAIL with `attempt to call method 'cancelLibraryNetworkRequests'`.

- [ ] **Step 3: Implement Library request cancellation**

Add this method in `suwayomi/client/library.lua` after `startLibraryNetworkRequest`:

```lua
function SuwayomiClient:cancelLibraryNetworkRequests()
    local active_requests = self.active_library_network_requests
    if not active_requests then
        return
    end

    local request_job = self:getNetworkRequestJob()
    for slot_key, request_token in pairs(active_requests) do
        active_requests[slot_key] = nil
        if request_token.active and request_job.cancel then
            request_job.cancel(request_token.active)
        end
    end
    self.active_library_network_requests = nil
end
```

- [ ] **Step 4: Run Library spec**

Run:

```bash
rtk busted spec/suwayomi_client_library_spec.lua
```

Expected: PASS.

- [ ] **Step 5: Add failing plugin-close spec**

In `spec/main_spec.lua`, extend `marks plugin closing and cancels active work before closing screens` by adding a client table before `plugin:closeSuwayomiPlugin()`:

```lua
        plugin.client = {
            cancelLibraryNetworkRequests = function(self)
                self.library_cancel_saw_closing = plugin.suwayomi_plugin_closing == true
            end,
        }
```

Add this assertion after the existing reader/manga assertions:

```lua
        assert.is_true(plugin.client.library_cancel_saw_closing)
```

- [ ] **Step 6: Run failing main spec**

Run:

```bash
rtk busted spec/main_spec.lua
```

Expected: FAIL because `closeSuwayomiPlugin()` does not call `client:cancelLibraryNetworkRequests()` yet.

- [ ] **Step 7: Cancel Library requests from plugin close**

In `main.lua`, update `SuwayomiPlugin:closeSuwayomiPlugin()` so the cancellation block includes:

```lua
        if self.client and self.client.cancelLibraryNetworkRequests then
            self.client:cancelLibraryNetworkRequests()
        end
```

Place it after `cancelMangaNetworkRequests()` and before `self.suwayomi_navigation:closeAll()` so active work sees `suwayomi_plugin_closing == true` before widgets close.

- [ ] **Step 8: Run focused specs**

Run:

```bash
rtk busted spec/main_spec.lua spec/suwayomi_client_library_spec.lua
```

Expected: PASS.

- [ ] **Step 9: Commit Task 3**

Run:

```bash
rtk git add main.lua suwayomi/client/library.lua spec/main_spec.lua spec/suwayomi_client_library_spec.lua
rtk git commit -m "fix(library): cancel requests on plugin close"
```

---

### Task 4: Make Library Timeout Feedback Action-Aware

**Files:**
- Modify: `suwayomi/client/library.lua`
- Test: `spec/suwayomi_client_library_spec.lua`

- [ ] **Step 1: Add failing timeout-message spec**

Append this test near the other Library network request tests in `spec/suwayomi_client_library_spec.lua`:

```lua
    it("uses action-aware timeout feedback for library loads", function()
        local requests = {}
        local client = newClient({
            network_request_job = {
                start = function(options)
                    table.insert(requests, options)
                    return { pid = #requests }
                end,
                cancel = function() end,
            },
            ui = {},
        })

        assert.is_true(client:showLibrary())

        assert.are.equal(
            "Library loading timed out. Check your connection, then open Library again.",
            requests[1].timeout_message
        )
    end)
```

- [ ] **Step 2: Run failing Library spec**

Run:

```bash
rtk busted spec/suwayomi_client_library_spec.lua
```

Expected: FAIL because `timeout_message` is still `Could not load library.`

- [ ] **Step 3: Update Library timeout copy**

In `suwayomi/client/library.lua`, add this local helper after `buildLibraryCategoryChoices`:

```lua
local function libraryTimeoutMessage(client)
    return client:translate("Library loading timed out. Check your connection, then open Library again.")
end
```

In `startLibraryNetworkRequest`, replace:

```lua
        timeout_message = self:translate("Could not load library."),
```

with:

```lua
        timeout_message = libraryTimeoutMessage(self),
```

- [ ] **Step 4: Run Library spec**

Run:

```bash
rtk busted spec/suwayomi_client_library_spec.lua
```

Expected: PASS.

- [ ] **Step 5: Commit Task 4**

Run:

```bash
rtk git add suwayomi/client/library.lua spec/suwayomi_client_library_spec.lua
rtk git commit -m "fix(library): clarify timeout recovery"
```

---

### Task 5: Surface Browse Chapter-Count Timeout State

**Files:**
- Modify: `suwayomi/client/browse_chapter_counts.lua`
- Modify: `suwayomi/ui/list_rows.lua`
- Test: `spec/suwayomi_client_source_manga_spec.lua`
- Test: `spec/suwayomi_ui_list_rows_spec.lua`

- [ ] **Step 1: Add failing row-formatting spec**

In `spec/suwayomi_ui_list_rows_spec.lua`, add this test near the `getMangaMandatory` chapter-count tests:

```lua
    it("shows chapter-count timeout guidance when browse count loading fails", function()
        local rows = require("suwayomi/ui/list_rows")

        assert.are.equal(
            "Chapter count timed out; open manga to load chapters",
            rows.getMangaMandatory({
                chapter_count_error = "Chapter count timed out; open manga to load chapters",
            })
        )
    end)
```

- [ ] **Step 2: Run failing row spec**

Run:

```bash
rtk busted spec/suwayomi_ui_list_rows_spec.lua
```

Expected: FAIL because `getMangaMandatory()` ignores `chapter_count_error` strings.

- [ ] **Step 3: Display chapter-count error strings**

In `suwayomi/ui/list_rows.lua`, update `Rows.getMangaMandatory(manga)` so the chapter-count branch begins with:

```lua
    if type(manga.chapter_count_error) == "string" and manga.chapter_count_error ~= "" then
        chapter_count = manga.chapter_count_error
    elseif manga.chapter_count_loading == true then
        chapter_count = _("Checking chapters")
```

Keep the existing verified-count branches after this new error branch.

- [ ] **Step 4: Run row spec**

Run:

```bash
rtk busted spec/suwayomi_ui_list_rows_spec.lua
```

Expected: PASS.

- [ ] **Step 5: Add failing chapter-count timeout spec**

In `spec/suwayomi_client_source_manga_spec.lua`, update `starts the next browse chapter count when a worker times out` so the `updated_manga` table records the exact error string:

```lua
                    table.insert(updated_manga, {
                        first_error = manga[1].chapter_count_error,
                        second_loading = manga[2].chapter_count_loading,
                    })
```

Replace this assertion:

```lua
        assert.is_true(updated_manga[#updated_manga].first_error)
```

with:

```lua
        assert.are.equal(
            "Chapter count timed out; open manga to load chapters",
            updated_manga[#updated_manga].first_error
        )
```

- [ ] **Step 6: Run failing source manga spec**

Run:

```bash
rtk busted spec/suwayomi_client_source_manga_spec.lua
```

Expected: FAIL because timeout currently stores boolean `true`.

- [ ] **Step 7: Store action-aware timeout error**

In `suwayomi/client/browse_chapter_counts.lua`, add:

```lua
local CHAPTER_COUNT_TIMEOUT_ERROR = "Chapter count timed out; open manga to load chapters"
```

Use that constant in the timeout result:

```lua
                        self:translate(CHAPTER_COUNT_TIMEOUT_ERROR),
```

Make `applyBrowseChapterCountResult(manga, result)` preserve string errors by replacing:

```lua
        manga.chapter_count_error = true
```

with:

```lua
        manga.chapter_count_error = result and result.error or true
```

- [ ] **Step 8: Run focused specs**

Run:

```bash
rtk busted spec/suwayomi_client_source_manga_spec.lua spec/suwayomi_ui_list_rows_spec.lua
```

Expected: PASS.

- [ ] **Step 9: Commit Task 5**

Run:

```bash
rtk git add suwayomi/client/browse_chapter_counts.lua suwayomi/ui/list_rows.lua spec/suwayomi_client_source_manga_spec.lua spec/suwayomi_ui_list_rows_spec.lua
rtk git commit -m "fix(browse): explain chapter count timeouts"
```

---

### Task 6: Verify Thumbnail Close And Timeout Coverage

**Files:**
- Review: `suwayomi/ui/list_menu.lua`
- Review: `spec/suwayomi_ui_list_menu_spec.lua`

- [ ] **Step 1: Run focused ListMenu spec**

Run:

```bash
rtk busted spec/suwayomi_ui_list_menu_spec.lua
```

Expected: PASS, including `refreshes visible rows after thumbnail timeouts` and close-callback tests around `onClose` / `onCloseWidget`.

- [ ] **Step 2: Inspect thumbnail cancellation code**

Run:

```bash
rtk grep -n "cancelThumbnailJobs\\|_suwayomi_thumbnail_active\\|onCloseWidget" suwayomi/ui/list_menu.lua spec/suwayomi_ui_list_menu_spec.lua
```

Expected: `cancelThumbnailJobs(menu)` clears active thumbnail jobs during menu close, timeout handlers ignore stale generation/active mismatches, and focused specs cover the behavior. No source edit or commit is expected for this task when the focused spec passes.

---

### Task 7: Full Stability Verification

**Files:**
- No source edits expected.

- [ ] **Step 1: Run focused stability specs**

Run:

```bash
rtk busted spec/main_spec.lua spec/suwayomi_client_library_spec.lua spec/suwayomi_client_source_manga_spec.lua spec/suwayomi_ui_list_rows_spec.lua spec/suwayomi_ui_list_menu_spec.lua
```

Expected: PASS.

- [ ] **Step 2: Run lint**

Run:

```bash
rtk luacheck --codes spec suwayomi main.lua _meta.lua
```

Expected: PASS with no warnings.

- [ ] **Step 3: Run full specs**

Run:

```bash
rtk busted spec
```

Expected: PASS.

- [ ] **Step 4: Run diff whitespace check**

Run:

```bash
rtk git diff --check
```

Expected: no whitespace errors.

- [ ] **Step 5: Run release payload smoke check**

Run:

```bash
bash .github/scripts/stage-release-payload.sh
```

Expected: output lists `suwayomi.koplugin/_meta.lua`, `suwayomi.koplugin/main.lua`, `suwayomi.koplugin/README.md`, and `suwayomi.koplugin/suwayomi/` contents only. Remove generated `suwayomi.koplugin/` before final status.

- [ ] **Step 6: Clean generated payload and inspect status**

Run:

```bash
rm -rf suwayomi.koplugin
rtk git status --short
rtk git log --oneline --max-count 8
```

Expected: worktree clean after commits. Recent commits include Task 1 through Task 5; Task 6 has no commit unless a failing ListMenu spec required a real fix.

- [ ] **Step 7: Stop for review**

Report:

```text
Branch:
Focused specs:
Luacheck:
Full specs:
Diff check:
Release payload smoke:
Manual QA checklist path:
Audit path:
```

Do not merge, push, or device-deploy unless user explicitly asks to continue or finalize.

---

## Self-Review Notes

- Priority 1 checklist coverage maps to setup, Library, Browse/extensions, source search/filter, downloads/recovery, reader return, read sync, timeout/retry, and release payload smoke.
- Code work is limited to concrete gaps found by the audit: Library route-close cancellation and two timeout-copy improvements.
- Worker-only stale tests are intentionally avoided because route ownership lives in controller/client modules.
- Verification includes local lint, full specs, diff check, and release payload staging.
