-- Boundary: SourceCatalog.
--
-- Responsibility: Owns Browse source filtering, source cache IO, and source list rendering.
-- Owned state: Reuses plugin-bound controller state such as current_sources_menu.
-- Dependencies: KOReader UI helpers, Suwayomi settings/debug modules, and gettext are resolved when methods run so tests can swap runtime stubs.
-- External data: API responses, cached source tables, and settings values are treated as untrusted until filtered locally.

local SourceCatalog = {}
local Methods = {}
local DEFAULT_SOURCE_LANGUAGE = "en"
local LOCAL_SOURCE_LANGUAGE = "localsourcelang"

local function getSettings()
    return require("suwayomi/settings")
end

local function getUI()
    return require("suwayomi/ui")
end

local function getDebug()
    return require("suwayomi/debug")
end

local function getUIManager()
    return require("ui/uimanager")
end

local function _(text)
    return require("gettext")(text)
end

local function nextTick(callback)
    local UIManager = getUIManager()
    if UIManager and UIManager.nextTick then
        return UIManager:nextTick(callback)
    end
    return callback()
end

local function normalizeLanguage(lang)
    if lang == nil then
        return nil
    end
    lang = tostring(lang)
    if lang == "" or lang == LOCAL_SOURCE_LANGUAGE then
        return nil
    end
    return lang
end

local function formatLanguageLabel(lang)
    return string.upper(tostring(lang or ""))
end

local function sortLanguages(left, right)
    return tostring(left):lower() < tostring(right):lower()
end

function Methods:getSourceLanguageFilter()
    return normalizeLanguage(self.current_source_language_filter) or DEFAULT_SOURCE_LANGUAGE
end


function Methods:getSourceLanguageFilterActions(sources)
    local seen = {}
    local languages = {}
    for _, source in ipairs(sources or {}) do
        local lang = normalizeLanguage(source and source.lang)
        if lang and not seen[lang] then
            seen[lang] = true
            table.insert(languages, lang)
        end
    end
    table.sort(languages, sortLanguages)

    local actions = {}
    for _, lang in ipairs(languages) do
        table.insert(actions, {
            id = "source_language_filter_value",
            text = formatLanguageLabel(lang),
            language = lang,
        })
    end
    return actions
end

function Methods:sourceMatchesBrowseSettings(source, selected_language, browse_settings)
    local lang = normalizeLanguage(source and source.lang)
    if lang and lang ~= selected_language then
        return false
    end
    if source.is_nsfw == true and not browse_settings.show_nsfw_sources then
        return false
    end
    return true
end


function Methods:filterSourcesByLanguage(sources)
    local selected_language = self:getSourceLanguageFilter()
    local browse_settings = self:loadBrowseSettings()
    local filtered = {}

    for _, source in ipairs(sources or {}) do
        if self:sourceMatchesBrowseSettings(source, selected_language, browse_settings) then
            table.insert(filtered, source)
        end
    end

    return filtered
end


function Methods:refreshSourceLanguageFilter()
    if not self.current_source_list_sources then
        return false
    end
    return self:showSourceList(self:filterSourcesByLanguage(self.current_source_list_sources), {
        credentials = self.current_source_list_credentials,
        all_sources = self.current_source_list_sources,
    })
end


function Methods:setSourceLanguageFilter(language)
    self.current_source_language_filter = normalizeLanguage(language) or DEFAULT_SOURCE_LANGUAGE
    self:refreshSourceLanguageFilter()
    return true
end


function Methods:showSourceLanguageFilterActions(actions, menu_context)
    local SuwayomiUI = getUI()
    if not SuwayomiUI.showChapterActionsMenu then
        return false
    end
    SuwayomiUI.showChapterActionsMenu({
        title = _("Source language"),
        actions = actions or {},
        anchor = menu_context and menu_context.anchor,
    }, function(action)
        if action and action.language then
            self:setSourceLanguageFilter(action.language)
        end
    end)
    return true
end


function Methods:loadSourceCache(credentials)
    local SuwayomiSettings = getSettings()
    if not SuwayomiSettings.loadSourceCache then
        return nil
    end
    return SuwayomiSettings:loadSourceCache(credentials and credentials.server_url or "")
end


function Methods:saveSourceCache(credentials, sources)
    local SuwayomiSettings = getSettings()
    if not SuwayomiSettings.saveSourceCache then
        return nil
    end
    return SuwayomiSettings:saveSourceCache(credentials and credentials.server_url or "", sources or {}, os.time())
