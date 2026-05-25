-- Boundary: SourceCatalog.
--
-- Responsibility: Owns Browse source filtering, source cache IO, and source list rendering.
-- Owned state: Reuses plugin-bound controller state such as current_sources_menu.
-- Dependencies: KOReader UI helpers, Suwayomi settings/debug modules, and the plugin i18n facade are resolved when methods run so tests can swap runtime stubs.
-- External data: API responses, cached source tables, and settings values are treated as untrusted until filtered locally.

local SourceCatalog = {}
local Methods = {}
local DEFAULT_SOURCE_LANGUAGE = "en"
local LOCAL_SOURCE_LANGUAGE = "localsourcelang"
local SourceLanguages = require("suwayomi/source_languages")

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

local function getI18n()
    return require("suwayomi/i18n")
end

local function tr(text)
    return getI18n().t(text)
end

local function fmt(text, ...)
    return getI18n().f(text, ...)
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
    lang = normalizeLanguage(lang)
    if not lang then
        return ""
    end
    return SourceLanguages.formatLabel(lang)
end

local function sortLanguages(left, right)
    return SourceLanguages.compare(left, right)
end

local function isSourceTable(source)
    return type(source) == "table"
end

local function copyDefaultSourceLanguageFilter()
    return {
        [DEFAULT_SOURCE_LANGUAGE] = true,
    }
end

function Methods:getSourceLanguageFilterSet()
    if type(self.current_source_language_filters) == "table" then
        return self.current_source_language_filters
    end

    local selected = copyDefaultSourceLanguageFilter()
    local legacy_filter = normalizeLanguage(self.current_source_language_filter)
    if legacy_filter then
        selected = {
            [legacy_filter] = true,
        }
    end
    self.current_source_language_filters = selected
    self.current_source_language_filter = nil
    return self.current_source_language_filters
end

function Methods:getSourceLanguageFilter()
    for lang, selected in pairs(self:getSourceLanguageFilterSet()) do
        if selected then
            return lang
        end
    end
    return DEFAULT_SOURCE_LANGUAGE
end


function Methods:getSourceLanguageFilterSummary()
    local selected_labels = {}
    for lang, selected in pairs(self:getSourceLanguageFilterSet()) do
        if selected then
            table.insert(selected_labels, formatLanguageLabel(lang))
        end
    end
    table.sort(selected_labels, function(left, right)
        return left:lower() < right:lower()
    end)
    return #selected_labels > 0 and table.concat(selected_labels, ", ") or tr("none")
end


function Methods:getSourceLanguageFilterChoices(sources)
    local seen = {}
    local languages = {}
    local selected_languages = self:getSourceLanguageFilterSet()
    for _ , source in ipairs(sources or {}) do
        if isSourceTable(source) then
            local lang = normalizeLanguage(source.lang)
            if lang and not seen[lang] then
                seen[lang] = true
                table.insert(languages, lang)
            end
        end
    end
    table.sort(languages, sortLanguages)

    local actions = {}
    for _ , lang in ipairs(languages) do
        table.insert(actions, {
            code = lang,
            label = formatLanguageLabel(lang),
            enabled = selected_languages[lang] == true,
        })
    end
    return actions
end


function Methods:sourceMatchesBrowseSettings(source, selected_languages, browse_settings)
    if not isSourceTable(source) then
        return false
    end

    local lang = normalizeLanguage(source.lang)
    if lang and not selected_languages[lang] then
        return false
    end
    if source.is_nsfw == true and not browse_settings.show_nsfw_sources then
        return false
    end
    return true
end


function Methods:filterSourcesByLanguage(sources)
    local selected_languages = self:getSourceLanguageFilterSet()
    local browse_settings = self:loadBrowseSettings()
    local filtered = {}

    for _ , source in ipairs(sources or {}) do
        if self:sourceMatchesBrowseSettings(source, selected_languages, browse_settings) then
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
    local lang = normalizeLanguage(language) or DEFAULT_SOURCE_LANGUAGE
    self.current_source_language_filters = {
        [lang] = true,
    }
    self:refreshSourceLanguageFilter()
    return true
