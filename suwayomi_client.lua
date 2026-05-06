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

function SuwayomiClient:showMangaForSource(source)
    return self:time("showMangaForSource", {
        source_id = source and source.id,
    }, function()
        local credentials = self.settings:load()
        local result = self.plugin:withLoadingMessage("manga", self:translate("Loading manga..."), function()
            return self.api.fetchMangaForSource(credentials, source.id)
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
            self.plugin:showChaptersForManga(manga)
        end)
    end)
end

return SuwayomiClient
