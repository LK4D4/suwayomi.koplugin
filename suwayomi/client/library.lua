-- Boundary: library flow.
--
-- Responsibility: project saved/loaded Library membership with session sorting and observational status.
-- Owned state: one Library session and its cancellable request on the client.
-- Dependencies: checked settings, normal Library widgets, and the request worker.
-- External data: only complete scoped snapshots are persisted; unassociated reconstruction permits local reading only.

local M = {}
local I18n = require("suwayomi/i18n")
local ListRows = require("suwayomi/ui/list_rows")

local function discoveryTime(manga)
    local value = manga.latest_fetched_at
    if type(value) ~= "number" or value <= 0 or value == math.huge or value ~= math.floor(value) then return nil end
    local ok, date = pcall(os.date, "%Y-%m-%d", value)
    if ok and type(date) == "string" and date ~= "" then return value end
end

local function mangaIdentity(manga)
    return tostring(manga.id or manga.local_manga_path or "")
        .. "\n" .. tostring(manga.endpoint_scope or "")
end

local function sortLibraryRows(rows, mode)
    table.sort(rows, function(a, b)
        if mode == "latest_arrivals" then
            local a_time, b_time = discoveryTime(a), discoveryTime(b)
            if a_time ~= b_time then
                if not a_time then return false end
                if not b_time then return true end
                return a_time > b_time
            end
        end
        local a_title, b_title = ListRows.getMangaTitle(a), ListRows.getMangaTitle(b)
        if a_title ~= b_title then return a_title < b_title end
        return mangaIdentity(a) < mangaIdentity(b)
    end)
end

function M.install(SuwayomiClient)
function SuwayomiClient:mangaBelongsToCategory(manga, category)
    if not category or not category.id then return true end
    if tostring(category.id) == "0" and #(manga.categories or {}) == 0 then return true end
    for _, candidate in ipairs(manga.categories or {}) do
        if tostring(candidate.id) == tostring(category.id) then return true end
    end
    return false
end

