# Source Manga Continuous Scroll Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make source Popular, Latest, and Search results behave like one growing KOReader list instead of separate remote page screens.

**Architecture:** Keep `source_manga_worker` as the one-page fetch boundary. Add an optional `ListMenu` page-change callback, pass it through Browse manga menus, then make `suwayomi/client/source_manga.lua` own a source-result session that appends later API pages into the same menu. Existing first-page loading, cancel, timeout, chapter-count enrichment, and manga action refresh behavior stay intact.

**Tech Stack:** LuaJIT/Lua 5.1, KOReader `Menu`, existing Suwayomi subprocess worker helpers, Busted specs, Luacheck.

---

## File Map

- Modify `suwayomi/ui/list_menu.lua`: store optional `on_page_changed` callback, invoke it after menu page recalculation/update.
- Modify `suwayomi/ui/browse.lua`: pass `on_page_changed` through `showMangaMenu` and `updateMangaMenu`; remove page rows by no longer relying on `on_next_page` / `on_previous_page` in source flow.
- Modify `suwayomi/client/source_manga.lua`: replace remote page replacement callbacks with source-result sessions and append loading.
- Modify `spec/suwayomi_ui_list_menu_spec.lua`: prove `ListMenu` fires page-change callback and keeps it optional.
- Modify `spec/suwayomi_ui_browse_spec.lua`: prove Browse manga menus pass `on_page_changed` to `ListMenu`.
- Modify `spec/suwayomi_client_source_manga_spec.lua`: prove no visible source page rows, append fetch, retry, cancel, stale-result handling, and filtered-page cap.
- Modify `README.md`: replace "page source results" and explicit next/previous-page user flow with continuous-list wording.
- Modify `docs/ARCHITECTURE.md`: update source manga ownership wording from result pagination to continuous append loading.

---

### Task 1: Add ListMenu Page-Change Callback

**Files:**
- Modify: `suwayomi/ui/list_menu.lua`
- Test: `spec/suwayomi_ui_list_menu_spec.lua`

- [ ] **Step 1: Add failing ListMenu callback spec**

Append this spec near the other `ListMenu.install` tests in `spec/suwayomi_ui_list_menu_spec.lua`:

```lua
    it("notifies callers after visible page changes", function()
        local ListMenu = require("suwayomi/ui/list_menu")
        local calls = {}
        local menu = {
            page = 2,
            item_table = {
                { text = "A" },
                { text = "B" },
                { text = "C" },
            },
            layout = {},
            item_group = {
                clear = function() end,
            },
            page_info = {
                resetLayout = function() end,
            },
            return_button = {
                resetLayout = function() end,
            },
            content_group = {
                resetLayout = function() end,
            },
            _recalculateDimen = function(self)
                self.perpage = 1
                self.page_num = 3
                self.item_width = 320
                self.item_height = 64
                self.item_dimen = { h = 64, copy = function(value) return value end }
            end,
            updatePageInfo = function() end,
            mergeTitleBarIntoLayout = function() end,
            show_parent = "menu",
            line_color = "black",
        }

        ListMenu.install(menu, {
            on_page_changed = function(changed_menu, page)
                table.insert(calls, { menu = changed_menu, page = page })
            end,
        })

        menu:updateItems()

        assert.are.equal(1, #calls)
        assert.are.equal(menu, calls[1].menu)
        assert.are.equal(2, calls[1].page)
    end)
```

- [ ] **Step 2: Run failing ListMenu spec**

Run:

```powershell
busted spec/suwayomi_ui_list_menu_spec.lua
```

Expected: FAIL because `calls` remains empty; `ListMenu.updateItems` does not call `on_page_changed` yet.

- [ ] **Step 3: Implement optional callback storage and invocation**

In `suwayomi/ui/list_menu.lua`, update `ListMenu.install` and `applyOptions` to store the callback:

