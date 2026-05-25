-- Boundary: library flow.
--
-- Responsibility: load library pages, apply category filtering, and route selected library manga actions.
-- Owned state: installed methods only; runtime state remains on SuwayomiClient instances.
-- Dependencies: SuwayomiClient core helpers and injected runtime services.
-- External data: validated by the moved methods before UI rendering or worker use.

local M = {}
local I18n = require("suwayomi/i18n")

function M.install(SuwayomiClient)
function SuwayomiClient:mangaBelongsToCategory(manga, category)
    if not category or not category.id then
        return true
    end
    for _index, candidate in ipairs(manga.categories or {}) do
        if tostring(candidate.id) == tostring(category.id) then
            return true
        end
    end
    return false
end

function SuwayomiClient:filterLibraryMangaByCategory(manga_list, category)
    if not category or not category.id then
        return manga_list or {}
    end

    local filtered = {}
    for _index, manga in ipairs(manga_list or {}) do
        if self:mangaBelongsToCategory(manga, category) then
            table.insert(filtered, manga)
        end
    end
    return filtered
end

function SuwayomiClient:buildLibraryCategoryChoices(categories)
    local choices = {
        {
            id = nil,
            name = I18n.t("All manga"),
        },
    }
    for _index, category in ipairs(categories or {}) do
        table.insert(choices, category)
    end
    return choices
end

local function libraryTimeoutMessage()
    return I18n.t("Library loading timed out. Check your connection, then open Library again.")
end

function SuwayomiClient:startLibraryNetworkRequest(credentials, request, loading_message, on_finish)
    local active_requests = self.active_library_network_requests or {}
    self.active_library_network_requests = active_requests
    local slot_key = tostring(request and request.action or "library_request")
    local previous = active_requests[slot_key]
    local request_job = self:getNetworkRequestJob()
    if previous and previous.active and request_job.cancel then
        request_job.cancel(previous.active)
    end

    local request_token = {}
    active_requests[slot_key] = request_token
    local ok, active, start_err = pcall(request_job.start, {
        owner = self.plugin,
        credentials = credentials,
        request = request,
        loading_message = loading_message,
        result_prefix = "library_request",
        timeout_seconds = self:getNetworkRequestTimeoutSeconds(),
        timeout_message = libraryTimeoutMessage(),
        on_cancel = function()
            if active_requests[slot_key] == request_token then
                active_requests[slot_key] = nil
            end
        end,
        on_finish = function(result)
            if active_requests[slot_key] ~= request_token then
                return
            end
            active_requests[slot_key] = nil
            if on_finish then
                on_finish(result)
            end
        end,
    })
    if not ok then
        start_err = active
        active = nil
    end
    if not active then
        if active_requests[slot_key] == request_token then
            active_requests[slot_key] = nil
        end
        return false, start_err
    end
    if active_requests[slot_key] == request_token then
        request_token.active = active
    end
    return true
end

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

function SuwayomiClient:showLibraryMangaResult(category, credentials, result)
    if not result then
        self.plugin:showMessage(I18n.t("Could not load Suwayomi library."))
        return
    end
    if not result.ok then
        self.plugin:showMessage(result.error or I18n.t("Could not load Suwayomi library."))
        return
    end

    local manga = self:filterLibraryMangaByCategory(result.manga or {}, category)
    self:log({
        operation = "showLibrary",
        event = "library_manga_loaded",
        category_id = category and category.id,
        manga_count = #manga,
        total_count = result.total_count,
    })

    if #manga == 0 then
        if category and category.id then
            self.plugin:showMessage(I18n.t("No manga in this library category."))
        else
            self.plugin:showMessage(I18n.t("Your Suwayomi library is empty."))
        end
        return
    end

    local library_manga = manga
    local menu_options = self:getTitleBarMenuOptions({
        title = I18n.t("Suwayomi Library"),
    }) or {}
    menu_options.thumbnail_credentials = credentials
    local library_menu
    local pending_library_menu_refresh = false
    local function refreshLibraryMangaMenu()
        for index = #library_manga, 1, -1 do
            if type(library_manga[index]) == "table" and library_manga[index].in_library == false then
                table.remove(library_manga, index)
            end
        end
        if not library_menu then
            pending_library_menu_refresh = true
            return
        end
        if self.ui.updateLibraryMangaMenu then
            self.ui.updateLibraryMangaMenu(library_menu, library_manga, function(selected_manga)
                if self.plugin.showMangaActions then
                    self.plugin:showMangaActions(selected_manga, {
                        onMangaUpdated = refreshLibraryMangaMenu,
                    })
                else
                    self.plugin:showChaptersForManga(selected_manga)
                end
            end, menu_options)
        end
    end

    library_menu = self.ui.showLibraryMangaMenu(library_manga, function(selected_manga)
        if self.plugin.showMangaActions then
            self.plugin:showMangaActions(selected_manga, {
                onMangaUpdated = refreshLibraryMangaMenu,
            })
        else
            self.plugin:showChaptersForManga(selected_manga)
        end
    end, menu_options)
    self:trackScreen("library", library_menu)
    if pending_library_menu_refresh then
        refreshLibraryMangaMenu()
    end
end

function SuwayomiClient:showLibraryManga(category, credentials)
    credentials = credentials or self.settings:load()
    local started, err = self:startLibraryNetworkRequest(credentials, {
        action = "fetch_library_manga_pages",
    }, I18n.t("Loading library..."), function(result)
        self:showLibraryMangaResult(category, credentials, result)
    end)
    if not started then
        self.plugin:showMessage(I18n.f("Could not start library loading: %1", err or I18n.t("unknown error")))
    end
    return started
end

function SuwayomiClient:showLibraryCategoriesResult(credentials, result)
    if not result then
        self.plugin:showMessage(I18n.t("Could not load Suwayomi library."))
        return
    end
    if not result.ok then
        self.plugin:showMessage(result.error or I18n.t("Could not load library categories."))
        return
    end

    local categories = result.categories or {}
    local picker_behavior = self.settings.loadLibraryCategoryPickerBehavior
        and self.settings:loadLibraryCategoryPickerBehavior()
        or "automatic"
    local should_show_category_picker = picker_behavior == "always"
        or (picker_behavior == "automatic" and #categories > 1)

    if should_show_category_picker and #categories > 0 then
        local category_menu = self.ui.showLibraryCategoryMenu(self:buildLibraryCategoryChoices(categories), function(category)
            self:showLibraryManga(category, credentials)
        end, self:getTitleBarMenuOptions({
            title = I18n.t("Suwayomi Library"),
        }))
        self:trackScreen("library-categories", category_menu)
        return
    end

    self:showLibraryManga(nil, credentials)
end

function SuwayomiClient:showLibrary()
    return self:time("showLibrary", {}, function()
        local credentials = self.settings:load()
        if not credentials.server_url or credentials.server_url == "" then
            self.plugin:showMessage(I18n.t("Set up your Suwayomi server login first."))
            if self.plugin.showOnboardingSetup then
                self.plugin:showOnboardingSetup({ first_run = true })
            end
            return
        end
        if self.plugin.schedulePendingReadSync then
            self.plugin:schedulePendingReadSync(credentials)
        end

        local started, err = self:startLibraryNetworkRequest(credentials, {
            action = "fetch_library_categories",
        }, I18n.t("Loading categories..."), function(result)
            self:showLibraryCategoriesResult(credentials, result)
        end)
        if not started then
            self.plugin:showMessage(I18n.f("Could not start library loading: %1", err or I18n.t("unknown error")))
        end
        return started
    end)
end
end

return M
