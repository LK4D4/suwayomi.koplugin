-- Boundary: SourceCatalog.
--
-- Responsibility: Owns Browse source filtering, source cache IO, and source list rendering.
-- Owned state: Reuses plugin-bound controller state such as current_sources_menu.
-- Dependencies: KOReader UI helpers, Suwayomi settings/debug modules, and gettext are resolved when methods run so tests can swap runtime stubs.
-- External data: API responses, cached source tables, and settings values are treated as untrusted until filtered locally.

local SourceCatalog = {}
local Methods = {}

local function getSettings()
    return require("suwayomi/settings")
end

local function getUI()
    return require("suwayomi/ui")
end

local function getDebug()
    return require("suwayomi/debug")
end

local function _(text)
    return require("gettext")(text)
end

function Methods:sourceMatchesBrowseSettings(source, selected_languages, browse_settings)
    if source.lang ~= "localsourcelang" and not selected_languages[source.lang] then
        return false
    end
    if source.is_nsfw == true and not browse_settings.show_nsfw_sources then
        return false
    end
    return true
end


function Methods:filterSourcesByLanguage(sources)
    local SuwayomiSettings = getSettings()
    local selected = self:buildSourceLanguageSet(SuwayomiSettings:loadSourceLanguages())
    local browse_settings = self:loadBrowseSettings()
    local filtered = {}

    for _, source in ipairs(sources or {}) do
        if self:sourceMatchesBrowseSettings(source, selected, browse_settings) then
            table.insert(filtered, source)
        end
    end

    return filtered
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
    local menu
    local function buildSourceMenuOptions()
        local menu_options = self:getHomeMenuOptions() or {}
        menu_options.on_global_search = function()
            return self:getClient():showGlobalSearch(sources)
        end
        menu_options.close_callback = function()
            if self.current_sources_menu == menu then
                self.current_sources_menu = nil
            end
        end
        return menu_options
    end

    if not options.force_new and self.current_sources_menu and SuwayomiUI.updateSourcesMenu then
        SuwayomiUI.updateSourcesMenu(self.current_sources_menu, sources, function(source)
            self:showMangaForSource(source)
        end, buildSourceMenuOptions())
        return self.current_sources_menu
    end

    menu = SuwayomiUI.showSourcesMenu(sources, function(source)
        self:showMangaForSource(source)
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
    if #filtered_sources == 0 then
        if not options.silent then
            self:showMessage(_("No Suwayomi sources match the selected languages."))
        end
        return
    end

    self:showSourceList(filtered_sources)
end


function Methods:showCachedSources(cache)
    local SuwayomiDebug = getDebug()
    local filtered_sources = self:filterSourcesByLanguage(cache and cache.sources or {})
    SuwayomiDebug.log({
        operation = "browseSuwayomi",
        event = "source_cache_hit",
        source_count = #(cache and cache.sources or {}),
        filtered_source_count = #filtered_sources,
        cache_age_seconds = math.max(0, os.time() - (tonumber(cache and cache.updated_at) or os.time())),
    })
    if #filtered_sources == 0 then
        return false
    end

    self:showSourceList(filtered_sources, { force_new = true })
    return true
end


function Methods:showMangaForSource(source)
    return self:getClient():showMangaForSource(source)
end


SourceCatalog.methods = Methods

return SourceCatalog
