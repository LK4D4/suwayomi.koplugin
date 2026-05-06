package.path = "?.lua;" .. package.path

describe("suwayomi_client", function()
    after_each(function()
        package.loaded.suwayomi_client = nil
    end)

    it("attaches source metadata to selected manga without overwriting existing values", function()
        local Client = require("suwayomi_client")
        local client = Client:new{}
        local manga = {
            id = "m1",
            title = "Sousou no Frieren",
            source = {
                id = "existing",
            },
        }

        client:attachSourceToManga(manga, {
            id = "s1",
            display_name = "MangaDex (EN)",
            raw_name = "MangaDex",
            lang = "en",
        })

        assert.are.same({
            id = "existing",
            displayName = "MangaDex (EN)",
            name = "MangaDex",
            lang = "en",
        }, manga.source)
    end)

    it("loads manga for a source and opens the selected manga through the plugin", function()
        local Client = require("suwayomi_client")
        local opened_manga
        local loading_messages = {}
        local log_events = {}
        local client = Client:new{
            settings = {
                load = function()
                    return { server_url = "https://suwayomi.example" }
                end,
            },
            api = {
                fetchMangaForSource = function(_, options)
                    assert.are.same({
                        source_id = "s1",
                        page = 1,
                        type = "POPULAR",
                    }, options)
                    return {
                        ok = true,
                        manga = {
                            { id = "m1", title = "Sousou no Frieren" },
                        },
                    }
                end,
            },
            ui = {
                showMangaMenu = function(manga, onSelect)
                    assert.are.equal("Sousou no Frieren", manga[1].title)
                    onSelect(manga[1])
                end,
            },
            debug = {
                time = function(_, _, callback)
                    return callback()
                end,
                log = function(event)
                    table.insert(log_events, event)
                end,
            },
            plugin = {
                withLoadingMessage = function(_, key, message, callback)
                    table.insert(loading_messages, key .. ":" .. message)
                    return callback()
                end,
                showMessage = function(_, message)
                    error("unexpected message: " .. tostring(message))
                end,
                showChaptersForManga = function(_, manga)
                    opened_manga = manga
                end,
            },
            gettext = function(text)
                return text
            end,
        }

        client:showMangaForSource({
            id = "s1",
            display_name = "MangaDex (EN)",
            raw_name = "MangaDex",
            lang = "en",
        })

        assert.are.same({ "manga:Loading manga..." }, loading_messages)
        assert.are.same({
            id = "s1",
            displayName = "MangaDex (EN)",
            name = "MangaDex",
            lang = "en",
        }, opened_manga.source)
        assert.are.equal("manga_loaded", log_events[1].event)
        assert.are.equal(1, log_events[1].manga_count)
    end)
end)
