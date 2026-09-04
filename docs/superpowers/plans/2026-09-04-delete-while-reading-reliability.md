# Delete While Reading Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve automatic finished-chapter cleanup across KOReader document switches, transient failures, and restarts without deleting unsafe paths or unread chapters.

**Architecture:** Add a settings-backed finished-chapter journal and a plugin-bound cleanup controller. Reader close records completion before teardown; independent lifecycle triggers process bounded local work through the existing device-delete boundary. Journal sequence order replaces source-list offsets, while ledger, current-document, managed-path, and queue checks guard every deletion.

**Tech Stack:** LuaJIT/Lua 5.1, KOReader `UIManager`, `LuaSettings`, LuaFileSystem/`ffi/util`, Busted, Luacheck.

**Spec:** `docs/superpowers/specs/2026-09-04-delete-while-reading-reliability-design.md`

## Global Constraints

- Keep delete-while-reading values `0` through `5`; value `N` retains newest `N - 1` finished records per manga.
- Order by durable completion sequence, not chapter-list position; rereading moves a record to newest position.
- Never store manga titles, chapter titles, source names, credentials, or server URLs in cleanup journal.
- Never delete current document, unread chapter, active or queued download, or path outside configured plugin-managed download directory.
- Do not add network work to document-close or cleanup processing.
- Retry transient active-download and filesystem failures from 5 seconds up to 300 seconds without retry limit.
- Preserve unknown journal versions unchanged and pause processing with non-sensitive compatibility feedback.
- Process bounded work per pass without truncating oversized valid journals.
- Keep manual delete and manual mark-read deletion behavior unchanged.
- Runtime module `suwayomi/chapters/finished_cleanup.lua` starts with an accurate `-- Boundary:` header.

---

### Task 1: Versioned Cleanup Journal Persistence

**Files:**
- Modify: `suwayomi/settings.lua:40-56,139-200,480-490,556-582`
- Test: `spec/suwayomi_settings_spec.lua`

**Interfaces:**
- Produces: `normalizeFinishedChapterCleanupJournal(value) -> journal, changed, error_code`
- Produces: `loadFinishedChapterCleanupJournal() -> journal, error_code`
- Produces: `saveFinishedChapterCleanupJournal(journal) -> journal, error_code`
- Produces: `clearFinishedChapterCleanupJournal() -> empty version-1 journal`

- [ ] **Step 1: Add failing journal settings tests**

Add Busted cases using existing `stored_data` and `flushed` harness:

```lua
it("loads an empty versioned finished cleanup journal by default", function()
    local settings = require("suwayomi/settings")
    assert.are.same({ version = 1, next_sequence = 1, mangas = {} },
        settings:loadFinishedChapterCleanupJournal())
end)

it("normalizes and deduplicates finished cleanup records without truncating them", function()
    stored_data.finished_chapter_cleanup = {
        version = 1,
        next_sequence = 1,
        mangas = {
            m1 = { records = {
                { chapter_id = "c1", path = "/downloads/c1.cbz", sequence = 2, retry_count = 3, retry_after = 10 },
                { chapter_id = "c1", path = "/downloads/new-c1.cbz", sequence = 4, retry_count = 0, retry_after = 0 },
                { chapter_id = "c2", path = "/downloads/c2.cbz", sequence = 3, retry_count = 0, retry_after = 0 },
            } },
        },
    }
    local journal = require("suwayomi/settings"):loadFinishedChapterCleanupJournal()
    assert.are.equal(5, journal.next_sequence)
    assert.are.equal(2, #journal.mangas.m1.records)
    assert.are.equal("/downloads/new-c1.cbz", journal.mangas.m1.records[2].path)
end)

it("preserves an unknown finished cleanup journal version", function()
    local raw = { version = 9, opaque = { keep = true } }
    stored_data.finished_chapter_cleanup = raw
    local journal, err = require("suwayomi/settings"):loadFinishedChapterCleanupJournal()
    assert.are.equal(raw, journal)
    assert.are.equal("unsupported_version", err)
    assert.is_false(flushed)
end)
```

