# Reader Return Smart Close Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make reader-return chapter-screen close route to Library for library titles, to Source for source-only titles, and keep current close behavior when no target is known.

**Architecture:** Extend the existing reader-return context with `in_library`, rebuild returned manga with that field, and pass a reader-return close target into `showChapterResultForManga`. Keep the route action in `suwayomi/manga/controller.lua` so only returned chapter menus get smart-close behavior.

**Tech Stack:** LuaJIT/Lua 5.1, Busted specs, KOReader menu stubs, existing `suwayomi/reader_return.lua` and `suwayomi/manga/controller.lua` controller mixins.

---

## File Structure

- Modify `suwayomi/reader_return.lua`: add `in_library` to saved contexts, copy it through sibling inference when available, rebuild returned manga with it, and pass a close target option.
- Modify `suwayomi/manga/controller.lua`: add reader-return close target resolution and close handling around existing chapter menu close callback.
- Modify `spec/suwayomi_reader_return_spec.lua`: cover saved `in_library`, restored manga membership, and close target option.
- Modify `spec/suwayomi_manga_controller_spec.lua`: cover Library route, Source route, fallback route, and normal chapter close regression.

---

### Task 1: Preserve Reader-Return Routing Metadata

**Files:**
- Modify: `spec/suwayomi_reader_return_spec.lua`
- Modify: `suwayomi/reader_return.lua`

- [x] **Step 1: Write failing reader-return metadata tests**

Add these assertions to existing reader-return specs.

In `spec/suwayomi_reader_return_spec.lua`, update `"saves return context keyed by local chapter path"`:

```lua
plugin:saveReaderReturnContext(
    { id = "m1", title = "Fable Orbit", in_library = true, source = { id = "local", name = "Local source" } },
    { id = "c1", name = "Chapter 1" },
    "/downloads/Local/Fable Orbit/Chapter 1.cbz"
)

assert.are.same({
    path = "/downloads/Local/Fable Orbit/Chapter 1.cbz",
    manga_id = "m1",
    manga_title = "Fable Orbit",
    chapter_id = "c1",
    chapter_name = "Chapter 1",
    source = { id = "local", name = "Local source" },
    in_library = true,
}, state.contexts["/downloads/Local/Fable Orbit/Chapter 1.cbz"])
```

In `"fetches chapters asynchronously before closing reader and restores the chapter list"`, add `in_library = true` to the stored context and add these assertions after existing `shown_manga.source` assertion:

```lua
assert.is_true(state.shown_manga.in_library)
assert.is_table(state.shown_options.reader_return_close_target)
assert.are.equal("library", state.shown_options.reader_return_close_target.kind)
```

In the `build_plugin()` helper table, add this method so the reader-return spec can assert the option passed to the manga controller without loading that controller:

```lua
buildReaderReturnCloseTarget = function(_, _, manga)
    if manga and manga.in_library == true then
        return { kind = "library" }
    end
    if manga and manga.source and manga.source.id then
        return { kind = "source", source = manga.source }
    end
    return nil
end,
```

- [x] **Step 2: Run reader-return spec and verify RED**

Run:

```bash
rtk busted spec/suwayomi_reader_return_spec.lua
```

Expected: FAIL because saved context lacks `in_library` and returned manga lacks `in_library`, so the close target stub receives no library state.

- [x] **Step 3: Implement reader-return metadata propagation**

In `suwayomi/reader_return.lua`, change `buildContext()` result to include `in_library`:

```lua
return {
    path = chapter_path,
    manga_id = present(manga.id),
    manga_title = manga.title,
    chapter_id = present(chapter.id),
    chapter_name = chapter.name,
    source = copyTable(manga.source),
    in_library = manga.in_library,
}
```

In `inferSiblingContext()`, add an inferred membership local and copy it from sibling contexts:

```lua
local inferred_in_library
local function consider(candidate)
    if type(candidate) ~= "table" or parentDirectory(candidate.path) ~= current_dir then
        return true
    end
    local manga_id = present(candidate.manga_id)
    if not manga_id then
        return true
    end
    if inferred_manga_id and inferred_manga_id ~= manga_id then
        return false
    end
    inferred_manga_id = manga_id
    if not inferred_source and candidate.source then
        inferred_source = candidate.source
    end
    if not inferred_manga_title and candidate.manga_title then
        inferred_manga_title = candidate.manga_title
    end
    if inferred_in_library == nil and candidate.in_library ~= nil then
        inferred_in_library = candidate.in_library
    end
    return true
end
```