end


function Methods:toggleSourceLanguageFilter(language, enabled)
    local lang = normalizeLanguage(language)
    if not lang then
        return false
    end
    local selected_languages = self:getSourceLanguageFilterSet()
    selected_languages[lang] = enabled == true or nil
    self:refreshSourceLanguageFilter()
    return true
end


function Methods:showSourceLanguageFilterActions(choices, menu_context)
    local SuwayomiUI = getUI()
    if not SuwayomiUI.showLanguageMenu then
        return false
    end
    local language_menu
    local function refreshLanguageMenu()
        if SuwayomiUI.updateLanguageMenu then
            SuwayomiUI.updateLanguageMenu(language_menu, {
                title = tr("Source languages"),
                show_done = false,
                languages = self:getSourceLanguageFilterChoices(self.current_source_list_sources),
                anchor = menu_context and menu_context.anchor,
            }, function(code, enabled)
                self:toggleSourceLanguageFilter(code, enabled)
                refreshLanguageMenu()
            end)
        end
    end
    language_menu = SuwayomiUI.showLanguageMenu({
        title = tr("Source languages"),
        show_done = false,
        languages = choices or {},
        anchor = menu_context and menu_context.anchor,
        onToggle = function(code, enabled)
            self:toggleSourceLanguageFilter(code, enabled)
            refreshLanguageMenu()
        end,
    })
    return true
end


function Methods:loadSourceCache(credentials)
    local SuwayomiSettings = getSettings()
    if not SuwayomiSettings.loadSourceCache then
        return nil
    end
    return SuwayomiSettings:loadSourceCache(credentials)
end


function Methods:saveSourceCache(credentials, sources)
    local SuwayomiSettings = getSettings()
    if not SuwayomiSettings.saveSourceCache then
        return nil
    end
    return SuwayomiSettings:saveSourceCache(credentials, sources or {}, os.time())
end


function Methods:showSourceList(sources, options)
    local SuwayomiUI = getUI()
    options = options or {}
    local all_sources = options.all_sources or sources
    local source_language_choices = self:getSourceLanguageFilterChoices(all_sources)
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
            { id = "global_search", text = tr("Global search") },
        }
        if #source_language_choices > 0 then
            table.insert(actions, {
                id = "source_language_filter",
                text = fmt("Source languages: %1", self:getSourceLanguageFilterSummary()),
                submenu = true,
            })
        end
        table.insert(actions, {
            id = "extensions",
            text = tr("Extensions"),
            submenu = true,
        })
        if self.getTitleBarMenuOptions then
            menu_options = self:getTitleBarMenuOptions({
                title = tr("Suwayomi Sources"),
                actions = actions,
                onSelect = function(action, _, menu_context)
                    if action and action.id == "global_search" then
                        return showGlobalSearch()
                    end
                    if action and action.id == "extensions" then
                        return self:showExtensions()
                    end
                    if action and action.id == "source_language_filter" then
                        return self:showSourceLanguageFilterActions(source_language_choices, menu_context)
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
            self:showMessage(tr("Could not load Suwayomi sources."))
        end
        return
    end
    if not result.ok then
        if not options.silent then
            self:showMessage(result.error or tr("Could not load Suwayomi sources."))
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
    if #filtered_sources == 0 and #self:getSourceLanguageFilterChoices(result.sources) == 0 then
        if not options.silent then
            self:showMessage(tr("No Suwayomi sources match the selected languages."))
        end
        return
    end
    if options.silent and not self.current_sources_menu then
        return true
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
    if #filtered_sources == 0 and #self:getSourceLanguageFilterChoices(cache and cache.sources or {}) == 0 then
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
