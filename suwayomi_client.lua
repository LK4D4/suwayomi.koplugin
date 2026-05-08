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

function SuwayomiClient:showMangaForSource(source)
    return self:time("showMangaForSource", {
        source_id = source and source.id,
    }, function()
        local credentials = self.settings:load()
        local result = self.plugin:withLoadingMessage("manga", self:translate("Loading manga..."), function()
            return self.api.fetchMangaForSource(credentials, {
                source_id = source.id,
                page = 1,
                type = "POPULAR",
            })
        end)
        if not result then
            return
        end
        if not result.ok then
            self.plugin:showMessage(self:translate(result.error))
            return
        end

        self:log({
            operation = "showMangaForSource",
            event = "manga_loaded",
            source_id = source and source.id,
            manga_count = #(result.manga or {}),
        })
        if not result.manga or #result.manga == 0 then
            self.plugin:showMessage(self:translate("This source has no manga."))
            return
        end

        self.ui.showMangaMenu(result.manga, function(manga)
            self:attachSourceToManga(manga, source)
            if self.plugin.showMangaActions then
                self.plugin:showMangaActions(manga)
            else
                self.plugin:showChaptersForManga(manga)
            end
        end, self:getHomeMenuOptions())
    end)
end

return SuwayomiClient