```lua
function ListMenu.install(menu, options)
    menu._suwayomi_thumbnail_credentials = options and options.thumbnail_credentials
    menu._suwayomi_on_close = options and options.on_close
    menu._suwayomi_on_page_changed = options and options.on_page_changed
    menu._suwayomi_thumbnail_active = menu._suwayomi_thumbnail_active or {}
    menu._suwayomi_thumbnail_active_count = menu._suwayomi_thumbnail_active_count or 0
    menu._suwayomi_thumbnail_generation = menu._suwayomi_thumbnail_generation or 0
```

```lua
local function applyOptions(menu, options)
    menu_utils.applyTitleBarOptions(menu, options)
    menu_utils.applyCloseCallback(menu, options)
    menu._suwayomi_thumbnail_credentials = options and options.thumbnail_credentials
    menu._suwayomi_on_close = options and options.on_close
    menu._suwayomi_on_page_changed = options and options.on_page_changed
end
```

Near the end of `ListMenu.updateItems`, after `ListMenu.startVisibleThumbnailJobs(menu, visible_items)`, add:

```lua
    if type(menu._suwayomi_on_page_changed) == "function" then
        menu._suwayomi_on_page_changed(menu, menu.page)
    end
```

- [ ] **Step 4: Run focused ListMenu spec**

Run:

```powershell
busted spec/suwayomi_ui_list_menu_spec.lua
```

Expected: PASS.

- [ ] **Step 5: Commit Task 1**

Run:

```powershell
git add suwayomi/ui/list_menu.lua spec/suwayomi_ui_list_menu_spec.lua
git commit -m "feat(ui): add list page callback"
```

---

### Task 2: Pass Page Callback Through Manga Menus

**Files:**
- Modify: `suwayomi/ui/browse.lua`
- Test: `spec/suwayomi_ui_browse_spec.lua`

- [ ] **Step 1: Add failing BrowseUI pass-through spec**

Add this test after `shows compact browse result library status, title, and paging rows` in `spec/suwayomi_ui_browse_spec.lua`:

```lua
    it("passes manga menu page-change callbacks to the list menu", function()
        local browse = require("suwayomi/ui/browse")
        local on_page_changed = function() end

        browse.showMangaMenu({
            { id = "m1", title = "Frieren" },
        }, function() end, {
            title = "Popular",
            on_page_changed = on_page_changed,
        })

        assert.are.equal("list_menu", shown_dialog.renderer)
        assert.are.equal(on_page_changed, shown_dialog.on_page_changed)
    end)
```

- [ ] **Step 2: Run failing BrowseUI spec**

Run:

```powershell
busted spec/suwayomi_ui_browse_spec.lua
```

Expected: FAIL because `BrowseUI.showMangaMenu` does not pass `on_page_changed`.

- [ ] **Step 3: Pass callback through show/update**

In `suwayomi/ui/browse.lua`, update `BrowseUI.showMangaMenu`:

```lua
    return getListMenu().show{
        title = options.title or _("Suwayomi Manga"),
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = menu_table,
        close_callback = options.close_callback,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
        on_page_changed = options.on_page_changed,
        thumbnail_credentials = options.thumbnail_credentials,
    }
```

Update `BrowseUI.updateMangaMenu`:

```lua
    return getListMenu().update(menu, {
        title = options.title or menu.title,
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = menu_table,
        close_callback = options.close_callback,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
        on_page_changed = options.on_page_changed,
        thumbnail_credentials = options.thumbnail_credentials,
    })
```

- [ ] **Step 4: Run BrowseUI spec**

Run:

```powershell
busted spec/suwayomi_ui_browse_spec.lua
```

Expected: PASS.

- [ ] **Step 5: Commit Task 2**

Run:

```powershell
git add suwayomi/ui/browse.lua spec/suwayomi_ui_browse_spec.lua
git commit -m "feat(browse): pass manga page callbacks"
```

---

### Task 3: Replace Source Page Rows With Append Session

**Files:**
- Modify: `suwayomi/client/source_manga.lua`
- Test: `spec/suwayomi_client_source_manga_spec.lua`
- Test helper if needed: `spec/support/suwayomi_client_spec_helper.lua`

