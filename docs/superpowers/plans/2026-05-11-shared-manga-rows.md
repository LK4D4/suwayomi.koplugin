# Shared Manga Rows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Library, Browse source results, source search results, and global-search result pages use one shared manga row formatter.

**Architecture:** Add a pure UI helper under `suwayomi/ui/manga_rows.lua` that converts manga tables into KOReader menu rows. Keep menu ownership, pagination, title bars, filtering, and manga actions in existing controllers/UI modules. Remove old client-side `menu_text` formatting so future metadata can be added in one documented place.

**Tech Stack:** LuaJIT/Lua 5.1, KOReader `Menu` row tables, Busted specs with KOReader stubs.

---

## File Structure

- Create `suwayomi/ui/manga_rows.lua`: pure manga row formatting. No fetching, filtering, pagination, menu creation, or mutation of manga tables.
- Create `spec/suwayomi_ui_manga_rows_spec.lua`: focused tests for the row helper contract.
- Modify `suwayomi/ui/browse.lua`: require the row helper and use it for both Browse/Search manga menus and Library manga menus.
- Modify `suwayomi/client.lua`: remove library `menu_text` formatting and pass raw manga tables to UI menu methods.
- Modify `suwayomi/manga/controller.lua`: stop recomputing `menu_text` after add/remove library mutations.
- Modify `spec/suwayomi_ui_browse_spec.lua`, `spec/suwayomi_ui_spec.lua`, `spec/suwayomi_client_spec.lua`, and `spec/suwayomi_manga_controller_spec.lua`: update expectations to the shared row contract.

## Task 1: Add Shared Manga Row Helper

**Files:**
- Create: `suwayomi/ui/manga_rows.lua`
- Test: `spec/suwayomi_ui_manga_rows_spec.lua`

- [ ] **Step 1: Write focused row helper specs**

Add `spec/suwayomi_ui_manga_rows_spec.lua`:

```lua
describe("suwayomi/ui/manga_rows", function()
    before_each(function()
        package.loaded["suwayomi/ui/manga_rows"] = nil
        package.preload["gettext"] = function()
            return function(text) return text end
        end
    end)

    after_each(function()
        package.preload["gettext"] = nil
        package.loaded["suwayomi/ui/manga_rows"] = nil
    end)

    it("uses title, id, then an empty title fallback", function()
        local rows = require("suwayomi/ui/manga_rows")

        assert.are.equal("Frieren", rows.getTitle({ title = "Frieren", id = "m1" }))
        assert.are.equal("m2", rows.getTitle({ id = "m2" }))
        assert.are.equal("", rows.getTitle(nil))
    end)

    it("shows in-library state only when requested and true", function()
        local rows = require("suwayomi/ui/manga_rows")

        assert.are.equal("In Library", rows.getMandatory({ in_library = true }, {
            show_in_library = true,
        }))
        assert.is_nil(rows.getMandatory({ in_library = false }, {
            show_in_library = true,
        }))
        assert.is_nil(rows.getMandatory({ in_library = true }, {
            show_in_library = false,
        }))
    end)

    it("builds rows without mutating manga tables", function()
        local rows = require("suwayomi/ui/manga_rows")
        local manga = { id = "m1", title = "Frieren", in_library = true }
        local selected

        local row = rows.buildRow(manga, {
            show_in_library = true,
            on_select = function(value)
                selected = value
            end,
        })

        assert.are.equal("Frieren", row.text)
        assert.are.equal("In Library", row.mandatory)
        assert.are.same(manga, row.manga)
        assert.is_nil(manga.menu_text)

        row.callback()
        assert.are.same(manga, selected)
    end)

    it("builds menu tables in source order", function()
        local rows = require("suwayomi/ui/manga_rows")
        local selected = {}
        local manga = {
            { id = "m1", title = "Added", in_library = true },
            { id = "m2", title = "New", in_library = false },
        }

        local menu_table = rows.buildMenuTable(manga, {
            show_in_library = true,
            on_select = function(value)
                table.insert(selected, value.id)
            end,
        })

        assert.are.equal("Added", menu_table[1].text)
        assert.are.equal("In Library", menu_table[1].mandatory)
        assert.are.equal("New", menu_table[2].text)
        assert.is_nil(menu_table[2].mandatory)

        menu_table[1].callback()
        menu_table[2].callback()
        assert.are.same({ "m1", "m2" }, selected)
    end)
end)
```

