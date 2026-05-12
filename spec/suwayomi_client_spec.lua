package.path = "?.lua;" .. package.path

local helper = require("spec/support/suwayomi_client_spec_helper")

describe("suwayomi/client core", function()
    after_each(function()
        helper.clearClientModules()
    end)



    it("attaches source metadata to selected manga without overwriting existing values", function()
        local Client = require("suwayomi/client")
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
end)
