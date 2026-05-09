local SuwayomiClient = {}
SuwayomiClient.__index = SuwayomiClient

function SuwayomiClient:new(options)
    options = options or {}
    return setmetatable({
        api = options.api,
        ui = options.ui,
        settings = options.settings,
        debug = options.debug,
        plugin = options.plugin,
        gettext = options.gettext or function(text) return text end,
    }, self)
end

function SuwayomiClient:translate(text)
    return self.gettext(text)
end

function SuwayomiClient:time(operation, context, callback)
    if self.debug and self.debug.time then
        return self.debug.time(operation, context, callback)
    end
    return callback()
end

function SuwayomiClient:log(event)
    if self.debug and self.debug.log then
        self.debug.log(event)
    end
end

function SuwayomiClient:getHomeMenuOptions()
    if self.plugin and self.plugin.getHomeMenuOptions then
        return self.plugin:getHomeMenuOptions()
    end
    return nil
end

function SuwayomiClient:attachSourceToManga(manga, source)
    if type(manga) ~= "table" or type(source) ~= "table" then
        return manga
    end

    manga.source = manga.source or {}
    manga.source.id = manga.source.id or source.id
    manga.source.displayName = manga.source.displayName or source.displayName or source.display_name
    manga.source.name = manga.source.name or source.raw_name or source.name
    manga.source.lang = manga.source.lang or source.lang
    return manga
end

function SuwayomiClient:formatLibraryMangaRow(manga)
    local parts = {
        manga.title or tostring(manga.id),
    }
    local details = {}
    if manga.unread_count ~= nil then
        table.insert(details, tostring(manga.unread_count) .. " unread")
    end
    local source = manga.source
    local source_name = source and (source.displayName or source.name or source.lang)
    if source_name and source_name ~= "" then
        table.insert(details, source_name)
    end
    if #details > 0 then
        table.insert(parts, "(" .. table.concat(details, " / ") .. ")")
    end
    return table.concat(parts, " ")
end

function SuwayomiClient:withLibraryMenuText(manga_list)
    for _, manga in ipairs(manga_list or {}) do
        manga.menu_text = self:formatLibraryMangaRow(manga)
    end
    return manga_list
end

function SuwayomiClient:mangaBelongsToCategory(manga, category)
    if not category or not category.id then
        return true
    end
    for _, candidate in ipairs(manga.categories or {}) do
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
    for _, manga in ipairs(manga_list or {}) do
        if self:mangaBelongsToCategory(manga, category) then
            table.insert(filtered, manga)
        end
    end
    return filtered
end

function SuwayomiClient:loadBrowseSettings()
    if self.settings and self.settings.loadBrowseSettings then
        return self.settings:loadBrowseSettings()
    end
    return {
        show_nsfw_sources = false,
        hide_in_library_results = false,
    }
end

function SuwayomiClient:filterBrowseManga(manga_list)
    local browse_settings = self:loadBrowseSettings()
    if not browse_settings.hide_in_library_results then
        return manga_list or {}
    end

    local filtered = {}
    for _, manga in ipairs(manga_list or {}) do
        if manga.in_library ~= true then
            table.insert(filtered, manga)
        end
    end
    return filtered
end

function SuwayomiClient:getSourceDisplayName(source)
    if type(source) ~= "table" then
        return self:translate("Source")
    end
    return source.display_name
        or source.displayName
        or source.name
        or source.raw_name
        or tostring(source.id)
end

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
        .. " - "
        .. self:translate("Page")
        .. " "
        .. tostring(options.page or 1)
end

function SuwayomiClient:buildBrowseResultMenuOptions(source, options, has_next_page)
    local menu_options = {}
    local home_options = self:getHomeMenuOptions() or {}
    for key, value in pairs(home_options) do
        menu_options[key] = value
    end
    menu_options.title = self:buildBrowseResultTitle(source, options)

    if (options.page or 1) > 1 then
        menu_options.on_previous_page = function()
            return self:showMangaForSource(source, {
                type = options.type,
                query = options.query,
                page = (options.page or 1) - 1,
                skip_mode_menu = true,
            })
        end
    end
    if has_next_page == true then
        menu_options.on_next_page = function()
            return self:showMangaForSource(source, {
                type = options.type,
                query = options.query,
                page = (options.page or 1) + 1,
                skip_mode_menu = true,
            })
        end
    end

    return menu_options
end

function SuwayomiClient:isLocalSource(source)
    return source and source.lang == "localsourcelang"
end

local function trim(text)
    return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function SuwayomiClient:isLatestUnsupportedError(error_text)
    local message = tostring(error_text or ""):lower()
    return message:match("unsupported%s+latest") ~= nil
        or message:match("latest%s+not%s+supported") ~= nil
        or message:match("does%s+not%s+support%s+latest") ~= nil
end

