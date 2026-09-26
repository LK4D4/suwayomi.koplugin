-- Boundary: ChapterMenu.
--
-- Responsibility: Owns chapter menus and render reconciliation; local_downloads decides record association and read authority.
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
    return #(snapshot.active or {}) > 0 or #(snapshot.queued or {}) > 0 or #(snapshot.refills or {}) > 0
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
    local menu = owner.current_chapter_menu
    local is_current = owner.captureChapterActionGuard and owner:captureChapterActionGuard()
    return function(...)
        if owner.suwayomi_host_retired or (is_current and not is_current()) then return false end
        if menu and owner.isSuwayomiScreenActive and not owner:isSuwayomiScreenActive(menu) then return false end
        if menu and owner.suwayomi_navigation and not owner.suwayomi_navigation:isCurrent(menu) then return false end
        return callback(...)
    end
end

function Methods:getChapterTitleBarMenuOptions(manga, lookup)
    if not self.getTitleBarMenuOptions then
        return {}
    end
    local context = self.current_chapter_context
    local manga_id = manga and tostring(manga.id or manga.title)
    return self:getTitleBarMenuOptions({
        title = self:formatChapterListTitle(manga),
        actions = self:getBulkChapterActions(lookup),
        vertical = true,
        destructive_actions_at_bottom = true,
        -- Retained title options outlive failed reloads; capture request freshness on opening.
        captureActionGuard = function()
            local is_current = self.captureChapterActionGuard and self:captureChapterActionGuard()
            local menu = self.current_chapter_menu
            return function()
                return not self.suwayomi_host_retired and self.current_chapter_context == context
                    and self.current_chapter_menu == menu
                    and (not self.suwayomi_navigation or self.suwayomi_navigation:isCurrent(menu))
                    and (not context or context.manga == manga)
                    and (not manga or tostring(manga.id or manga.title) == manga_id)
                    and (not is_current or is_current())
            end
        end,
        onSelect = function(action, _, menu_context)
            if action.refill then return self:performRefillAction(action.refill_action, action.refill) end
            return self:performBulkChapterAction(action.id, menu_context)
        end,
    })
end