Also cover non-table journals, empty IDs/paths, NaN/infinity/negative numbers, sparse records, unknown fields, save flushing, and clear flushing. Build more than cleanup pass limit worth of valid records and assert none disappear.

- [ ] **Step 2: Run journal tests and verify RED**

Run: `busted spec/suwayomi_settings_spec.lua`

Expected: FAIL because `loadFinishedChapterCleanupJournal` and related methods do not exist.

- [ ] **Step 3: Implement journal normalization and persistence**

Add helpers equivalent to:

```lua
local FINISHED_CLEANUP_VERSION = 1

local function emptyFinishedCleanupJournal()
    return { version = FINISHED_CLEANUP_VERSION, next_sequence = 1, mangas = {} }
end

local function finiteNonNegative(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or value < 0 then
        return nil
    end
    return value
end
```

Normalize manga keys to non-empty strings. Accept only records with non-empty string `chapter_id` and `path`, plus finite non-negative `sequence`, `retry_count`, and `retry_after`. Deduplicate by chapter ID, keeping highest sequence. Sort accepted records by sequence, then chapter ID for stable persistence. Set `next_sequence` to at least `max_sequence + 1` and at least `1`.

Unknown `version` returns original table and `unsupported_version` without writing. Known-version loads persist only when normalization changed data. Saves refuse unsupported versions. Clears write a new empty version-1 journal and flush.

- [ ] **Step 4: Run journal tests and full settings spec**

Run: `busted spec/suwayomi_settings_spec.lua`

Expected: PASS with no errors.

- [ ] **Step 5: Commit journal persistence**

```bash
git add suwayomi/settings.lua spec/suwayomi_settings_spec.lua
git commit -m "feat(cleanup): persist finished chapter journal"
```

---

### Task 2: Finished Cleanup Controller

**Files:**
- Create: `suwayomi/chapters/finished_cleanup.lua`
- Create: `spec/suwayomi_finished_cleanup_spec.lua`
- Modify: `suwayomi/chapters/delete_actions.lua:48-128,153-220`
- Modify: `spec/suwayomi_chapters_actions_spec.lua:864-980`

**Interfaces:**
- Consumes: settings journal methods from Task 1.
- Consumes: `loadChapterLedger()`, `saveChapterLedger(ledger)`, `getDownloadQueue()`, `getCurrentReaderDocumentPath()`, `chapterArchiveExists(path)`, and `deleteChapterFromDeviceWithOptions(manga, chapter, options)`.
- Produces: `recordFinishedChapter(entry) -> boolean, reason`
- Produces: `cancelFinishedChapter(manga_id, chapter_id) -> boolean`
- Produces: `processFinishedChapterCleanup() -> summary`
- Produces: `scheduleFinishedChapterCleanup(delay_seconds) -> boolean`
- Produces: `cancelFinishedChapterCleanup() -> boolean`
- Produces: `onFinishedCleanupSettingChanged(previous_value, current_value)`
- Produces: `onFinishedCleanupDownloadDirectoryChanged()`

- [ ] **Step 1: Add failing retention and event-recording tests**

Build a focused fake plugin with in-memory settings, ledger, queue, clock, `UIManager:scheduleIn`, and delete result controls. Add table-driven retention tests:

```lua
for setting = 1, 5 do
    it("retains " .. tostring(setting - 1) .. " newest records for setting " .. tostring(setting), function()
        local plugin = buildPlugin({ setting = setting })
        record(plugin, "m1", "c1", "/downloads/source/manga/c1.cbz")
        record(plugin, "m1", "c2", "/downloads/source/manga/c2.cbz")
        record(plugin, "m1", "c3", "/downloads/source/manga/c3.cbz")
        record(plugin, "m1", "c4", "/downloads/source/manga/c4.cbz")
        record(plugin, "m1", "c5", "/downloads/source/manga/c5.cbz")
        plugin:processFinishedChapterCleanup()
        assert.are.equal(math.min(setting - 1, 5), retainedCount(plugin, "m1"))
    end)
end
```

Add cases for reread upsert, unread gaps, independent manga histories, retention increase/decrease, and disabling cleanup clearing all records and invalidating scheduled callbacks.