- [ ] **Step 1: Add failing test for no visible remote page rows**

Replace the existing spec named `passes browse result title and paging callbacks that preserve source context` in `spec/suwayomi_client_source_manga_spec.lua` with:

```lua
    it("keeps source API pages out of visible manga menu rows", function()
        local shown_manga
        local shown_options
        local fetched_options = {}
        local client = newClient({
            api = {
                fetchMangaForSource = function(_, options)
                    table.insert(fetched_options, options)
                    return {
                        ok = true,
                        manga = {
                            { id = "m1", title = "Frieren" },
                        },
                        has_next_page = true,
                    }
                end,
            },
            ui = {
                showMangaMenu = function(manga, _, options)
                    shown_manga = manga
                    shown_options = options
                end,
            },
        })

        client:showMangaForSource({
            id = "s1",
            display_name = "MangaDex (EN)",
            raw_name = "MangaDex",
            lang = "en",
        }, {
            type = "SEARCH",
            query = "frieren",
            skip_mode_menu = true,
        })

        assert.are.same({
            { source_id = "s1", page = 1, type = "SEARCH", query = "frieren" },
        }, fetched_options)
        assert.are.equal("Frieren", shown_manga[1].title)
        assert.are.equal("Search: frieren", shown_options.title)
        assert.is_nil(shown_options.on_previous_page)
        assert.is_nil(shown_options.on_next_page)
        assert.is_function(shown_options.on_page_changed)
    end)
```

- [ ] **Step 2: Run failing source manga spec**

Run:

```powershell
busted spec/suwayomi_client_source_manga_spec.lua
```

Expected: FAIL because title is still `Search - Page 1` and `on_next_page` exists.

- [ ] **Step 3: Update source result title helpers**

In `suwayomi/client/source_manga.lua`, replace title helpers with:

```lua
function SuwayomiClient:getSourceModeTitle(options)
    local mode = options.type or "POPULAR"
    if mode == "SEARCH" then
        return self:translate("Search") .. ": " .. tostring(options.query or "")
    end
    if mode == "LATEST" then
        return self:translate("Latest")
    end
    return self:translate("Popular")
end

function SuwayomiClient:buildBrowseResultTitle(source, options)
    return self:getSourceDisplayName(source)
        .. " - "
        .. self:getSourceModeTitle(options)
end

function SuwayomiClient:getSourceModeScreenTitle(options)
    return self:getSourceModeTitle(options)
end

function SuwayomiClient:buildBrowseResultScreenTitle(_, options)
    return self:getSourceModeScreenTitle(options)
end
```

Replace `buildBrowseResultMenuOptions` with a version that accepts `session` and does not create previous/next rows:

```lua
function SuwayomiClient:buildBrowseResultMenuOptions(source, options, session)
    local detail_title = self:buildBrowseResultTitle(source, options)
    local menu_options = copyOptions({}, self:getTitleBarMenuOptions({ title = detail_title }))
    menu_options.title = self:buildBrowseResultScreenTitle(source, options)
    menu_options.on_page_changed = function(menu, page)
        return self:onSourceMangaMenuPageChanged(session, menu, page)
    end
    return menu_options
end
```

- [ ] **Step 4: Add session builder helpers**

In `suwayomi/client/source_manga.lua`, add these helpers before `renderMangaForSourceResult`:

```lua
local FILTERED_AUTO_LOAD_LIMIT = 3

local function appendList(target, source)
    for _, item in ipairs(source or {}) do
        table.insert(target, item)
    end
    return target
end

function SuwayomiClient:newSourceMangaSession(credentials, source, browse_options)
    return {
        token = self:nextSourceMangaLoadToken(),
        credentials = credentials,
        source = source,
        browse_options = browse_options,
        manga = {},
        visible_manga = {},
        loaded_page = 0,
        has_next_page = false,
        filtered_auto_loads = 0,
    }
end

function SuwayomiClient:getCurrentSourceMangaSession()
    return self._source_manga_result_session
end

function SuwayomiClient:setCurrentSourceMangaSession(session)
    self._source_manga_result_session = session
    return session
end

function SuwayomiClient:isCurrentSourceMangaSession(session)
    return session
        and self._source_manga_result_session == session
        and self._source_manga_load_token == session.token
end

function SuwayomiClient:clearCurrentSourceMangaSession(session)
    if self._source_manga_result_session == session then
        self._source_manga_result_session = nil
    end
end
```