-- Keep the supplied ledger separate: its absence makes this render own persistence.
-- A caller-provided lookup must borrow the same read_ledger used for reconciliation.
function Methods:buildChapterMenuItems(manga, chapters, ledger, options, lookup, read_ledger)
    local started_at = SuwayomiDebug.now()
    local saved = manga.local_only or (options and options.saved)
    local items = {}
    local downloaded_count = 0
    local metadata_finished_count = 0
    local metadata_write_count = 0
    local ledger_upsert_count = 0
    local reader_return_entries = {}
    local snapshot = self:getDownloadQueue():getSnapshot()
    local manual_snapshot, manual_error = snapshot.manual_deletion, snapshot.manual_deletion_error
    read_ledger = ledger or read_ledger or self:loadChapterLedger()
    lookup = lookup or (self.buildChapterDownloadLookup and self:buildChapterDownloadLookup(manga, read_ledger))
    local ledger_changed = false

    for _index, chapter in ipairs(chapters or {}) do
        local item = {}
        for key, value in pairs(chapter) do
            item[key] = value
        end
        local local_only = manga.local_only or (self.isLocalOnlyChapter and self:isLocalOnlyChapter(manga, item, lookup))
        item._suwayomi_manual_deletion = not local_only and (manual_snapshot[self:getChapterDownloadKey(manga, item)]
            or (manual_error and { state = "blocked", reason = manual_error } or nil)) or nil
        local read_entry = not local_only and self:getChapterReadEntry(manga, item, lookup)
        local explicit_unread = type(read_entry) == "table"
            and read_entry.pending_read_sync == true and read_entry.pending_read_state == false
        if explicit_unread then
            -- Older sidecar evidence cannot undo a pending explicit unread.
            item.is_read, chapter.is_read = false, false
        end

        local chapter_exists, chapter_path = self:isChapterDownloaded(manga, item, lookup)
        -- Finding readable bytes does not associate them with this server.
        local read_authority = chapter_exists and not local_only
            and self:hasChapterReadAuthority(manga, item, chapter_path, lookup)
        if chapter_exists then
            local metadata_finished = chapter_exists and self:isChapterPathFinishedInKoreader(chapter_path)
            if chapter_exists then
                downloaded_count = downloaded_count + 1
            end
            if metadata_finished then
                metadata_finished_count = metadata_finished_count + 1
            end
            if metadata_finished and not explicit_unread and not (options and options.confirmed_read_state) then
                item.is_read = true
                if chapter.is_read ~= true then
                    chapter.is_read = true
                end
                if read_authority and item._suwayomi_is_read ~= true then
                    item.pending_read_sync = true
                    chapter.pending_read_sync = true
                end
            end
            if not saved and read_authority and item.is_read == true and not metadata_finished then
                self:setKoreaderChapterReadState(chapter_path, true)
                metadata_write_count = metadata_write_count + 1
            end
        end

        if not saved and read_authority then
            local updates = {
                path = chapter_path,
                read = item.is_read == true,
                pending_read_sync = item.pending_read_sync == true or nil,
            }
            self:upsertChapterLedgerEntryInLedger(read_ledger, manga, item, updates)
            ledger_changed = true
            reader_return_entries[#reader_return_entries + 1] = {
                chapter = item,
                path = chapter_path,
            }
            ledger_upsert_count = ledger_upsert_count + 1
        end

        local status = not local_only and self:getChapterDownloadStatus(manga, item) or nil

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

    if not ledger and ledger_changed then
        local persisted, err = self:saveChapterLedger(read_ledger)
        if not persisted then
            self:showMessage(err or I18n.t("Failed to save settings."))
            local committed = self:loadChapterLedger()
            for _, chapter in ipairs(chapters or {}) do
                local entry = committed[self:getChapterLedgerKey(manga, chapter)]
                if entry then chapter.is_read = entry.read == true
                else chapter.is_read = chapter._suwayomi_is_read == true end
                chapter.pending_read_sync = entry and entry.pending_read_sync
            end
            return nil, err
        end
    end
    if not saved and not ledger and self.saveReaderReturnContextsForChapters then
        self:saveReaderReturnContextsForChapters(manga, reader_return_entries)
    end

    SuwayomiDebug.log({
        operation = "buildChapterMenuItems",
        event = "end",
        manga_id = manga and manga.id,
        chapter_count = #(chapters or {}),
        downloaded_count = downloaded_count,
        metadata_finished_count = metadata_finished_count,
        metadata_write_count = metadata_write_count,
        ledger_upsert_count = ledger_upsert_count,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
    return items
end


function Methods:buildChapterMenuOptions(manga, chapters, ledger, options)
    local visible_chapters = self:getVisibleChapters(chapters)
    local read_ledger = ledger or self:loadChapterLedger()
    local lookup = self.buildChapterDownloadLookup and self:buildChapterDownloadLookup(manga, read_ledger)
    local items, err = self:buildChapterMenuItems(manga, visible_chapters, ledger, options, lookup, read_ledger)
    if not items then return nil, err end

    return copyTitleBarOptions({
        title = self.formatChapterListScreenTitle and self:formatChapterListScreenTitle(manga) or I18n.t("Chapters"),
        chapters = items,
    }, self:getChapterTitleBarMenuOptions(manga, lookup))
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


function Methods:buildQuickChapterMenuItems(manga, chapters, lookup, read_ledger)
    read_ledger = read_ledger or self:loadChapterLedger()
    lookup = lookup or (self.buildChapterDownloadLookup and self:buildChapterDownloadLookup(manga, read_ledger))
    if manga.local_only then
        return self:buildChapterMenuItems(manga, chapters, nil, { saved = true }, lookup, read_ledger)
    end
    if self.isLocalOnlyChapter then
        for _, chapter in ipairs(chapters or {}) do
            if self:isLocalOnlyChapter(manga, chapter, lookup) then
                return self:buildChapterMenuItems(manga, chapters, nil, { saved = true }, lookup, read_ledger)
            end
        end
    end
    local cached_items = self:buildCachedChapterMenuMap()
    local items = {}
    local snapshot = self:getDownloadQueue():getSnapshot()
    local manual_snapshot, manual_error = snapshot.manual_deletion, snapshot.manual_deletion_error
    for _index, chapter in ipairs(chapters or {}) do
        local item = {}
        for key, value in pairs(chapter) do
            item[key] = value
        end
        item._suwayomi_manual_deletion = manual_snapshot[self:getChapterDownloadKey(manga, item)]
            or (manual_error and { state = "blocked", reason = manual_error } or nil)

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
        elseif item.is_read or item._suwayomi_manual_deletion then
            item.menu_text = item.name
            item.menu_status = self:getDownloadQueue():formatChapterMenuStatus(item, item.is_read and { state = "read" } or nil)
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
    local read_ledger = self:loadChapterLedger()
    local lookup = self.buildChapterDownloadLookup and self:buildChapterDownloadLookup(manga, read_ledger)

    return copyTitleBarOptions({
        title = self.formatChapterListScreenTitle and self:formatChapterListScreenTitle(manga) or I18n.t("Chapters"),
        chapters = self:buildQuickChapterMenuItems(manga, visible_chapters, lookup, read_ledger),
    }, self:getChapterTitleBarMenuOptions(manga, lookup))
end


function Methods:getChapterActions(manga, chapter)
    local lookup = self.buildChapterDownloadLookup and self:buildChapterDownloadLookup(manga)
    if manga.local_only or (self.isLocalOnlyChapter and self:isLocalOnlyChapter(manga, chapter, lookup)) then
        if not self:isChapterDownloaded(manga, chapter, lookup) then return {} end
        return {
            { id = "open", text = I18n.c("chapter action", "Open") },
            { id = "verify_download", text = I18n.t("Verify download") },
        }
    end
    local status = self.getChapterDownloadStatus and self:getChapterDownloadStatus(manga, chapter) or nil
    local downloaded = self:isChapterDownloaded(manga, chapter, lookup)
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
        -- A busy rejection or an unproved old target needs a fresh explicit action,
        -- not a deletion Retry control or an unread/read round trip.
        local settings = SuwayomiSettings:loadDeleteChaptersSettings()
        if settings.delete_after_mark_read == true and downloaded then
            table.insert(actions, { id = "mark_read", text = I18n.t("Mark as read") })
        end
    else
        table.insert(actions, { id = "mark_read", text = I18n.t("Mark as read") })
        table.insert(actions, { id = "mark_previous_read", text = I18n.t("Mark previous as read") })
    end
    if downloaded then
        table.insert(actions, { id = "delete", text = I18n.t("Delete from device"), destructive = true })
    end
    return actions
end


function Methods:getBulkChapterActions(lookup)
    local actions = {}
    local context = self.current_chapter_context
    local local_only = context and context.manga and context.manga.local_only
    if context and self.isLocalOnlyChapterContext then
        local_only = self:isLocalOnlyChapterContext(context.manga, context.chapters)
    end
    local show_scanlator_filter = self.current_scanlator_filter ~= nil
        or #(self:getChapterScanlatorChoices((self.current_chapter_context and self.current_chapter_context.chapters) or {})) > 0
    if local_only then
        table.insert(actions, self:getSelectedChapterCount() > 0
            and { id = "clear_selection", text = I18n.t("Clear selection") }
            or { id = "select_all", text = I18n.t("Select all") })
        if show_scanlator_filter then
            table.insert(actions, { id = "scanlator_filter", text = I18n.t("Scanlator filter"), submenu = true })
        end
        if context.manga.id and not context.manga.local_only and context.manga.endpoint_scope
            and context.manga.endpoint_scope == SuwayomiSettings:normalizeEndpointScope(SuwayomiSettings:load().server_url) then
            table.insert(actions, { id = "refresh_chapters", text = I18n.t("Refresh chapters") })
        end
        return actions
    end
    local refill = context and self:getMangaRefillRequest(context.manga)
    if refill and refill.manga_id ~= nil and refill.revision ~= nil then
        table.insert(actions, {
            id = "retry_refill", text = I18n.t("Check again") .. "\n" .. SuwayomiUI.formatRefillStatus(refill),
            refill = refill, refill_action = "retry",
        })
        table.insert(actions, {
            id = "stop_refill", text = I18n.t("Turn off auto-download"), refill = refill, refill_action = "stop",
        })
    elseif refill then
        table.insert(actions, { id = "refill_status", text = SuwayomiUI.formatRefillStatus(refill), enabled = false })
    end

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

    local manga_actions = MangaActionMenu.buildMainActions(self, self.current_chapter_context and self.current_chapter_context.manga,
        { download_lookup = lookup })
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
        title = I18n.t("Auto-download"),
        actions = MangaActionMenu.buildKeepDownloadedActions(self, self.current_chapter_context and self.current_chapter_context.manga),
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
        if action.refill then return self:performRefillAction(action.refill_action, action.refill) end
        self:performBulkChapterAction(action.id, menu_context)
    end))
end


function Methods:showChapterActions(manga, chapter)
    local is_current = self.captureChapterActionGuard and self:captureChapterActionGuard()
    if not SuwayomiUI.showChapterActionsMenu then
        self:enqueueChapterDownload(manga, chapter)
        return
    end

    local actions = self:getChapterActions(manga, chapter)
    if #actions == 0 then
        self:showMessage(I18n.t("This chapter is not downloaded."))
        return
    end

    local options = {
        title = chapter.name,
        actions = actions,
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
    if options.saved == nil then options.saved = self.current_chapter_context.saved end
    self.pending_chapter_menu_refresh = false

    local menu_options_builder = options.quick
        and self.buildQuickChapterMenuOptions
        or self.buildChapterMenuOptions
    local menu_options = menu_options_builder(
        self,
        self.current_chapter_context.manga,
        self.current_chapter_context.chapters,
        options.ledger,
        options
    )
    if not menu_options then return false end
    menu_options.empty_text = self.current_chapter_options and self.current_chapter_options.empty_text
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
