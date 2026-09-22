-- Boundary: library flow.
--
-- Responsibility: render saved Library information and replace it after a complete server load.
-- Owned state: one Library session and its cancellable request on the client.
-- Dependencies: checked settings, normal Library widgets, and the request worker.
-- External data: only complete scoped snapshots are persisted; unassociated reconstruction permits local reading only.

local M = {}
local I18n = require("suwayomi/i18n")

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
    session.request = nil
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
    local ok, active = pcall(self:getNetworkRequestJob().start, {
        owner = self.plugin,
        credentials = session.credentials,
        request = { action = "fetch_library_snapshot" },
        result_prefix = "library_request",
        timeout_seconds = self:getNetworkRequestTimeoutSeconds(),
        on_cancel = function()
            if session.request == token then session.request = nil end
        end,
        on_finish = function(result)
            if not live(self, session) or session.request ~= token then return end
            session.request, session.active = nil, nil
            if not result or not result.ok then
                if not quiet then notify(self, I18n.t("Could not refresh Library. Showing saved information.")) end
                return
            end
            session.listing = result
            session.saved = true
            local saved = self.settings:saveLibraryCache(session.credentials, result)
            renderLibrary(self, session)
            if not saved then
                notify(self, I18n.t("Library loaded, but could not be saved for next time."))
            end
        end,
    })
    if not ok or not active then
        if session.request == token then
            session.request = nil
            if not quiet then notify(self, I18n.t("Could not refresh Library. Showing saved information.")) end
        end
        return false
    end
    if session.request == token then session.active = active end
    return true
end

local function menuOptions(self, session)
    local options = self:getTitleBarMenuOptions({
        title = I18n.t("Suwayomi Library"),
        actions = { { id = "refresh", text = I18n.t("Refresh") } },
        captureActionGuard = function() return function() return live(self, session) end end,
        onSelect = function(action)
            if action.id == "refresh" then return refreshLibrary(self, session) end
        end,
    }) or {}
    options.thumbnail_credentials = session.credentials
    return options
end

local function renderManga(self, session)
    local rows = self:filterLibraryMangaByCategory(session.listing.manga, session.category)
    local options = menuOptions(self, session)
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