- [ ] **Step 5: Make first-page rendering use session state**

In `showMangaForSource`, create a session before starting the load:

```lua
        local browse_options = {
            type = options.type or "POPULAR",
            query = options.query,
            page = tonumber(options.page) or 1,
        }
        local session = self:newSourceMangaSession(credentials, source, browse_options)
        self:setCurrentSourceMangaSession(session)

        if self:startSourceMangaLoad(credentials, source, browse_options, {
            session = session,
            append = false,
        }) then
            return
        end
```

Update `startSourceMangaLoad` signature and state creation:

```lua
function SuwayomiClient:startSourceMangaLoad(credentials, source, browse_options, load_options)
    load_options = load_options or {}
```

```lua
    local state = {
        token = load_options.session and load_options.session.token or self:nextSourceMangaLoadToken(),
        credentials = credentials,
        source = source,
        browse_options = browse_options,
        title = title,
        detail_title = self:buildBrowseResultTitle(source, browse_options),
        runtime = runtime,
        session = load_options.session,
        append = load_options.append == true,
    }
```

For first-page loads, keep loading menu behavior. For append loads, do not show a new loading menu:

```lua
    if not state.append then
        state.menu = self.ui.showMangaMenu({
            { title = self:translate("Loading manga...") },
        }, nil, self:buildSourceMangaLoadingMenuOptions(state))
        self:trackScreen("browse-results", state.menu)
    else
        state.menu = load_options.menu
    end
```

In `on_finish`, route through a new session renderer:

```lua
            self:renderMangaForSourceResult(
                credentials,
                result_source,
                result_options,
                result,
                state.menu,
                state.session,
                { append = state.append }
            )
```

- [ ] **Step 6: Update `renderMangaForSourceResult` to append rows**

Change signature:

```lua
function SuwayomiClient:renderMangaForSourceResult(credentials, source, browse_options, result, existing_menu, session, render_options)
    render_options = render_options or {}
```

After success validation, normalize session:

```lua
    session = session or self:getCurrentSourceMangaSession() or self:newSourceMangaSession(credentials, source, browse_options)
    if not self:isCurrentSourceMangaSession(session) then
        return
    end
    session.source = source
    session.credentials = credentials
    session.browse_options = {
        type = browse_options.type,
        query = browse_options.query,
        page = tonumber(browse_options.page) or 1,
    }
    session.loaded_page = tonumber(browse_options.page) or session.loaded_page or 1
    session.has_next_page = result.has_next_page == true
    session.loading_more = false
    session.load_more_error = nil
    appendList(session.manga, result.manga or {})

    local visible_manga = self:filterBrowseManga(session.manga)
    local appended_visible_count = #visible_manga - #(session.visible_manga or {})
    session.visible_manga = visible_manga
    if appended_visible_count > 0 then
        session.filtered_auto_loads = 0
    end
```

Build menu options from session:

```lua
    local menu_options = self:buildBrowseResultMenuOptions(source, session.browse_options, session)
    menu_options.thumbnail_credentials = credentials
```

Replace uses of `manga_list` in refresh logic with `session.manga`, and set:

```lua
        visible_manga = self:filterBrowseManga(session.manga)
        session.visible_manga = visible_manga
```

For empty first page with more pages, allow the menu to render empty rows plus page callback. Keep existing "no manga" message only when no rows and no more pages:

```lua
    if #visible_manga == 0 and session.has_next_page ~= true then
```

- [ ] **Step 7: Run focused no-page-row test**

Run:

```powershell
busted spec/suwayomi_client_source_manga_spec.lua
```