- [ ] **Step 2: Run focused controller spec and verify RED**

Run: `busted spec/suwayomi_finished_cleanup_spec.lua`

Expected: FAIL because `suwayomi/chapters/finished_cleanup` does not exist.

- [ ] **Step 3: Implement journal ordering and bounded processor shell**

Create plugin-bound methods. `recordFinishedChapter` validates ledger-derived IDs/path, reloads journal, removes matching older record, writes a new record with `next_sequence`, increments sequence, flushes, and schedules processing without deleting current document inline.

`processFinishedChapterCleanup` uses a per-instance flag, reloads journal, handles unsupported versions without saving, sorts each manga oldest-first, retains newest `setting - 1`, and processes at most `self.finished_cleanup_batch_size or 25` candidates per pass. It saves every terminal or retry transition before continuing.

- [ ] **Step 4: Add failing safety, deletion, and retry tests**

Add exact behavior cases:

```lua
it("never passes an unmanaged path to deletion", function()
    local plugin = buildPlugin({ setting = 1, download_directory = "/downloads" })
    record(plugin, "m1", "c1", "/private/c1.cbz")
    local summary = plugin:processFinishedChapterCleanup()
    assert.are.equal(0, #plugin.delete_calls)
    assert.are.equal(1, summary.rejected)
    assert.are.equal("unsafe_path", journalRecord(plugin, "m1", "c1").blocked_reason)
end)

it("persists exponential retry state and resumes after restart", function()
    local first = buildPlugin({ setting = 1, now = 100, delete_state = "delete_failed" })
    record(first, "m1", "c1", "/downloads/source/manga/c1.cbz")
    first:processFinishedChapterCleanup()
    assert.are.equal(1, journalRecord(first, "m1", "c1").retry_count)
    assert.are.equal(105, journalRecord(first, "m1", "c1").retry_after)
    local restarted = buildPlugin({ setting = 1, now = 105, journal = first.journal, delete_state = "deleted" })
    restarted:processFinishedChapterCleanup()
    assert.is_nil(journalRecord(restarted, "m1", "c1"))
end)
```

Also cover ledger unread cancellation, missing archive convergence and ledger-path clear, missing records remaining while inside the retained window, journal/ledger path mismatch rejection, current document deferral, queued/downloading deferral, 5/10/20/.../300-second backoff cap, no retry limit, stopping one manga after transient failure while continuing other manga, successful retry removing only its candidate, bounded follow-up pass, compatibility summary, redacted diagnostics, and one notification per changed reason/count per plugin session.

- [ ] **Step 5: Run safety/retry tests and verify RED**

Run: `busted spec/suwayomi_finished_cleanup_spec.lua`

Expected: FAIL on absent revalidation, retry, or notification behavior.

- [ ] **Step 6: Implement revalidation, delete-state mapping, retries, and privacy summaries**

Check archive existence before path safety: an absent archive is terminal convergence, including a previously rejected path. Skip filesystem deletion, clear only a matching stale ledger path, and remove the journal record. For an existing archive, resolve configured root and candidate through `ffi/util.realpath`; reject when resolution fails or candidate is not a strict descendant of root. Then call:

```lua
self:deleteChapterFromDeviceWithOptions(
    { id = record.manga_id or manga_id },
    { id = record.chapter_id, path = record.path, is_read = true },
    {
        ledger = ledger,
        chapter_path = record.path,
        quiet_active = true,
        quiet_delete_failed = true,
        quiet_missing = true,
        skip_refresh = true,
    }
)
```

Map `deleted` and `missing` to convergence, `queued`, `downloading`, and `delete_failed` to transient retry, and safety checks to retained `blocked_reason` without timer. Clear stale `blocked_reason` and retry metadata when conditions change. Log only operation/event/reason/count/retry fields through `suwayomi/debug.lua`; notify only aggregate counts with translated text.

Remove `getFinishedChapterDeleteCandidate` and `deleteFinishedChaptersWhileReading` from `delete_actions.lua`. Replace old source-list-offset tests with contract tests proving existing manual deletion result states stay unchanged.

