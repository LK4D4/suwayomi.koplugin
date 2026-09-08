-- Boundary: ChapterMenu.
--
-- Responsibility: Owns chapter row, action, bulk action, and quick-refresh menu construction.
-- Owned state: Builds UI data structures and callbacks; destructive actions remain in suwayomi/chapters/actions.lua.
-- Dependencies: KOReader UI helpers, Suwayomi runtime modules, and the plugin i18n facade are required at module load to match the original plugin runtime.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")
local SuwayomiDebug = require("suwayomi/debug")
local I18n = require("suwayomi/i18n")
local MangaActionMenu = require("suwayomi/manga/action_menu")

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

local function hasCancelableDownloads(self)
    if not self.getDownloadQueue then
        return false
    end
    local queue = self:getDownloadQueue()
    if not queue or not queue.getSnapshot then
        return false
    end
    local snapshot = queue:getSnapshot() or {}
    return #(snapshot.active or {}) > 0 or #(snapshot.queued or {}) > 0
end

-- Controllers expose new(deps) for a consistent boundary; methods remain plugin-bound mixins so this refactor can move code without changing callback behavior.
function ChapterMenu:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

local function guardChapterCallback(owner, callback)
    local is_current = owner.captureChapterActionGuard and owner:captureChapterActionGuard()
    return function(...)
        if owner.suwayomi_host_retired or (is_current and not is_current()) then return false end
        return callback(...)
    end
end

function Methods:getChapterTitleBarMenuOptions(manga)
    if not self.getTitleBarMenuOptions then
        return {}
    end
    local context = self.current_chapter_context
    local manga_id = manga and tostring(manga.id or manga.title)
    return self:getTitleBarMenuOptions({
        title = self:formatChapterListTitle(manga),
        actions = self:getBulkChapterActions(),
        vertical = true,
        destructive_actions_at_bottom = true,
        -- Retained title options outlive failed reloads; capture request freshness on opening.
        captureActionGuard = function()
            local is_current = self.captureChapterActionGuard and self:captureChapterActionGuard()
            return function()
                return not self.suwayomi_host_retired and self.current_chapter_context == context
                    and (not context or context.manga == manga)
                    and (not manga or tostring(manga.id or manga.title) == manga_id)
                    and (not is_current or is_current())
            end
        end,
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

    for _index, chapter in ipairs(chapters or {}) do
        local item = {}
        for key, value in pairs(chapter) do
            item[key] = value
        end

        local chapter_exists = false
        local chapter_path
        if download_directory and download_directory ~= "" then
            chapter_path = select(2, SuwayomiDownloader:getTargetPath(download_directory, manga, item))
            if SuwayomiDownloader.findExistingChapterPath then
                chapter_path = SuwayomiDownloader:findExistingChapterPath(download_directory, manga, item) or chapter_path
            end
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
                if chapter.is_read ~= true then
                    chapter.is_read = true
                end
                if item._suwayomi_is_read ~= true then
                    item.pending_read_sync = true
                    chapter.pending_read_sync = true
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
        title = self.formatChapterListScreenTitle and self:formatChapterListScreenTitle(manga) or I18n.t("Chapters"),
        chapters = self:buildChapterMenuItems(manga, visible_chapters, ledger),
    }, self:getChapterTitleBarMenuOptions(manga))
end


function Methods:buildCachedChapterMenuMap()
    local items_by_key = {}
    for _index, item in ipairs((self.current_chapter_options and self.current_chapter_options.chapters) or {}) do
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
    for _index, chapter in ipairs(chapters or {}) do
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
        title = self.formatChapterListScreenTitle and self:formatChapterListScreenTitle(manga) or I18n.t("Chapters"),
        chapters = self:buildQuickChapterMenuItems(manga, visible_chapters),
    }, self:getChapterTitleBarMenuOptions(manga))
end


function Methods:getChapterActions(manga, chapter)
    local status = self.getChapterDownloadStatus and self:getChapterDownloadStatus(manga, chapter) or nil
    local downloaded = self:isChapterDownloaded(manga, chapter)
    local actions = {}

    if status and (status.state == "queued" or status.state == "downloading") then
        table.insert(actions, { id = "cancel_download", text = I18n.t("Cancel download"), destructive = true })
    elseif status and status.archive_state == "damaged" then
        table.insert(actions, { id = "redownload", text = I18n.t("Redownload") })
    elseif status and status.archive_state == "unverified" then
        table.insert(actions, { id = "verify_download", text = I18n.t("Verify download") })
    elseif downloaded then
        table.insert(actions, { id = "open", text = I18n.c("chapter action", "Open") })
    elseif status and status.state == "failed" then
        table.insert(actions, { id = "retry_download", text = I18n.t("Retry") })
    else
        table.insert(actions, { id = "download", text = I18n.c("chapter action", "Download") })
    end
    if downloaded and not (status and (status.archive_state == "unverified"
        or status.state == "queued" or status.state == "downloading")) then
        table.insert(actions, { id = "verify_download", text = I18n.t("Verify download") })
    end
    if status and (status.state == "failed" or (status.state == "queued" and status.retry_at)) then
        table.insert(actions, { id = "download_error", text = I18n.t("Download error") })
    end

    if chapter.is_read == true then
        table.insert(actions, { id = "mark_unread", text = I18n.t("Mark as unread") })
    else
        table.insert(actions, { id = "mark_read", text = I18n.t("Mark as read") })
        table.insert(actions, { id = "mark_previous_read", text = I18n.t("Mark previous as read") })
    end
    if downloaded then
        table.insert(actions, { id = "delete", text = I18n.t("Delete from device"), destructive = true })
    end
    return actions
end