- [ ] **Step 2: Run row helper spec and confirm failure**

Run:

```powershell
$env:PATH = "$env:APPDATA\luarocks\bin;$env:PATH"; busted spec/suwayomi_ui_manga_rows_spec.lua
```

Expected: FAIL because `suwayomi/ui/manga_rows.lua` does not exist.

- [ ] **Step 3: Implement the row helper**

Create `suwayomi/ui/manga_rows.lua`:

```lua
-- Boundary: shared manga menu row formatting.
--
-- Responsibility: convert manga tables into KOReader Menu row tables for
-- Library, Browse, source search, and global-search result screens.
-- Owned state: none.
-- Dependencies: gettext only.
-- External data: manga tables come from API/client layers and are treated as
-- optional-field records.

local _ = require("gettext")

local MangaRows = {}

function MangaRows.getTitle(manga)
    if type(manga) ~= "table" then
        return ""
    end
    if manga.title ~= nil then
        return tostring(manga.title)
    end
    if manga.id ~= nil then
        return tostring(manga.id)
    end
    return ""
end

function MangaRows.getMandatory(manga, options)
    options = options or {}
    if options.show_in_library == true and type(manga) == "table" and manga.in_library == true then
        return _("In Library")
    end
    return nil
end

function MangaRows.buildRow(manga, options)
    options = options or {}
    return {
        text = MangaRows.getTitle(manga),
        mandatory = MangaRows.getMandatory(manga, options),
        manga = manga,
        callback = function()
            if options.on_select then
                options.on_select(manga)
            end
        end,
    }
end

function MangaRows.buildMenuTable(manga_list, options)
    local menu_table = {}
    for _, manga in ipairs(manga_list or {}) do
        table.insert(menu_table, MangaRows.buildRow(manga, options))
    end
    return menu_table
end

return MangaRows
```

- [ ] **Step 4: Run row helper spec and confirm pass**

Run:

```powershell
$env:PATH = "$env:APPDATA\luarocks\bin;$env:PATH"; busted spec/suwayomi_ui_manga_rows_spec.lua
```

Expected: PASS.

## Task 2: Route Browse And Library Menus Through Shared Rows

**Files:**
- Modify: `suwayomi/ui/browse.lua`
- Test: `spec/suwayomi_ui_browse_spec.lua`
- Test: `spec/suwayomi_ui_spec.lua`

- [ ] **Step 1: Update Browse UI tests for new row shape**

In `spec/suwayomi_ui_browse_spec.lua`, update the browse manga row test to expect:

```lua
assert.are.equal("Already Added", shown_dialog.item_table[2].text)
assert.are.equal("In Library", shown_dialog.item_table[2].mandatory)
assert.are.equal("New Find", shown_dialog.item_table[3].text)
assert.is_nil(shown_dialog.item_table[3].mandatory)
assert.are.equal("Unknown State", shown_dialog.item_table[4].text)
assert.is_nil(shown_dialog.item_table[4].mandatory)
```

Update the library manga menu fixture to pass raw manga:

```lua
browse.showLibraryMangaMenu({
    { id = "m1", title = "Sousou no Frieren", unread_count = 12 },
}, function(manga)
    selected_manga = manga
end)

assert.are.equal("Sousou no Frieren", shown_dialog.item_table[1].text)
assert.is_nil(shown_dialog.item_table[1].mandatory)
```