Return it in the inferred context:

```lua
return {
    path = path,
    manga_id = inferred_manga_id,
    manga_title = inferred_manga_title,
    source = copyTable(inferred_source),
    in_library = inferred_in_library,
}
```

When rebuilding returned manga in `startReaderReturnChapterRequest()`, include membership and close target:

```lua
local manga = {
    id = context.manga_id,
    title = context.manga_title or context.manga_id,
    source = copyTable(context.source),
    in_library = context.in_library,
}
self:closeReaderToFileManager(function()
    if self.active_reader_return_request == request_token then
        self.active_reader_return_request = nil
    end
    self:showChapterResultForManga(manga, result, {
        return_context = context,
        reader_return_close_target = self.buildReaderReturnCloseTarget
            and self:buildReaderReturnCloseTarget(context, manga)
            or nil,
    })
end, function()
```

- [x] **Step 4: Run reader-return spec and verify GREEN**

Run:

```bash
rtk busted spec/suwayomi_reader_return_spec.lua
```

Expected: PASS.

- [x] **Step 5: Commit Task 1**

Run:

```bash
rtk git add spec/suwayomi_reader_return_spec.lua suwayomi/reader_return.lua
rtk git commit -m "feat: preserve reader return route metadata"
```

---

### Task 2: Route Reader-Return Chapter Close

**Files:**
- Modify: `spec/suwayomi_manga_controller_spec.lua`
- Modify: `suwayomi/manga/controller.lua`

- [x] **Step 1: Write failing manga controller close routing tests**

In `spec/suwayomi_manga_controller_spec.lua`, replace the existing `plugin:getClient()` helper with this version:

```lua
function plugin:getClient()
    return {
        attachSourceToManga = function(_, manga, source)
            manga.source = source
            return manga
        end,
        showSourceModeMenu = function(_, source)
            state.opened_source = source
            return { name = "source-menu" }
        end,
    }
end
```

Then extend the helper after `trackSuwayomiScreen()`:

```lua
function plugin:showLibrary()
    state.opened_library = true
    return { name = "library-menu" }
end
```

Then add these tests near existing returned-chapter specs:

```lua
it("opens Library when closing returned chapters for a library manga", function()
    local plugin, state = installController()
    local manga = { id = "m1", title = "Fable Orbit", in_library = true, source = { id = "s1" } }

    assert.is_true(plugin:showChapterResultForManga(manga, {
        ok = true,
        chapters = { { id = "c1", name = "Ch. 1" } },
    }, {
        reader_return_close_target = plugin:buildReaderReturnCloseTarget(nil, manga),
    }))

    state.chapter_menu_options.close_callback()

    assert.is_nil(plugin.current_chapter_menu)
    assert.is_true(state.opened_library)
    assert.is_nil(state.opened_source)
end)

it("opens Source when closing returned chapters for a source-only manga", function()
    local plugin, state = installController()
    local source = { id = "s1", name = "Random Source" }
    local manga = { id = "m1", title = "Cloud Decimal", in_library = false, source = source }

    assert.is_true(plugin:showChapterResultForManga(manga, {
        ok = true,
        chapters = { { id = "c1", name = "Ch. 1" } },
    }, {
        reader_return_close_target = plugin:buildReaderReturnCloseTarget(nil, manga),
    }))

    state.chapter_menu_options.close_callback()

    assert.is_nil(plugin.current_chapter_menu)
    assert.are.equal(source, state.opened_source)
    assert.is_nil(state.opened_library)
end)

it("keeps normal close behavior when returned chapters have no close target", function()
    local plugin, state = installController()
    local manga = { id = "m1", title = "Plain Vessel" }

    assert.is_true(plugin:showChapterResultForManga(manga, {
        ok = true,
        chapters = { { id = "c1", name = "Ch. 1" } },
    }, {
        reader_return_close_target = plugin:buildReaderReturnCloseTarget(nil, manga),
    }))

    state.chapter_menu_options.close_callback()

    assert.is_nil(plugin.current_chapter_menu)
    assert.is_nil(state.opened_library)
    assert.is_nil(state.opened_source)
end)

it("does not route normal chapter menu close", function()
    local plugin, state = installController()
    local manga = { id = "m1", title = "Quiet Lattice", in_library = true, source = { id = "s1" } }

    assert.is_true(plugin:showChapterResultForManga(manga, {
        ok = true,
        chapters = { { id = "c1", name = "Ch. 1" } },
    }))

    state.chapter_menu_options.close_callback()

    assert.is_nil(plugin.current_chapter_menu)
    assert.is_nil(state.opened_library)
    assert.is_nil(state.opened_source)
end)
```