Expected: new no-page-row test PASS. Other paging tests may fail until append behavior lands.

- [ ] **Step 8: Add failing append-on-last-page spec**

Add this spec near the paging tests:

```lua
    it("appends the next source API page when the menu reaches the last local page", function()
        local fetched_options = {}
        local updated_manga
        local updated_options
        local client = newClient({
            api = {
                fetchMangaForSource = function(_, options)
                    table.insert(fetched_options, options)
                    return {
                        ok = true,
                        manga = {
                            { id = "m" .. tostring(options.page), title = "Page " .. tostring(options.page) },
                        },
                        has_next_page = options.page < 2,
                    }
                end,
            },
            ui = {
                showMangaMenu = function(manga, _, options)
                    updated_manga = manga
                    updated_options = options
                    return { name = "browse-menu", page = 1, page_num = 1 }
                end,
                updateMangaMenu = function(menu, manga, _, options)
                    updated_manga = manga
                    updated_options = options
                    menu.page = menu.page or 1
                    menu.page_num = menu.page_num or 1
                end,
            },
        })

        client:showMangaForSource({ id = "s1", display_name = "MangaDex (EN)" }, {
            skip_mode_menu = true,
        })
        updated_options.on_page_changed({ page = 1, page_num = 1 }, 1)

        assert.are.same({
            { source_id = "s1", page = 1, type = "POPULAR" },
            { source_id = "s1", page = 2, type = "POPULAR" },
        }, fetched_options)
        assert.are.equal(2, #updated_manga)
        assert.are.equal("Page 1", updated_manga[1].title)
        assert.are.equal("Page 2", updated_manga[2].title)
    end)
```

- [ ] **Step 9: Implement last-page append trigger**

Add helpers in `suwayomi/client/source_manga.lua`:

```lua
function SuwayomiClient:sourceMangaSessionCanLoadMore(session)
    return self:isCurrentSourceMangaSession(session)
        and session.has_next_page == true
        and session.loading_more ~= true
end

function SuwayomiClient:onSourceMangaMenuPageChanged(session, menu, page)
    if not self:sourceMangaSessionCanLoadMore(session) then
        return
    end
    local page_num = tonumber(menu and menu.page_num) or tonumber(page) or 1
    local current_page = tonumber(page) or tonumber(menu and menu.page) or 1
    if current_page < page_num then
        return
    end
    return self:startSourceMangaAppendLoad(session, menu)
end

function SuwayomiClient:startSourceMangaAppendLoad(session, menu)
    if not self:sourceMangaSessionCanLoadMore(session) then
        return
    end
    session.loading_more = true
    session.load_more_error = nil
    local next_options = {
        type = session.browse_options.type,
        query = session.browse_options.query,
        page = (tonumber(session.loaded_page) or 1) + 1,
    }
    return self:startSourceMangaLoad(session.credentials, session.source, next_options, {
        session = session,
        append = true,
        menu = menu,
    })
end
```

In append start failure and timeout paths, clear `session.loading_more` and use append failure rows instead of replacing the whole menu. Implement `renderSourceMangaAppendStatus`:

```lua
function SuwayomiClient:renderSourceMangaAppendStatus(session, menu)
    if not self:isCurrentSourceMangaSession(session) or not menu or not self.ui.updateMangaMenu then
        return
    end
    local rows = {}
    appendList(rows, session.visible_manga or {})
    if session.loading_more then
        table.insert(rows, {
            title = self:translate("Loading more..."),
            raw_menu_row = true,
            select_enabled = false,
        })
    elseif session.load_more_error then
        table.insert(rows, {
            text = session.load_more_error,
            raw_menu_row = true,
            select_enabled = false,
        })
        table.insert(rows, {
            text = self:translate("Retry loading more"),
            raw_menu_row = true,
            callback = function()
                return self:startSourceMangaAppendLoad(session, menu)
            end,
        })
    end
    local menu_options = self:buildBrowseResultMenuOptions(session.source, session.browse_options, session)
    menu_options.thumbnail_credentials = session.credentials
    self.ui.updateMangaMenu(menu, rows, nil, menu_options)
end
```