function Methods:getBulkChapterActions()
    local actions = {}
    local show_scanlator_filter = self.current_scanlator_filter ~= nil
        or #(self:getChapterScanlatorChoices((self.current_chapter_context and self.current_chapter_context.chapters) or {})) > 0

    if self:getSelectedChapterCount() > 0 then
        table.insert(actions, { id = "download_selected", text = self:getSelectedChapterCount() > (self.max_batch_queue_chapters or 50)
            and I18n.t("Download selected (up to 50 new)") or I18n.t("Download selected") })
        table.insert(actions, { id = "mark_read_selected", text = I18n.t("Mark read") })
        table.insert(actions, { id = "mark_unread_selected", text = I18n.t("Mark unread") })
        table.insert(actions, { id = "clear_selection", text = I18n.t("Clear selection") })
        if show_scanlator_filter then
            table.insert(actions, { id = "scanlator_filter", text = I18n.t("Scanlator filter"), submenu = true })
        end
        if hasCancelableDownloads(self) then
            table.insert(actions, { id = "cancel_all_downloads", text = I18n.t("Cancel all downloads"), destructive = true })
        end
        table.insert(actions, { id = "delete_selected", text = I18n.t("Delete downloads"), destructive = true })
        return actions
    end

    if self.current_chapter_context and #(self:getVisibleChapters(self.current_chapter_context.chapters or {})) > 0 then
        table.insert(actions, { id = "select_all", text = I18n.t("Select all") })
    end

    local manga_actions = MangaActionMenu.buildMainActions(self, self.current_chapter_context and self.current_chapter_context.manga, {})
    for _index, action in ipairs(manga_actions) do
        table.insert(actions, action)
    end
    if show_scanlator_filter then
        table.insert(actions, { id = "scanlator_filter", text = I18n.t("Scanlator filter"), submenu = true })
    end
    if hasCancelableDownloads(self) then
        table.insert(actions, { id = "cancel_all_downloads", text = I18n.t("Cancel all downloads"), destructive = true })
    end

    return actions
end


function Methods:getBulkDownloadActions()
    return MangaActionMenu.buildBulkDownloadActions()
end


function Methods:showBulkActionConfirmation(text, ok_text, callback, on_stale)
    local is_current = self.captureChapterActionGuard and self:captureChapterActionGuard()
    local function accept()
        if is_current and not is_current() then
            if on_stale and not self.suwayomi_host_retired then return on_stale() end
            return false
        end
        return callback()
    end
    if SuwayomiUI.showConfirm then
        SuwayomiUI.showConfirm({
            text = text,
            ok_text = ok_text,
            ok_callback = accept,
        })
    else
        accept()
    end
    return true
end


function Methods:showScanlatorFilterActions(menu_context)
    if not SuwayomiUI.showChapterActionsMenu then
        return false
    end

    SuwayomiUI.showChapterActionsMenu({
        title = I18n.t("Scanlator filter"),
        actions = self:getScanlatorFilterActions(),
        anchor = menu_context and menu_context.anchor,
        on_back = guardChapterCallback(self, function()
            self:showBulkChapterActions(menu_context)
        end),
    }, guardChapterCallback(self, function(action)
        if action.id == "scanlator_filter_all" then
            self:setScanlatorFilter(nil)
        else
            self:setScanlatorFilter(action.scanlator)
        end
    end))
    return true
end


function Methods:showBulkDownloadActions(menu_context)
    if not SuwayomiUI.showChapterActionsMenu then
        return
    end

    SuwayomiUI.showChapterActionsMenu({
        title = I18n.t("Bulk downloads"),
        actions = self:getBulkDownloadActions(),
        anchor = menu_context and menu_context.anchor,
        on_back = guardChapterCallback(self, function()
            self:showBulkChapterActions(menu_context)
        end),
    }, guardChapterCallback(self, function(action)
        self:performBulkChapterAction(action.id)
    end))
end


function Methods:showKeepDownloadedActions(menu_context)
    if not SuwayomiUI.showChapterActionsMenu then
        return
    end

    SuwayomiUI.showChapterActionsMenu({
        title = I18n.t("Download ahead"),
        actions = MangaActionMenu.buildKeepDownloadedActions(),
        anchor = menu_context and menu_context.anchor,
        on_back = guardChapterCallback(self, function()
            self:showBulkChapterActions(menu_context)
        end),
    }, guardChapterCallback(self, function(action)
        self:performBulkChapterAction(action.id, menu_context)
    end))
end


function Methods:showBulkChapterActions(menu_context)
    if not SuwayomiUI.showChapterActionsMenu then
        self:downloadSelectedChapters()
        return
    end

    local count = self:getSelectedChapterCount()
    local title = I18n.t("Chapter downloads")
    if count > 0 then
        title = I18n.count(count, "%1 selected chapter", "%1 selected chapters")
    end
    local options = {
        title = title,
        actions = self:getBulkChapterActions(),
        anchor = menu_context and menu_context.anchor,
    }

    SuwayomiUI.showChapterActionsMenu(options, guardChapterCallback(self, function(action)
        self:performBulkChapterAction(action.id, menu_context)
    end))
end


function Methods:showChapterActions(manga, chapter)
    local is_current = self.captureChapterActionGuard and self:captureChapterActionGuard()
    if not SuwayomiUI.showChapterActionsMenu then
        self:enqueueChapterDownload(manga, chapter)
        return
    end

    local options = {
        title = chapter.name,
        actions = self:getChapterActions(manga, chapter),
    }

    SuwayomiUI.showChapterActionsMenu(options, function(action)
        if is_current and not is_current() then return false end
        return self:performChapterAction(manga, chapter, action.id)
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