In `spec/suwayomi_ui_spec.lua`, update facade manga menu expectations so `showMangaMenu` rows no longer include `[ ]` or `[+]`.

- [ ] **Step 2: Run UI specs and confirm failure**

Run:

```powershell
$env:PATH = "$env:APPDATA\luarocks\bin;$env:PATH"; busted spec/suwayomi_ui_browse_spec.lua spec/suwayomi_ui_spec.lua
```

Expected: FAIL because `suwayomi/ui/browse.lua` still uses old row builders.

- [ ] **Step 3: Replace private manga row builders**

In `suwayomi/ui/browse.lua`, add near the existing requires:

```lua
local MangaRows = require("suwayomi/ui/manga_rows")
```

Delete `formatBrowseMangaRow`.

Replace `buildMangaMenuTable` with:

```lua
local function buildMangaMenuTable(manga_list, onSelectCallback, options)
    options = options or {}
    local menu_table = {}
    if options.on_previous_page then
        table.insert(menu_table, {
            text = _("Previous page"),
            callback = options.on_previous_page,
        })
    end
    for _, row in ipairs(MangaRows.buildMenuTable(manga_list, {
        show_in_library = true,
        on_select = onSelectCallback,
    })) do
        table.insert(menu_table, row)
    end
    if options.on_next_page then
        table.insert(menu_table, {
            text = _("Next page"),
            callback = options.on_next_page,
        })
    end
    return menu_table
end
```

Replace `buildLibraryMangaMenuTable` with:

```lua
local function buildLibraryMangaMenuTable(manga_list, onSelectCallback)
    return MangaRows.buildMenuTable(manga_list, {
        show_in_library = false,
        on_select = onSelectCallback,
    })
end
```

- [ ] **Step 4: Run UI specs and confirm pass**

Run:

```powershell
$env:PATH = "$env:APPDATA\luarocks\bin;$env:PATH"; busted spec/suwayomi_ui_manga_rows_spec.lua spec/suwayomi_ui_browse_spec.lua spec/suwayomi_ui_spec.lua
```

Expected: PASS.

## Task 3: Remove Client-Side Manga Row Text Mutation

**Files:**
- Modify: `suwayomi/client.lua`
- Test: `spec/suwayomi_client_spec.lua`

- [ ] **Step 1: Update client specs away from `menu_text`**

Remove the spec that directly asserts `formatLibraryMangaRow`.

In library flow specs, replace assertions such as:

```lua
assert.are.equal("Sousou no Frieren (12 unread / MangaDex EN)", shown_manga[1].menu_text)
```

with:

```lua
assert.are.equal("Sousou no Frieren", shown_manga[1].title)
assert.are.equal(12, shown_manga[1].unread_count)
assert.is_nil(shown_manga[1].menu_text)
```

In refresh-after-membership-change specs, assert removed library manga disappear from the refreshed list and retained manga keep their raw fields:

```lua
assert.are.equal("m1", updated_manga[1].id)
assert.are.equal("Sousou no Frieren", updated_manga[1].title)
assert.is_nil(updated_manga[1].menu_text)
```

- [ ] **Step 2: Run client specs and confirm failure**

Run:

```powershell
$env:PATH = "$env:APPDATA\luarocks\bin;$env:PATH"; busted spec/suwayomi_client_spec.lua
```

Expected: FAIL because `client.lua` still assigns `menu_text` and still exposes row-format methods.

- [ ] **Step 3: Remove row formatting from client**

In `suwayomi/client.lua`:

Delete:

```lua
function SuwayomiClient:formatLibraryMangaRow(manga)
    ...
end

function SuwayomiClient:withLibraryMenuText(manga_list)
    ...
end
```

In `showLibraryManga`, replace:

```lua
local library_manga = self:withLibraryMenuText(manga)
```

with:

```lua
local library_manga = manga
```

In `refreshLibraryMangaMenu`, delete:

```lua
self:withLibraryMenuText(library_manga)
```

- [ ] **Step 4: Run client specs and confirm pass**

Run:

```powershell
$env:PATH = "$env:APPDATA\luarocks\bin;$env:PATH"; busted spec/suwayomi_client_spec.lua
```

Expected: PASS.

## Task 4: Remove Controller Dependency On Client Row Formatting

**Files:**
- Modify: `suwayomi/manga/controller.lua`
- Test: `spec/suwayomi_manga_controller_spec.lua`

- [ ] **Step 1: Update controller specs**

In `spec/suwayomi_manga_controller_spec.lua`, remove fake `formatLibraryMangaRow` from the fake client.

Add an assertion in the add/remove library mutation test:

```lua
assert.is_nil(manga.menu_text)
```

- [ ] **Step 2: Run controller spec and confirm failure**

Run:

```powershell
$env:PATH = "$env:APPDATA\luarocks\bin;$env:PATH"; busted spec/suwayomi_manga_controller_spec.lua
```

Expected: FAIL if the controller still expects `client:formatLibraryMangaRow`.

- [ ] **Step 3: Delete row-text recomputation from controller**

In `suwayomi/manga/controller.lua`, delete this block from `updateMangaFromLibraryStateResponse`:

```lua
if self.getClient then
    local client = self:getClient()
    if client and client.formatLibraryMangaRow then
        manga.menu_text = client:formatLibraryMangaRow(manga)
    end
end
```

- [ ] **Step 4: Run controller spec and confirm pass**

Run:

```powershell
$env:PATH = "$env:APPDATA\luarocks\bin;$env:PATH"; busted spec/suwayomi_manga_controller_spec.lua
```

Expected: PASS.

## Task 5: Full Verification And Commit

**Files:**
- Verify all modified runtime/spec files.

- [ ] **Step 1: Search for stale old row formatting**

Run:

```powershell
rg -n "formatLibraryMangaRow|withLibraryMenuText|formatBrowseMangaRow|menu_text =|\\[\\+\\]|\\[ \\]" suwayomi spec
```

Expected: no stale manga row formatting remains. Existing non-manga `menu_text` uses may remain only for chapters/downloads.

- [ ] **Step 2: Run focused suite**

Run:

```powershell
$env:PATH = "$env:APPDATA\luarocks\bin;$env:PATH"; busted spec/suwayomi_ui_manga_rows_spec.lua spec/suwayomi_ui_browse_spec.lua spec/suwayomi_ui_spec.lua spec/suwayomi_client_spec.lua spec/suwayomi_manga_controller_spec.lua
```

Expected: PASS.

- [ ] **Step 3: Run project lint and full tests**

Run:

```powershell
$env:PATH = "$env:APPDATA\luarocks\bin;$env:PATH"; luacheck --codes spec suwayomi main.lua _meta.lua
$env:PATH = "$env:APPDATA\luarocks\bin;$env:PATH"; busted spec
```

Expected: PASS.

- [ ] **Step 4: Commit implementation**

Run:

```powershell
git status --short
git add suwayomi/ui/manga_rows.lua suwayomi/ui/browse.lua suwayomi/client.lua suwayomi/manga/controller.lua spec/suwayomi_ui_manga_rows_spec.lua spec/suwayomi_ui_browse_spec.lua spec/suwayomi_ui_spec.lua spec/suwayomi_client_spec.lua spec/suwayomi_manga_controller_spec.lua
git commit -m "refactor: share manga row formatting"
```

Expected: commit succeeds with one logical implementation change.

## Self-Review

- Spec coverage: The plan covers one shared manga row module, Library title-only rows, Browse/Search `In Library` mandatory markers, action preservation, and old formatting cleanup.
- Placeholder scan: No placeholder markers remain.
- Type consistency: The row helper consistently uses `show_in_library`, `on_select`, `text`, `mandatory`, and `manga`.