Call `renderSourceMangaAppendStatus(session, menu)` before starting append worker so the loading row appears.

- [ ] **Step 10: Run append spec**

Run:

```powershell
busted spec/suwayomi_client_source_manga_spec.lua
```

Expected: append spec PASS. Remaining failures show exact legacy expectations to update.

- [ ] **Step 11: Add retry and stale-result specs**

Add append failure test:

```lua
    it("keeps loaded manga visible and retries failed append loads", function()
        local subprocess_job, started = buildSourceMangaSubprocessFake()
        local updated_rows
        local client = newClient({
            subprocess_job = subprocess_job,
            source_manga_worker = {},
            ffi_util = {},
            ui_manager = {},
            ui = {
                showMangaMenu = function()
                    return { name = "browse-menu", page = 1, page_num = 1 }
                end,
                updateMangaMenu = function(_, manga, _, options)
                    updated_rows = manga
                    updated_rows.options = options
                end,
            },
        })

        client:showMangaForSource({ id = "s1", display_name = "MangaDex (EN)" }, {
            skip_mode_menu = true,
        })
        started[1].on_finish(started[1], {
            ok = true,
            manga = { { id = "m1", title = "Page 1" } },
            has_next_page = true,
        })
        updated_rows.options.on_page_changed({ page = 1, page_num = 1 }, 1)
        started[2].on_finish(started[2], {
            ok = false,
            error = "Timed out.",
        })

        assert.are.equal("Page 1", updated_rows[1].title)
        assert.are.equal("Timed out.", updated_rows[2].text)
        assert.are.equal("Retry loading more", updated_rows[3].text)

        updated_rows[3].callback()

        assert.are.equal(3, #started)
        assert.are.equal(2, started[3].browse_options.page)
    end)
```

Add stale result test:

```lua
    it("ignores stale append results after a new source session starts", function()
        local subprocess_job, started = buildSourceMangaSubprocessFake()
        local updated_rows = {}
        local client = newClient({
            subprocess_job = subprocess_job,
            source_manga_worker = {},
            ffi_util = {},
            ui_manager = {},
            ui = {
                showMangaMenu = function()
                    return { name = "browse-menu", page = 1, page_num = 1 }
                end,
                updateMangaMenu = function(_, manga, _, options)
                    table.insert(updated_rows, manga)
                    updated_rows.options = options
                end,
            },
        })

        client:showMangaForSource({ id = "s1", display_name = "First" }, {
            skip_mode_menu = true,
        })
        started[1].on_finish(started[1], {
            ok = true,
            manga = { { id = "m1", title = "First page" } },
            has_next_page = true,
        })
        updated_rows.options.on_page_changed({ page = 1, page_num = 1 }, 1)

        client:showMangaForSource({ id = "s2", display_name = "Second" }, {
            skip_mode_menu = true,
        })
        started[2].on_finish(started[2], {
            ok = true,
            manga = { { id = "stale", title = "Stale append" } },
            has_next_page = false,
        })

        local latest = updated_rows[#updated_rows]
        for _, row in ipairs(latest or {}) do
            assert.are_not.equal("Stale append", row.title)
        end
    end)
```

- [ ] **Step 12: Add cancel-on-close and filtered-page cap specs**

Add cancel spec:

```lua
    it("cancels pending append loads when the result menu closes", function()
        local subprocess_job, started, canceled = buildSourceMangaSubprocessFake()
        local shown_options
        local client = newClient({
            subprocess_job = subprocess_job,
            source_manga_worker = {},
            ffi_util = {},
            ui_manager = {},
            ui = {
                showMangaMenu = function(_, _, options)
                    shown_options = options
                    return { name = "browse-menu", page = 1, page_num = 1 }
                end,
                updateMangaMenu = function(_, _, _, options)
                    shown_options = options
                end,
            },
        })

        client:showMangaForSource({ id = "s1", display_name = "MangaDex (EN)" }, {
            skip_mode_menu = true,
        })
        started[1].on_finish(started[1], {
            ok = true,
            manga = { { id = "m1", title = "Page 1" } },
            has_next_page = true,
        })
        shown_options.on_page_changed({ page = 1, page_num = 1 }, 1)
        shown_options.close_callback()

        assert.are.equal(started[2], canceled[1])
    end)
```