end


function Methods:showSourceList(sources, options)
    local SuwayomiUI = getUI()
    options = options or {}
    local all_sources = options.all_sources or sources
    local source_language_actions = self:getSourceLanguageFilterActions(all_sources)
    local menu
    local function selectSource(source)
        return nextTick(function()
            return self:showMangaForSource(source)
        end)
    end
    local function buildSourceMenuOptions()
        local menu_options = {}
        local function showGlobalSearch()
            return self:getClient():showGlobalSearch(sources)
        end
        local actions = {
            { id = "global_search", text = _("Global search") },
        }
        if #source_language_actions > 0 then
            table.insert(actions, {
                id = "source_language_filter",
                text = _("Source language: ") .. formatLanguageLabel(self:getSourceLanguageFilter()),
                submenu = true,
            })
        end
        if self.getTitleBarMenuOptions then
            menu_options = self:getTitleBarMenuOptions({
                title = _("Suwayomi Sources"),
                actions = actions,
                onSelect = function(action, _, menu_context)
                    if action and action.id == "global_search" then
                        return showGlobalSearch()
                    end
                    if action and action.id == "source_language_filter" then
                        return self:showSourceLanguageFilterActions(source_language_actions, menu_context)
                    end
                end,
            }) or {}
        end
        menu_options.close_callback = function()
            if self.current_sources_menu == menu then
                self.current_sources_menu = nil
            end
        end
        menu_options.thumbnail_credentials = options.credentials
        return menu_options
    end

    self.current_source_list_sources = all_sources
    self.current_source_list_credentials = options.credentials

    if not options.force_new and self.current_sources_menu and SuwayomiUI.updateSourcesMenu then
        SuwayomiUI.updateSourcesMenu(self.current_sources_menu, sources, function(source)
            return selectSource(source)
        end, buildSourceMenuOptions())
        return self.current_sources_menu
    end

    menu = SuwayomiUI.showSourcesMenu(sources, function(source)
        return selectSource(source)
    end, buildSourceMenuOptions())
    self.current_sources_menu = menu
    if self.trackSuwayomiScreen then
        self:trackSuwayomiScreen("browse-sources", menu)
    end
    return self.current_sources_menu
end


function Methods:showFetchedSources(result, options)
    local SuwayomiDebug = getDebug()
    options = options or {}
    if not result then
        if not options.silent then
            self:showMessage(_("Could not load Suwayomi sources."))
        end
        return
    end
    if not result.ok then
        if not options.silent then
            self:showMessage(_(result.error or "Could not load Suwayomi sources."))
        end
        return
    end

    self:saveSourceCache(options.credentials, result.sources)
    local filtered_sources = self:filterSourcesByLanguage(result.sources)
    SuwayomiDebug.log({
        operation = "browseSuwayomi",
        event = options.refresh and "sources_refreshed" or "sources_loaded",
        source_count = #(result.sources or {}),
        filtered_source_count = #filtered_sources,
    })
    if #filtered_sources == 0 and #self:getSourceLanguageFilterActions(result.sources) == 0 then
        if not options.silent then
            self:showMessage(_("No Suwayomi sources match the selected languages."))
        end
        return
    end

    self:showSourceList(filtered_sources, {
        credentials = options.credentials,
        all_sources = result.sources,
    })
end


function Methods:showCachedSources(cache, options)
    local SuwayomiDebug = getDebug()
    options = options or {}
    local filtered_sources = self:filterSourcesByLanguage(cache and cache.sources or {})
    SuwayomiDebug.log({
        operation = "browseSuwayomi",
        event = "source_cache_hit",
        source_count = #(cache and cache.sources or {}),
        filtered_source_count = #filtered_sources,
        cache_age_seconds = math.max(0, os.time() - (tonumber(cache and cache.updated_at) or os.time())),
    })
    if #filtered_sources == 0 and #self:getSourceLanguageFilterActions(cache and cache.sources or {}) == 0 then
        return false
    end

    self:showSourceList(filtered_sources, {
        credentials = options.credentials,
        force_new = true,
        all_sources = cache and cache.sources or {},
    })
    return true
end


function Methods:showMangaForSource(source)
    return self:getClient():showMangaForSource(source)
end


SourceCatalog.methods = Methods

return SourceCatalog
