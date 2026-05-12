-- Boundary: library flow.
--
-- Responsibility: load library pages, apply category filtering, and route selected library manga actions.
-- Owned state: installed methods only; runtime state remains on SuwayomiClient instances.
-- Dependencies: SuwayomiClient core helpers and injected runtime services.
-- External data: validated by the moved methods before UI rendering or worker use.

local M = {}

function M.install(SuwayomiClient)
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

    local library_manga = manga
    local menu_options = self:getTitleBarMenuOptions({
        title = self:translate("Suwayomi Library"),
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
            local category_menu = self.ui.showLibraryCategoryMenu(self:buildLibraryCategoryChoices(categories), function(category)
                self:showLibraryManga(category, credentials)
            end, self:getTitleBarMenuOptions({
                title = self:translate("Suwayomi Library"),
            }))
            self:trackScreen("library-categories", category_menu)
            return
        end

        self:showLibraryManga(nil, credentials)
    end)
end
end

return M