Add filtered cap spec:

```lua
    it("caps chained auto-loads when filtering hides source pages", function()
        local fetched_pages = {}
        local latest_options
        local client = newClient({
            browse_settings = {
                hide_in_library_results = true,
            },
            api = {
                fetchMangaForSource = function(_, options)
                    table.insert(fetched_pages, options.page)
                    return {
                        ok = true,
                        manga = {
                            { id = "m" .. tostring(options.page), title = "Hidden", in_library = true },
                        },
                        has_next_page = true,
                    }
                end,
            },
            ui = {
                showMangaMenu = function(_, _, options)
                    latest_options = options
                    return { name = "browse-menu", page = 1, page_num = 1 }
                end,
                updateMangaMenu = function(_, _, _, options)
                    latest_options = options
                end,
            },
        })

        client:showMangaForSource({ id = "s1", display_name = "MangaDex (EN)" }, {
            skip_mode_menu = true,
        })
        latest_options.on_page_changed({ page = 1, page_num = 1 }, 1)

        assert.are.same({ 1, 2, 3, 4 }, fetched_pages)
    end)
```

- [ ] **Step 13: Implement append failure, retry, cancellation, and cap behavior**

Update append timeout/failure paths in `startSourceMangaLoad`:

```lua
        on_timeout = function(timed_out_active)
            if state.canceled or not self:isCurrentSourceMangaLoad(state) then
                return
            end
            state.finished = true
            state.active = nil
            self:clearSourceMangaLoad(state)
            timed_out_active.canceled = true
            if state.append and state.session then
                state.session.loading_more = false
                state.session.load_more_error = self:translate("Timed out.")
                self:renderSourceMangaAppendStatus(state.session, state.menu)
                self.plugin:showMessage(state.session.load_more_error)
                return
            end
            self:showSourceMangaFailureStatus(
                state.menu,
                state.source,
                state.browse_options,
                self:translate("Timed out."),
                { show_toast = true }
            )
        end,
```

When `start_ok` fails for append state:

```lua
    if not active then
        state.finished = true
        self:clearSourceMangaLoad(state)
        if state.append and state.session then
            state.session.loading_more = false
            state.session.load_more_error = self:translate("Could not start manga loading.")
            self:renderSourceMangaAppendStatus(state.session, state.menu)
            return true
        end
```

In `renderMangaForSourceResult`, before regular failure handling:

```lua
    if not result.ok and render_options.append == true and session then
        session.loading_more = false
        session.load_more_error = result.error or self:translate("Could not load manga.")
        self:renderSourceMangaAppendStatus(session, existing_menu)
        self.plugin:showMessage(session.load_more_error)
        return
    end
```

Wire menu close callback inside `buildBrowseResultMenuOptions`:

```lua
    menu_options.close_callback = function()
        return self:closeSourceMangaSession(session)
    end
```

Add close helper:

```lua
function SuwayomiClient:closeSourceMangaSession(session)
    if not session then
        return
    end
    if session.active_append_load then
        self:cancelSourceMangaLoad(session.active_append_load, { silent = true })
        session.active_append_load = nil
    end
    self:clearCurrentSourceMangaSession(session)
end
```

When append active starts, store state:

```lua
    if state.append and state.session then
        state.session.active_append_load = state
    end
```

When append finishes, clear it:

```lua
            if state.session and state.session.active_append_load == state then
                state.session.active_append_load = nil
            end
```

Implement filtered auto-load cap after append success:

```lua
    if render_options.append == true and appended_visible_count == 0 and session.has_next_page == true then
        session.filtered_auto_loads = (session.filtered_auto_loads or 0) + 1
        if session.filtered_auto_loads < FILTERED_AUTO_LOAD_LIMIT then
            return self:startSourceMangaAppendLoad(session, existing_menu)
        end
        session.load_more_error = nil
    end
```