- [ ] **Step 7: Run cleanup and chapter-action specs**

Run: `busted spec/suwayomi_finished_cleanup_spec.lua spec/suwayomi_chapters_actions_spec.lua`

Expected: PASS with no errors.

- [ ] **Step 8: Commit cleanup controller**

```bash
git add suwayomi/chapters/finished_cleanup.lua spec/suwayomi_finished_cleanup_spec.lua suwayomi/chapters/delete_actions.lua spec/suwayomi_chapters_actions_spec.lua
git commit -m "feat(cleanup): retry finished chapter deletion"
```

---

### Task 3: Reader, Settings, Queue, and Lifecycle Integration

**Files:**
- Modify: `suwayomi/readsync/controller.lua:1-6,29-49,294-315`
- Modify: `suwayomi/chapters/read_actions.lua:82-130`
- Modify: `suwayomi/plugin/settings_controller.lua:456-475`
- Modify: `suwayomi/downloads/directory.lua:128-145`
- Modify: `suwayomi/reader_return.lua:407-415`
- Modify: `main.lua:14-54,56-93,218-249`
- Modify: `spec/suwayomi_readsync_controller_spec.lua:491-560`
- Modify: `spec/suwayomi_chapters_actions_spec.lua`
- Modify: `spec/suwayomi_plugin_settings_controller_spec.lua`
- Modify: `spec/suwayomi_reader_return_spec.lua`
- Modify: `spec/main_spec.lua`
- Modify: `spec/support/plugin_runtime_spec_helper.lua:9-57,199-218`

**Interfaces:**
- Consumes: all Task 2 controller methods.
- Produces: close-document recording, unread cancellation, immediate settings/directory reevaluation, queue-idle processing, return-to-Suwayomi processing, and startup recovery.

- [ ] **Step 1: Add failing close-document lifecycle tests**

Replace old immediate-deletion expectations with:

```lua
it("records finished cleanup from a fresh reader instance without chapter context", function()
    local controller = installController()
    local plugin = buildPlugin(controller, {
        current_document_path = "/downloads/source/manga/c2.cbz",
        current_document_finished = true,
        ledger = { ["m1:c2"] = { manga_id = "m1", chapter_id = "c2", path = "/downloads/source/manga/c2.cbz", read = false } },
    })
    plugin.current_chapter_context = nil
    plugin:onCloseDocument()
    assert.are.equal("c2", plugin.recorded_finished[1].chapter_id)
    assert.is_true(plugin:loadChapterLedger()["m1:c2"].pending_read_sync)
    assert.are.equal(1, plugin.finished_journal_flushes)
    assert.are.equal(0, #plugin.delete_calls)
end)
```

Cover already-read finished documents, disabled cleanup still scheduling existing read sync, native **Open next file** reaching the same close callback with no chapter context, and no record for unfinished/unmatched/invalid-path documents.

- [ ] **Step 2: Run reader controller spec and verify RED**

Run: `busted spec/suwayomi_readsync_controller_spec.lua`

Expected: FAIL because `onCloseDocument` still invokes immediate offset cleanup.

- [ ] **Step 3: Record durable completion from reader close**

Remove temporary manga/chapter builders from `readsync/controller.lua`. After `markLedgerEntryRead`, call `recordFinishedChapter(entry)` only when setting is enabled and IDs/path are valid. Do not process or delete from close callback. Update boundary comment to remove downloads cleanup ownership.

- [ ] **Step 4: Add failing trigger and cancellation integration tests**

Add focused cases proving:

```lua
plugin:markChapterUnread(manga, chapter)
assert.are.equal({ { manga_id = "m1", chapter_id = "c1" } }, plugin.cleanup_cancellations)

state.delete_finished_menu.onSelect(0)
assert.are.equal(1, state.cleanup_cancel_count)
assert.are.equal({}, state.finished_cleanup_journal.mangas)

plugin:init()
assert.are.equal(1, plugin.finished_cleanup_process_count)

queue.options.onStatusChanged()
assert.are.equal(1, plugin.finished_cleanup_schedule_count)
```