function SuwayomiClient:buildLibraryCategoryChoices(categories)
    local choices = {
        {
            id = nil,
            name = self:translate("All manga"),
        },
    }
    for _, category in ipairs(categories or {}) do
        table.insert(choices, category)
    end
    return choices
end

function SuwayomiClient:fetchLibraryMangaPages(credentials)
    local page_size = 100
    local offset = 0
    local all_manga = {}
    local total_count

    while true do
        local result = self.api.fetchLibraryManga(credentials, {
            first = page_size,
            offset = offset,
        })
        if not result.ok then
            return result
        end

        local page_manga = result.manga or {}
        for _, manga in ipairs(page_manga) do
            table.insert(all_manga, manga)
        end
        total_count = tonumber(result.total_count) or #all_manga

        if #page_manga == 0 or #page_manga < page_size or #all_manga >= total_count then
            break
        end
        offset = offset + page_size
    end

    return {
        ok = true,
        manga = all_manga,
        total_count = total_count,
    }
end

function SuwayomiClient:showLibraryManga(category, credentials)
    credentials = credentials or self.settings:load()
    local result = self.plugin:withLoadingMessage("library-manga", self:translate("Loading library manga..."), function()
        return self:fetchLibraryMangaPages(credentials)
    end)
    if not result then
        return
    end
    if not result.ok then
        self.plugin:showMessage(self:translate(result.error))
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
            self.plugin:showMessage(self:translate("This category has no manga."))
        else
            self.plugin:showMessage(self:translate("Your Suwayomi library is empty."))
        end
        return
    end

    local library_manga = self:withLibraryMenuText(manga)
    local library_menu
    local pending_library_menu_refresh = false
    local function refreshLibraryMangaMenu()
        for index = #library_manga, 1, -1 do
            if type(library_manga[index]) == "table" and library_manga[index].in_library == false then
                table.remove(library_manga, index)
            end
        end
        self:withLibraryMenuText(library_manga)
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
            end, self:getHomeMenuOptions())
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
    end, self:getHomeMenuOptions())
    if pending_library_menu_refresh then
        pending_library_menu_refresh = false
        refreshLibraryMangaMenu()
    end
end