- [ ] **Step 14: Update existing source manga expectations**

Run:

```powershell
busted spec/suwayomi_client_source_manga_spec.lua
```

Expected failures should be legacy assertions for `Search - Page N`, `Popular - Page N`, `on_next_page`, and `on_previous_page`.

Update those expectations to:

- `Search: frieren` for search titles.
- `Popular` for popular titles.
- `Latest` for latest titles.
- `on_page_changed` exists when source list is rendered.
- `on_next_page` and `on_previous_page` are nil.
- Empty filtered pages with `has_next_page` render a menu, not an empty-state toast.

- [ ] **Step 15: Run source manga spec until green**

Run:

```powershell
busted spec/suwayomi_client_source_manga_spec.lua
```

Expected: PASS.

- [ ] **Step 16: Commit Task 3**

Run:

```powershell
git add suwayomi/client/source_manga.lua spec/suwayomi_client_source_manga_spec.lua spec/support/suwayomi_client_spec_helper.lua
git commit -m "feat(browse): append source manga pages"
```

---

### Task 4: Update User-Facing Docs And Architecture

**Files:**
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`

- [ ] **Step 1: Update README source-result wording**

In `README.md`, change feature bullet:

```markdown
- Browse sources, search across visible sources, search within a source, continuously load source results, and open manga/chapter actions directly from the server
```

Change usage step that currently mentions `Next page` / `Previous page` to:

```markdown
10. Browse source results like one continuous list. When you reach the end of the loaded results, the plugin loads more manga from the same source when more pages are available.
```

- [ ] **Step 2: Update architecture ownership wording**

In `docs/ARCHITECTURE.md`, update the Browse and Library ownership line for `suwayomi/client/source_manga.lua`:

```markdown
- `suwayomi/client/source_manga.lua`: source mode selection, source-specific search prompts, source manga worker loading, continuous browse result append sessions, and manga action refresh callbacks.
```

Update the "Where To Change Things" table row for source manga:

```markdown
| Source manga loading, source-specific search, continuous browse result append loading, and browse chapter-count enrichment | `suwayomi/client/source_manga.lua`, `suwayomi/client/browse_chapter_counts.lua`, `suwayomi/browse/source_manga_worker.lua`, `suwayomi/browse/chapter_count_worker.lua` | `spec/suwayomi_client_source_manga_spec.lua`, worker specs |
```

- [ ] **Step 3: Review docs diff**

Run:

```powershell
git diff -- README.md docs/ARCHITECTURE.md
```

Expected: only source-result wording changes; no command/runtime layout drift.

- [ ] **Step 4: Commit Task 4**

Run:

```powershell
git add README.md docs/ARCHITECTURE.md
git commit -m "docs: describe continuous source browsing"
```

---

### Task 5: Full Verification

**Files:**
- No source edits expected.

- [ ] **Step 1: Run focused specs**

Run:

```powershell
busted spec/suwayomi_ui_list_menu_spec.lua spec/suwayomi_ui_browse_spec.lua spec/suwayomi_client_source_manga_spec.lua
```

Expected: PASS.

- [ ] **Step 2: Run full test suite**

Run:

```powershell
busted spec
```

Expected: all specs PASS.

- [ ] **Step 3: Run Luacheck**

Run:

```powershell
luacheck --codes spec suwayomi main.lua _meta.lua
```

Expected: `0 warnings` or existing repo success text with all checked files clean.

- [ ] **Step 4: Inspect final diff**

Run:

```powershell
git status --short
git log --oneline --max-count 5
git diff origin/master...HEAD --stat
```

Expected:

- Worktree clean.
- Recent commits include Task 1 through Task 4.
- Diff limited to planned files.

- [ ] **Step 5: Stop for review**

Do not merge or push unless user asks to finalize. Report:

- worktree path
- branch name
- commit list
- verification commands and results