Also assert increasing retention does not delete immediately, decreasing retention processes immediately, re-enabling starts from empty history, directory change reevaluates blocked entries, return to Suwayomi schedules processing before network request, and queue callbacks do not reenter an active processor.

- [ ] **Step 5: Run integration specs and verify RED**

Run: `busted spec/suwayomi_chapters_actions_spec.lua spec/suwayomi_plugin_settings_controller_spec.lua spec/suwayomi_reader_return_spec.lua spec/main_spec.lua`

Expected: FAIL on missing hooks or controller composition.

- [ ] **Step 6: Wire cancellation and processing triggers**

After durable unread ledger update, call `cancelFinishedChapter(manga.id, chapter.id)`. In setting dialog, compare old/new values and call `onFinishedCleanupSettingChanged`. In download-directory chooser callback, call `onFinishedCleanupDownloadDirectoryChanged` before caller callback. In `returnToSuwayomiChapters`, schedule cleanup before starting reader-return request.

Require `suwayomi/chapters/finished_cleanup` in `main.lua`, add retry defaults (`5`, `300`, and batch `25`), compose methods, call cleanup processing after queue recovery in `init`, and invoke scheduling from queue `onStatusChanged`. Extend runtime spec helper module clearing and queue callback capture.

- [ ] **Step 7: Run all integration specs**

Run: `busted spec/suwayomi_readsync_controller_spec.lua spec/suwayomi_chapters_actions_spec.lua spec/suwayomi_plugin_settings_controller_spec.lua spec/suwayomi_reader_return_spec.lua spec/main_spec.lua`

Expected: PASS with no errors.

- [ ] **Step 8: Commit lifecycle integration**

```bash
git add suwayomi/readsync/controller.lua suwayomi/chapters/read_actions.lua suwayomi/plugin/settings_controller.lua suwayomi/downloads/directory.lua suwayomi/reader_return.lua main.lua spec/suwayomi_readsync_controller_spec.lua spec/suwayomi_chapters_actions_spec.lua spec/suwayomi_plugin_settings_controller_spec.lua spec/suwayomi_reader_return_spec.lua spec/main_spec.lua spec/support/plugin_runtime_spec_helper.lua
git commit -m "feat(cleanup): recover cleanup across reader lifecycle"
```

---

### Task 4: Architecture, Localization Extraction, and Full Verification

**Files:**
- Modify: `docs/ARCHITECTURE.md:27-30,90-102,129-138`
- Modify only if extraction requires it: `template.pot` and source `.po` catalogs through repository localization workflow

**Interfaces:**
- Documents: journal ownership, processor triggers, delete boundary, and focused test location.

- [ ] **Step 1: Update architecture map**

Document `suwayomi/chapters/finished_cleanup.lua` as owner of durable finish order, retention, candidate revalidation, retry scheduling, and failure summaries. Keep `delete_actions.lua` documented as archive/sidecar/ledger/queue deletion boundary. Add `spec/suwayomi_finished_cleanup_spec.lua` to test-routing table.

- [ ] **Step 2: Review documentation and runtime boundaries**

Run: `git diff --check`

Expected: exit `0` with no whitespace errors.

- [ ] **Step 3: Run focused and full local verification**

Run:

```bash
busted spec/suwayomi_finished_cleanup_spec.lua
busted spec
luacheck --codes spec suwayomi main.lua _meta.lua
./scripts/check-l10n.sh
```

Expected: all Busted tests pass, Luacheck reports `0 warnings / 0 errors`, and localization check exits `0`.

- [ ] **Step 4: Inspect complete diff against acceptance criteria**

Run:

```bash
git status --short
git diff --stat HEAD~3
git diff HEAD~3 -- docs/ARCHITECTURE.md main.lua suwayomi spec
```

Verify each acceptance criterion maps to a passing focused test. Confirm no credentials, raw paths in diagnostics, manga/chapter titles in journal, or development-only files enter runtime packaging.

- [ ] **Step 5: Commit documentation and final test adjustments**

```bash
git add docs/ARCHITECTURE.md template.pot l10n spec suwayomi main.lua
git commit -m "docs: map finished chapter cleanup"
```