function SuwayomiClient:showLibrary()
    return self:time("showLibrary", {}, function()
        local credentials = self.settings:load()
        if not credentials.server_url or credentials.server_url == "" then
            self.plugin:showMessage(self:translate("Set up your Suwayomi server login first."))
            return
        end
        if self.plugin.schedulePendingReadSync then
            self.plugin:schedulePendingReadSync(credentials)
        end

        local result = self.plugin:withLoadingMessage("library-categories", self:translate("Loading library..."), function()
            return self.api.fetchCategories(credentials)
        end)
        if not result then
            return
        end
        if not result.ok then
            self.plugin:showMessage(self:translate(result.error))
            return
        end

        local categories = result.categories or {}
        local picker_behavior = self.settings.loadLibraryCategoryPickerBehavior
            and self.settings:loadLibraryCategoryPickerBehavior()
            or "automatic"
        local should_show_category_picker = picker_behavior == "always"
            or (picker_behavior == "automatic" and #categories > 1)

        if should_show_category_picker and #categories > 0 then
            self.ui.showLibraryCategoryMenu(self:buildLibraryCategoryChoices(categories), function(category)
                self:showLibraryManga(category, credentials)
            end, self:getHomeMenuOptions())
            return
        end

        self:showLibraryManga(nil, credentials)
    end)
end

function SuwayomiClient:showSourceSearchPrompt(source)
    if not self.ui.showSourceSearchPrompt then
        return
    end

    return self.ui.showSourceSearchPrompt(source, function(query)
        local search_query = trim(query)
        if search_query == "" then
            self.plugin:showMessage(self:translate("Enter a search query."))
            return
        end
        self:showMangaForSource(source, {
            type = "SEARCH",
            query = search_query,
            skip_mode_menu = true,
        })
    end)
end

function SuwayomiClient:searchSourceForSummary(credentials, source, query)
    local ok, result = pcall(function()
        return self.api.fetchMangaForSource(credentials, {
            source_id = source.id,
            page = 1,
            type = "SEARCH",
            query = query,
        })
    end)
    if not ok then
        return {
            source = source,
            status = "error",
            error = tostring(result),
        }
    end
    if not result or not result.ok then
        return {
            source = source,
            status = "error",
            error = result and result.error or self:translate("Could not load manga."),
        }
    end

    local manga = self:filterBrowseManga(result.manga or {})
    if #manga == 0 then
        return {
            source = source,
            status = result.has_next_page and "pageable_empty" or "empty",
            manga = manga,
            has_next_page = result.has_next_page,
            query = query,
        }
    end
    return {
        source = source,
        status = "ok",
        first_match = manga[1],
        manga = manga,
        has_next_page = result.has_next_page,
        query = query,
    }
end

function SuwayomiClient:showGlobalSearch(sources)
    if not self.ui.showGlobalSearchPrompt then
        return
    end

    return self.ui.showGlobalSearchPrompt(function(query)
        local search_query = trim(query)
        if search_query == "" then
            self.plugin:showMessage(self:translate("Enter a search query."))
            return
        end

        local credentials = self.settings:load()
        local summaries = self.plugin:withLoadingMessage("global-search", self:translate("Searching sources..."), function()
            local rows = {}
            for _, source in ipairs(sources or {}) do
                table.insert(rows, self:searchSourceForSummary(credentials, source, search_query))
            end
            return rows
        end)
        if not summaries then
            return
        end

        self:log({
            operation = "globalSearch",
            event = "global_search_loaded",
            source_count = #(sources or {}),
            query = search_query,
        })

        if self.ui.showGlobalSearchResultsMenu then
            self.ui.showGlobalSearchResultsMenu(summaries, function(summary)
                if summary and (summary.status == "ok" or summary.status == "pageable_empty") then
                    return self:showMangaForSource(summary.source, {
                        type = "SEARCH",
                        query = summary.query or search_query,
                        page = 1,
                        skip_mode_menu = true,
                    })
                end
            end, self:getHomeMenuOptions())
        end
    end)
end

function SuwayomiClient:showSourceModeMenu(source)
    if self:isLocalSource(source) or not self.ui.showSourceModeMenu then
        return self:showMangaForSource(source, {
            type = "POPULAR",
            skip_mode_menu = true,
        })
    end

    return self.ui.showSourceModeMenu(source, function(mode)
        if mode == "SEARCH" then
            return self:showSourceSearchPrompt(source)
        end
        return self:showMangaForSource(source, {
            type = mode,
            skip_mode_menu = true,
        })
    end, self:getHomeMenuOptions())
end

function SuwayomiClient:showMangaForSource(source, options)
    options = options or {}
    if not options.skip_mode_menu and not self:isLocalSource(source) and self.ui.showSourceModeMenu then
        return self:showSourceModeMenu(source)
    end

    return self:time("showMangaForSource", {
        source_id = source and source.id,
        type = options.type or "POPULAR",
    }, function()
        local credentials = self.settings:load()
        local page = tonumber(options.page) or 1
        local browse_options = {
            type = options.type or "POPULAR",
            query = options.query,
            page = page,
        }
        local result = self.plugin:withLoadingMessage("manga", self:translate("Loading manga..."), function()
            local request_options = {
                source_id = source.id,
                page = page,
                type = browse_options.type,
            }
            if request_options.type == "SEARCH" then
                request_options.query = browse_options.query
            end
            return self.api.fetchMangaForSource(credentials, request_options)
        end)
        if not result then
            return
        end
        if not result.ok then
            if browse_options.type == "LATEST"
                and source
                and source.supports_latest == nil
                and self:isLatestUnsupportedError(result.error)
            then
                self.plugin:showMessage(self:translate("Latest manga is not supported by this source."))
                return
            end
            self.plugin:showMessage(self:translate(result.error))
            return
        end

        local manga_list = result.manga or {}
        local visible_manga = self:filterBrowseManga(manga_list)
        self:log({
            operation = "showMangaForSource",
            event = "manga_loaded",
            source_id = source and source.id,
            type = browse_options.type,
            page = page,
            manga_count = #visible_manga,
        })
        local menu_options = self:buildBrowseResultMenuOptions(source, browse_options, result.has_next_page)
        if #visible_manga == 0
            and not menu_options.on_previous_page
            and not menu_options.on_next_page
        then
            self.plugin:showMessage(self:translate("This source has no manga."))
            return
        end

        local manga_menu
        local pending_manga_menu_refresh = false
        local function refreshMangaMenu()
            visible_manga = self:filterBrowseManga(manga_list)
            if not manga_menu then
                pending_manga_menu_refresh = true
                return
            end
            if self.ui.updateMangaMenu then
                self.ui.updateMangaMenu(manga_menu, visible_manga, function(manga)
                    self:attachSourceToManga(manga, source)
                    if self.plugin.showMangaActions then
                        self.plugin:showMangaActions(manga, {
                            onMangaUpdated = refreshMangaMenu,
                        })
                    else
                        self.plugin:showChaptersForManga(manga)
                    end
                end, menu_options)
            end
        end

        manga_menu = self.ui.showMangaMenu(visible_manga, function(manga)
            self:attachSourceToManga(manga, source)
            if self.plugin.showMangaActions then
                self.plugin:showMangaActions(manga, {
                    onMangaUpdated = refreshMangaMenu,
                })
            else
                self.plugin:showChaptersForManga(manga)
            end
        end, menu_options)
        if pending_manga_menu_refresh then
            pending_manga_menu_refresh = false
            refreshMangaMenu()
        end
    end)
end

return SuwayomiClient
