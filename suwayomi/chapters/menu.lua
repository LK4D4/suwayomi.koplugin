-- Boundary: ChapterMenu.
--
-- Responsibility: Owns chapter row, action, bulk action, and quick-refresh menu construction.
-- Owned state: Builds UI data structures and callbacks; destructive actions remain in suwayomi/chapters/actions.lua.
-- Dependencies: KOReader UI helpers, Suwayomi runtime modules, and gettext are required at module load to match the original plugin runtime.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")
local SuwayomiDebug = require("suwayomi/debug")
local _ = require("gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template

local ChapterMenu = {}
ChapterMenu.__index = ChapterMenu

local function copyDownloadStatus(status)
    if type(status) ~= "table" then
        return nil
    end
    if status.state ~= "downloaded" and status.state ~= "skipped" then
        return nil
    end
    return {
        state = status.state,
    }
end

local function copyTitleBarOptions(target, title_options)
    for key, value in pairs(title_options or {}) do
        target[key] = value
    end
    return target
end

-- Controllers expose new(deps) for a consistent boundary; methods remain plugin-bound mixins so this refactor can move code without changing callback behavior.
function ChapterMenu:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

function Methods:getChapterTitleBarMenuOptions()
    if not self.getTitleBarMenuOptions then
        return {}
    end
    return self:getTitleBarMenuOptions({
        title = _("Chapter downloads"),
        actions = self:getBulkChapterActions(),
        vertical = true,
        destructive_actions_at_bottom = true,
        onSelect = function(action, _, menu_context)
            return self:performBulkChapterAction(action.id, menu_context)
        end,
    })
end

function Methods:buildChapterMenuItems(manga, chapters, ledger)
    local started_at = SuwayomiDebug.now()
    local SuwayomiDownloader = require("suwayomi/downloads/downloader")
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    local history_paths = self:loadKoreaderHistoryPaths()
    local items = {}
    local downloaded_count = 0
    local metadata_finished_count = 0
    local history_read_count = 0
    local metadata_write_count = 0
    local ledger_upsert_count = 0
    local reader_return_entries = {}

    for _, chapter in ipairs(chapters or {}) do
        local item = {}
        for key, value in pairs(chapter) do
            item[key] = value
        end

        local chapter_exists = false
        local chapter_path
        if download_directory and download_directory ~= "" then
            _, chapter_path = SuwayomiDownloader:getTargetPath(download_directory, manga, item)
            chapter_exists = SuwayomiDownloader:chapterExists(chapter_path)
            local metadata_finished = chapter_exists and self:isChapterPathFinishedInKoreader(chapter_path)
            local history_read = chapter_exists and history_paths[chapter_path] == true
            if chapter_exists then
                downloaded_count = downloaded_count + 1
            end
            if metadata_finished then
                metadata_finished_count = metadata_finished_count + 1
            end
            if history_read then
                history_read_count = history_read_count + 1
            end
            if metadata_finished or history_read then
                item.is_read = true
                if item._suwayomi_is_read ~= true then
                    item.pending_read_sync = true
                end
            end
            if chapter_exists and item.is_read == true and not metadata_finished then
                self:setKoreaderChapterReadState(chapter_path, true)
                metadata_write_count = metadata_write_count + 1
            end
        end

        if chapter_exists then
            local updates = {
                path = chapter_path,
                read = item.is_read == true,
                pending_read_sync = item.pending_read_sync == true or nil,
            }
            if ledger then
                self:upsertChapterLedgerEntryInLedger(ledger, manga, item, updates)
            else
                self:upsertChapterLedgerEntry(manga, item, updates)
            end
            reader_return_entries[#reader_return_entries + 1] = {
                chapter = item,
                path = chapter_path,
            }
            ledger_upsert_count = ledger_upsert_count + 1
        end

        local status = self:getChapterDownloadStatus(manga, item)
        if chapter_exists and status and status.state == "failed" then
            -- A recovered archive is more trustworthy than stale queue status from an interrupted worker.
            self:getDownloadQueue():clearStatus(manga, item, { quiet = true })
            status = { state = "downloaded" }
        end
        if not status then
            if chapter_exists then
                status = { state = "downloaded" }
            elseif item.is_read then
                status = { state = "read" }
            end
        end
        item.menu_text = item.name
        item._suwayomi_download_status = copyDownloadStatus(status)
        item.menu_status = self:getDownloadQueue():formatChapterMenuStatus(item, status)
        if self.selection_mode then
            if self:isChapterSelected(manga, item) then
                item.menu_status = self:addChapterSelectionMarker(item.menu_status)
            end
        end

        table.insert(items, item)
    end

    if self.saveReaderReturnContextsForChapters then
        self:saveReaderReturnContextsForChapters(manga, reader_return_entries)
    end

    SuwayomiDebug.log({
        operation = "buildChapterMenuItems",
        event = "end",
        manga_id = manga and manga.id,
        chapter_count = #(chapters or {}),
        downloaded_count = downloaded_count,
        metadata_finished_count = metadata_finished_count,
        history_read_count = history_read_count,
        metadata_write_count = metadata_write_count,
        ledger_upsert_count = ledger_upsert_count,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
    return items
end


function Methods:buildChapterMenuOptions(manga, chapters, ledger)
    local visible_chapters = self:getVisibleChapters(chapters)

    return copyTitleBarOptions({
        title = self:formatChapterListTitle(manga),
        chapters = self:buildChapterMenuItems(manga, visible_chapters, ledger),
    }, self:getChapterTitleBarMenuOptions())
end


function Methods:buildCachedChapterMenuMap()
    local items_by_key = {}
    for _, item in ipairs((self.current_chapter_options and self.current_chapter_options.chapters) or {}) do
        items_by_key[self:getChapterDownloadKey(
            self.current_chapter_context.manga,
            item
        )] = item
    end
    return items_by_key
end


function Methods:buildQuickChapterMenuItems(manga, chapters)
    local cached_items = self:buildCachedChapterMenuMap()
    local items = {}
    for _, chapter in ipairs(chapters or {}) do
        local item = {}
        for key, value in pairs(chapter) do
            item[key] = value
        end

        local cached = cached_items[self:getChapterDownloadKey(manga, item)]
        local status = self:getChapterDownloadStatus(manga, item)
        if status then
            item.menu_text = item.name
            item._suwayomi_download_status = copyDownloadStatus(status)
            item.menu_status = self:getDownloadQueue():formatChapterMenuStatus(item, status)
        elseif cached and cached._suwayomi_download_status then
            item.menu_text = item.name
            item._suwayomi_download_status = copyDownloadStatus(cached._suwayomi_download_status)
            item.menu_status = self:getDownloadQueue():formatChapterMenuStatus(item, item._suwayomi_download_status)
        elseif item.is_read then
            item.menu_text = item.name
            item.menu_status = self:getDownloadQueue():formatChapterMenuStatus(item, { state = "read" })
        elseif item.is_read == nil and cached and cached.menu_text then
            item.menu_text = self:stripChapterSelectionMarker(cached.menu_text)
            item.menu_status = self:stripChapterSelectionStatus(cached.menu_status)
        else
            item.menu_text = item.name
            item.menu_status = nil
        end

        if self.selection_mode then
            if self:isChapterSelected(manga, item) then
                item.menu_status = self:addChapterSelectionMarker(item.menu_status)
            end
        end

        table.insert(items, item)
    end
    return items
end


function Methods:stripChapterSelectionMarker(menu_text)
    return tostring(menu_text or ""):gsub("^%[[x ]%]%s+", "", 1)
end


function Methods:buildQuickChapterMenuOptions(manga, chapters)
    local visible_chapters = self:getVisibleChapters(chapters)

    return copyTitleBarOptions({
        title = self:formatChapterListTitle(manga),
        chapters = self:buildQuickChapterMenuItems(manga, visible_chapters),
    }, self:getChapterTitleBarMenuOptions())
end


function Methods:getChapterActions(manga, chapter)
    local downloaded = self:isChapterDownloaded(manga, chapter)
    local actions = {}

    if downloaded then
        table.insert(actions, { id = "open", text = _("Open") })
    else
        table.insert(actions, { id = "download", text = _("Download") })
    end

    if chapter.is_read == true then
        table.insert(actions, { id = "mark_unread", text = _("Mark as unread") })
    else
        table.insert(actions, { id = "mark_read", text = _("Mark as read") })
        table.insert(actions, { id = "mark_previous_read", text = _("Mark previous as read") })
        table.insert(actions, { id = "mark_through_read", text = _("Mark through here") })
    end
    if downloaded then
        table.insert(actions, { id = "delete", text = _("Delete from device"), destructive = true })
    end
    return actions
end


function Methods:getBulkChapterActions()
    local actions = {}

    if self:getSelectedChapterCount() > 0 then
        table.insert(actions, { id = "download_selected", text = _("Download selected") })
        table.insert(actions, { id = "mark_read_selected", text = _("Mark read") })
        table.insert(actions, { id = "mark_unread_selected", text = _("Mark unread") })
        table.insert(actions, { id = "clear_selection", text = _("Clear selection") })
        if #(self:getChapterScanlatorChoices((self.current_chapter_context and self.current_chapter_context.chapters) or {})) > 0 then
            table.insert(actions, { id = "scanlator_filter", text = _("Scanlator filter"), submenu = true })
        end
        table.insert(actions, { id = "delete_selected", text = _("Delete downloads"), destructive = true })
        return actions
    end

    if self.current_chapter_context and #(self:getVisibleChapters(self.current_chapter_context.chapters or {})) > 0 then
        table.insert(actions, { id = "select_all", text = _("Select all") })
    end

    table.insert(actions, { id = "bulk_downloads", text = _("Bulk downloads"), submenu = true })
    if #(self:getChapterScanlatorChoices((self.current_chapter_context and self.current_chapter_context.chapters) or {})) > 0 then
        table.insert(actions, { id = "scanlator_filter", text = _("Scanlator filter"), submenu = true })
    end
    table.insert(actions, { id = "delete_read_downloaded", text = _("Delete read downloads"), destructive = true })

    return actions
end


function Methods:getBulkDownloadActions()
    local actions = {}

    table.insert(actions, { id = "download_next_5_unread", text = _("Download next 5") })
    table.insert(actions, { id = "download_next_10_unread", text = _("Download next 10") })
    table.insert(actions, { id = "download_next_50_unread", text = _("Download next 50") })
    table.insert(actions, { id = "keep_next_5_unread", text = _("Keep next 5 downloaded") })
    table.insert(actions, { id = "keep_next_10_unread", text = _("Keep next 10 downloaded") })
    table.insert(actions, { id = "keep_next_50_unread", text = _("Keep next 50 downloaded") })

    return actions
end


function Methods:showBulkActionConfirmation(text, ok_text, callback)
    if SuwayomiUI.showConfirm then
        SuwayomiUI.showConfirm({
            text = text,
            ok_text = ok_text,
            ok_callback = callback,
        })
    else
        callback()
    end
    return true
end


function Methods:showScanlatorFilterActions(menu_context)
    if not SuwayomiUI.showChapterActionsMenu then
        return false
    end

    SuwayomiUI.showChapterActionsMenu({
        title = _("Scanlator filter"),
        actions = self:getScanlatorFilterActions(),
        anchor = menu_context and menu_context.anchor,
        on_back = function()
            self:showBulkChapterActions(menu_context)
        end,
    }, function(action)
        if action.id == "scanlator_filter_all" then
            self:setScanlatorFilter(nil)
        else
            self:setScanlatorFilter(action.scanlator)
        end
    end)
    return true
end


function Methods:showBulkDownloadActions(menu_context)
    if not SuwayomiUI.showChapterActionsMenu then
        return
    end

    SuwayomiUI.showChapterActionsMenu({
        title = _("Bulk downloads"),
        actions = self:getBulkDownloadActions(),
        anchor = menu_context and menu_context.anchor,
        on_back = function()
            self:showBulkChapterActions(menu_context)
        end,
    }, function(action)
        self:performBulkChapterAction(action.id)
    end)
end


function Methods:showBulkChapterActions(menu_context)
    if not SuwayomiUI.showChapterActionsMenu then
        self:downloadSelectedChapters()
        return
    end

    local count = self:getSelectedChapterCount()
    local title = _("Chapter downloads")
    if count > 0 then
        title = T(
            self:pluralize(count, _("%1 selected chapter"), _("%1 selected chapters")),
            count
        )
    end
    local options = {
        title = title,
        actions = self:getBulkChapterActions(),
        anchor = menu_context and menu_context.anchor,
    }

    SuwayomiUI.showChapterActionsMenu(options, function(action)
        self:performBulkChapterAction(action.id, menu_context)
    end)
end


function Methods:showChapterActions(manga, chapter)
    if not SuwayomiUI.showChapterActionsMenu then
        self:enqueueChapterDownload(manga, chapter)
        return
    end

    local options = {
        title = chapter.name,
        actions = self:getChapterActions(manga, chapter),
    }

    SuwayomiUI.showChapterActionsMenu(options, function(action)
        self:performChapterAction(manga, chapter, action.id)
    end)
end


function Methods:refreshChapterMenu(options)
    local started_at = SuwayomiDebug.now()
    options = options or {}
    if not self.current_chapter_context then
        return
    end
    self.pending_chapter_menu_refresh = false

    local menu_options_builder = options.quick
        and self.buildQuickChapterMenuOptions
        or self.buildChapterMenuOptions
    local menu_options = menu_options_builder(
        self,
        self.current_chapter_context.manga,
        self.current_chapter_context.chapters,
        options.ledger
    )
    self.current_chapter_options = self.current_chapter_options or {}
    self.current_chapter_options.title = menu_options.title
    self.current_chapter_options.chapters = menu_options.chapters
    self.current_chapter_options.title_bar_left_icon = menu_options.title_bar_left_icon
    self.current_chapter_options.on_title_bar_left_tap = menu_options.on_title_bar_left_tap

    if SuwayomiUI.updateChapterMenu then
        SuwayomiUI.updateChapterMenu(self.current_chapter_menu, menu_options, function(chapter)
            self:handleChapterTap(self.current_chapter_context.manga, chapter)
        end, function(chapter)
            self:toggleChapterSelection(self.current_chapter_context.manga, chapter)
        end)
    elseif self.current_chapter_menu and self.current_chapter_menu.updateItems then
        self.current_chapter_menu:updateItems(nil, true)
    end
    SuwayomiDebug.log({
        operation = "refreshChapterMenu",
        event = "end",
        quick = options.quick == true,
        chapter_count = #(self.current_chapter_context.chapters or {}),
        selected_count = self:getSelectedChapterCount(),
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
end


ChapterMenu.methods = Methods

return ChapterMenu