function SuwayomiClient:filterLibraryMangaByCategory(manga_list, category)
    local rows = {}
    for _, manga in ipairs(manga_list or {}) do
        if self:mangaBelongsToCategory(manga, category) then rows[#rows + 1] = manga end
    end
    return rows
end

function SuwayomiClient:buildLibraryCategoryChoices(categories)
    local choices = { { name = I18n.t("All manga") } }
    for _, category in ipairs(categories or {}) do choices[#choices + 1] = category end
    return choices
end

local function live(self, session)
    if self.library_session ~= session or session.closed or self.plugin.suwayomi_host_retired then return false end
    if session.scope ~= self.settings:normalizeEndpointScope(self.settings:load().server_url) then return false end
    local widget = session.manga_menu or session.category_menu
    return not widget or not self.plugin.isSuwayomiScreenActive or self.plugin:isSuwayomiScreenActive(widget)
end

local function notify(self, message)
    self.plugin:showMessage(message, { timeout = 3, toast = true })
end

function SuwayomiClient:cancelLibraryNetworkRequests()
    local session = self.library_session
    if not session then return end
    session.request, session.refreshing = nil, false
    if session.active then self:getNetworkRequestJob().cancel(session.active) end
    session.active = nil
end

local renderLibrary
local function refreshLibrary(self, session, background)
    if not live(self, session) then return false end
    self:cancelLibraryNetworkRequests()
    local quiet = background and (session.saved or #session.listing.manga > 0)
    local token = {}
    session.request = token
    session.refreshing, session.refresh_failed = true, false
    renderLibrary(self, session)
    local function failed()
        session.request, session.active, session.refreshing = nil, nil, false
        session.refresh_failed = true
        renderLibrary(self, session)
        if not quiet then
            local message = (session.saved or #session.listing.manga > 0)
                and I18n.t("Could not refresh Library. Showing retained information.")
                or I18n.t("Could not refresh Library. No saved information is available.")
            notify(self, message)
        end
    end
    local ok, active = pcall(self:getNetworkRequestJob().start, {
        owner = self.plugin,
        credentials = session.credentials,
        request = { action = "fetch_library_snapshot" },
        result_prefix = "library_request",
        timeout_seconds = self:getNetworkRequestTimeoutSeconds(),
        on_cancel = function()
            if session.request == token then
                session.request, session.active, session.refreshing = nil, nil, false
                if live(self, session) then renderLibrary(self, session) end
            end
        end,
        on_finish = function(result)
            if not live(self, session) or session.request ~= token then return end
            session.request, session.active, session.refreshing = nil, nil, false
            if not result or not result.ok or type(result.categories) ~= "table"
                or type(result.manga) ~= "table" then
                failed()
                return
            end
            session.listing = result
            session.saved = true
            session.information = "loaded"
            if session.category and session.category.id ~= nil then
                local selected_id = tostring(session.category.id)
                session.category = nil
                for _, category in ipairs(result.categories) do
                    if tostring(category.id) == selected_id then
                        session.category = category
                        break
                    end
                end
            end
            local saved = self.settings:saveLibraryCache(session.credentials, result)
            session.saved_for_restart = saved ~= nil and saved ~= false
            renderLibrary(self, session)
            if not saved then
                notify(self, I18n.t("Library loaded, but could not be saved for next time."))
            end
        end,
    })
    if not ok or not active then
        if session.request == token then
            failed()
        end
        return false
    end
    if session.request == token then session.active = active end
    return true
end

local function menuOptions(self, session)
    local options = self:getTitleBarMenuOptions({
        title = I18n.t("Suwayomi Library"),
        actions = {
            { id = "refresh", text = I18n.t("Refresh") },
            { id = "sort_latest_arrivals", text = I18n.t("Latest arrivals") },
            { id = "sort_title", text = I18n.t("Title") },
        },
        captureActionGuard = function() return function() return live(self, session) end end,
        onSelect = function(action)
            if action.id == "refresh" then return refreshLibrary(self, session) end
            if action.id == "sort_latest_arrivals" or action.id == "sort_title" then
                session.sort_mode = action.id == "sort_title" and "title" or "latest_arrivals"
                renderLibrary(self, session)
            end
        end,
    }) or {}
    options.thumbnail_credentials = session.credentials
    local status = { session.information == "loaded" and I18n.t("Loaded information")
        or (session.saved and I18n.t("Saved information") or I18n.t("Reconstructed information")) }
    if not session.saved and #session.listing.manga == 0 then status[1] = I18n.t("No saved information") end
    if session.information == "loaded" and not session.saved_for_restart then
        status[#status + 1] = I18n.t("Not saved for restart")
    end
    if session.refreshing then status[#status + 1] = I18n.t("Refreshing") end
    if session.refresh_failed then
        status[#status + 1] = (session.saved or #session.listing.manga > 0)
            and I18n.t("Refresh failed; information retained") or I18n.t("Refresh failed; information unavailable")
    end
    if session.listing.arrivals_supported == false then
        status[#status + 1] = I18n.t("Latest arrivals unavailable; using Title")
    else
        status[#status + 1] = session.sort_mode == "title" and I18n.t("Title") or I18n.t("Latest arrivals")
    end
    options.library_status = I18n.join(status, " · ")
    return options
end

local function pendingLibraryChoices(self, session, rows)
    local pending, by_id = {}, {}
    if not session.scope or session.scope == "" then return pending end
    local function validID(value)
        local id = (type(value) == "number" or type(value) == "string") and tonumber(value)
        return id and id > 0 and id <= 9007199254740991 and id == math.floor(id) and tostring(id) or nil
    end
    for _, entry in pairs(self.settings:loadChapterLedger() or {}) do
        if type(entry) == "table" and entry.pending_read_sync == true then
            local id = validID(entry.manga_id)
            local scope = self.settings:normalizeEndpointScope(entry.endpoint_scope)
            if id and scope and scope ~= "" and scope == session.scope then by_id[id] = true end
        end
    end
    for _, manga in ipairs(rows) do
        local id = validID(manga.id)
        local scope = self.settings:normalizeEndpointScope(manga.endpoint_scope)
        if not scope and session.saved and not manga.local_only then scope = session.scope end
        if id and scope == session.scope and by_id[id] then pending[manga] = true end
    end
    return pending
end

local function renderManga(self, session)
    local rows = self:filterLibraryMangaByCategory(session.listing.manga, session.category)
    sortLibraryRows(rows, session.listing.arrivals_supported == false and "title" or session.sort_mode)
    local options = menuOptions(self, session)
    options.library_pending = pendingLibraryChoices(self, session, rows)
    if not session.saved and #rows == 0 then
        options.empty_text = I18n.t("No saved Library information is available.")
    elseif session.category and session.category.id then
        options.empty_text = I18n.t("No manga in this library category.")
    else
        options.empty_text = I18n.t("Your Suwayomi library is empty.")
    end
    local function select(manga)
        if not live(self, session) then return end
        session.category_selected = true
        if session.saved then manga.endpoint_scope = session.scope end
        if manga.local_only then
            self.plugin:showChaptersForManga(manga)
            return
        end
        local function updated(updated_manga)
            if not live(self, session) then return end
            updated_manga = updated_manga or manga
            for index = #session.listing.manga, 1, -1 do
                if tostring(session.listing.manga[index].id) == tostring(updated_manga.id) then
                    if updated_manga.in_library == false then
                        table.remove(session.listing.manga, index)
                    else
                        local previous = session.listing.manga[index]
                        -- Nested actions do not reload the Library snapshot's discovery/aggregate metadata.
                        updated_manga.latest_fetched_at = previous.latest_fetched_at
                        updated_manga.unread_count = previous.unread_count
                        session.listing.manga[index] = updated_manga
                    end
                end
            end
            renderManga(self, session)
        end
        if self.plugin.showMangaActions then
            self.plugin:showMangaActions(manga, { onMangaUpdated = updated })
        else
            self.plugin:showChaptersForManga(manga)
        end
    end
    if session.manga_menu then
        options.close_callback = session.manga_menu.close_callback
        self.ui.updateLibraryMangaMenu(session.manga_menu, rows, select, options)
    else
        options.close_callback = function()
            session.manga_menu = nil
            if not session.category_menu then
                session.closed = true
                self:cancelLibraryNetworkRequests()
            end
        end
        session.manga_menu = self.ui.showLibraryMangaMenu(rows, select, options)
        self:trackScreen("library", session.manga_menu)
    end
end

renderLibrary = function(self, session)
    local categories = session.listing.categories
    local behavior = self.settings:loadLibraryCategoryPickerBehavior()
    local picker = #categories > 0 and (behavior == "always" or (behavior == "automatic" and #categories > 1))
    if session.category_menu or (picker and not session.category_selected) then
        local options = menuOptions(self, session)
        local function select(category)
            if not live(self, session) then return end
            session.category, session.category_selected = category, true
            renderManga(self, session)
        end
        local choices = self:buildLibraryCategoryChoices(categories)
        if session.category_menu then
            options.close_callback = session.category_menu.close_callback
            self.ui.updateLibraryCategoryMenu(session.category_menu, choices, select, options)
        else
            if session.manga_menu then
                local menu = session.manga_menu
                session.manga_menu = nil
                menu.close_callback = nil
                self:getUIManager():close(menu)
                if self.plugin.getNavigation then self.plugin:getNavigation():pop(menu) end
            end
            options.close_callback = function()
                session.closed = true
                self:cancelLibraryNetworkRequests()
            end
            session.category_menu = self.ui.showLibraryCategoryMenu(choices, select, options)
            self:trackScreen("library-categories", session.category_menu)
        end
        if session.manga_menu then renderManga(self, session) end
    else
        renderManga(self, session)
    end
end

local function reconstructLibrary(self, scope)
    local lfs = require("suwayomi/fs")
    local by_id, categories = {}, {}
    local function add(entry)
        if type(entry) ~= "table" or type(entry.path) ~= "string"
            or (not entry.manga_id and not entry.path:match("^(.*)[/\\][^/\\]+$"))
            or (entry.endpoint_scope and entry.endpoint_scope ~= scope)
            or lfs.attributes(entry.path, "mode") ~= "file" then return end
        local local_manga_path = not entry.manga_id and entry.path:match("^(.*)[/\\][^/\\]+$")
        local key = entry.manga_id and tostring(entry.manga_id) or local_manga_path
        local manga = by_id[key]
        if manga and manga.endpoint_scope ~= entry.endpoint_scope then
            -- Scoped metadata wins as a unit; matching IDs do not associate legacy rows.
            if manga.endpoint_scope then return end
            manga = nil
        end
        manga = manga or { id = entry.manga_id, endpoint_scope = entry.endpoint_scope, categories = {},
            local_only = entry.endpoint_scope == nil or entry.manga_id == nil,
            local_manga_path = local_manga_path }
        by_id[key] = manga
        manga.title = manga.title or entry.manga_title
        manga.source = manga.source or entry.source
        manga.thumbnail_url = manga.thumbnail_url or entry.thumbnail_url
        -- Pre-cache releases saved identities but not cover URLs. Suwayomi's
        -- standard relative cover route also addresses those existing thumbnails.
        if not manga.thumbnail_url and entry.endpoint_scope == scope and scope and key:match("^%d+$") then
            manga.thumbnail_url = "/api/v1/manga/" .. key .. "/thumbnail"
        end
        for _, category in ipairs(entry.categories or {}) do
            if category.id and not self:mangaBelongsToCategory(manga, category) then
                manga.categories[#manga.categories + 1] = category
            end
        end
    end
    for _, entry in pairs(self.settings:loadReaderReturnContexts()) do add(entry) end
    for _, entry in pairs(self.settings:loadChapterLedger()) do add(entry) end
    local listing = { manga = {}, categories = {} }
    for _, manga in pairs(by_id) do
        manga.title = manga.title or (manga.local_manga_path and manga.local_manga_path:match("[^/\\]+$"))
            or I18n.f("Manga %1", manga.id)
        listing.manga[#listing.manga + 1] = manga
        for _, category in ipairs(manga.categories) do
            if not categories[tostring(category.id)] then categories[tostring(category.id)] = category end
        end
    end
    table.sort(listing.manga, function(a, b)
        if a.title == b.title then return tostring(a.id) < tostring(b.id) end
        return a.title < b.title
    end)
    for _, category in pairs(categories) do listing.categories[#listing.categories + 1] = category end
    table.sort(listing.categories, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return listing
end

function SuwayomiClient:showLibrary()
    if self.plugin.suwayomi_host_retired then return end
    self:cancelLibraryNetworkRequests()
    if self.plugin.getNavigation then self.plugin:getNavigation():closeAll() end
    local credentials = self.settings:load()
    local scope = self.settings:normalizeEndpointScope(credentials.server_url)
    local listing = self.settings:loadLibraryCache(credentials)
    local session = {
        credentials = credentials,
        scope = scope,
        listing = listing or reconstructLibrary(self, scope),
        saved = listing ~= nil,
        saved_for_restart = listing ~= nil,
        sort_mode = "latest_arrivals",
    }
    self.library_session = session
    renderLibrary(self, session)
    if session.scope then
        if self.plugin.schedulePendingReadSync then self.plugin:schedulePendingReadSync(credentials) end
        refreshLibrary(self, session, true)
    end
    return session.category_menu or session.manga_menu
end
end

return M