- [x] **Step 2: Run manga controller spec and verify RED**

Run:

```bash
rtk busted spec/suwayomi_manga_controller_spec.lua
```

Expected: FAIL because `buildReaderReturnCloseTarget()` is missing and close callbacks do not route.

- [x] **Step 3: Implement manga close target helpers**

In `suwayomi/manga/controller.lua`, add helpers near `findReturnedChapterItemNumber()`:

```lua
local function hasSourceId(source)
    return type(source) == "table" and source.id ~= nil and tostring(source.id) ~= ""
end
```

Add plugin methods before `showChapterResultForManga()`:

```lua
function Methods:buildReaderReturnCloseTarget(_, manga)
    if type(manga) ~= "table" then
        return nil
    end
    if manga.in_library == true then
        return { kind = "library" }
    end
    if hasSourceId(manga.source) then
        return { kind = "source", source = manga.source }
    end
    return nil
end

function Methods:openReaderReturnCloseTarget(target)
    if type(target) ~= "table" then
        return nil
    end
    if target.kind == "library" and self.showLibrary then
        return self:showLibrary()
    end
    if target.kind == "source" and hasSourceId(target.source) then
        local client = self.getClient and self:getClient() or nil
        if client and client.showSourceModeMenu then
            return client:showSourceModeMenu(target.source)
        end
    end
    return nil
end
```

Update `showChapterResultForManga()` close callback:

```lua
local reader_return_close_target = options.reader_return_close_target
self.current_chapter_options.close_callback = function()
    local is_current_menu = self.current_chapter_menu == chapter_menu
    if is_current_menu then
        self.current_chapter_menu = nil
    end
    if is_current_menu and reader_return_close_target and self.openReaderReturnCloseTarget then
        return self:openReaderReturnCloseTarget(reader_return_close_target)
    end
    return nil
end
```

- [x] **Step 4: Run manga controller spec and verify GREEN**

Run:

```bash
rtk busted spec/suwayomi_manga_controller_spec.lua
```

Expected: PASS.

- [x] **Step 5: Commit Task 2**

Run:

```bash
rtk git add spec/suwayomi_manga_controller_spec.lua suwayomi/manga/controller.lua
rtk git commit -m "feat: route reader return close target"
```

---

### Task 3: Integration Verification And Final Commit Check

**Files:**
- Verify all files changed by Tasks 1-2.

- [x] **Step 1: Run focused specs**

Run:

```bash
rtk busted spec/suwayomi_reader_return_spec.lua spec/suwayomi_manga_controller_spec.lua
```

Expected: PASS.

- [ ] **Step 2: Run full local checks**

Run:

```bash
rtk busted spec
rtk luacheck --codes spec suwayomi main.lua _meta.lua
```

Expected: both PASS.

- [x] **Step 3: Review diff for privacy and scope**

Run:

```bash
rtk git diff --stat master...HEAD
rtk git diff master...HEAD -- suwayomi/reader_return.lua suwayomi/manga/controller.lua spec/suwayomi_reader_return_spec.lua spec/suwayomi_manga_controller_spec.lua
```

Expected: runtime changes stay in reader-return and manga controller boundaries; no debug output adds path, source display name, title, or chapter name logging.

- [ ] **Step 4: Confirm branch state**

Run:

```bash
rtk git status --short --branch
```

Expected: clean worktree on `codex/reader-return-smart-close`.
