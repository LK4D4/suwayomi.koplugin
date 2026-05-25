package.path = "?.lua;" .. package.path

local Marker = require("spec/support/i18n_marker")

describe("suwayomi/manga/action_menu", function()
    before_each(function()
        Marker.install()
        package.loaded["suwayomi/manga/action_menu"] = nil
        package.loaded["suwayomi/i18n"] = nil
        package.loaded.gettext = nil
        package.preload.gettext = function()
            return function(text)
                return text
            end
        end
    end)

    after_each(function()
        Marker.uninstall()
        package.loaded["suwayomi/manga/action_menu"] = nil
        package.loaded["suwayomi/i18n"] = nil
        package.loaded.gettext = nil
        package.preload.gettext = nil
    end)

    it("translates shared manga action labels", function()
        local actions = require("suwayomi/manga/action_menu")
        local manga = {
            id = "m1",
            in_library = true,
        }
        local owner = {
            current_chapter_context = {
                manga = manga,
                chapters = {
                    { id = "c1", is_read = false },
                },
            },
            getVisibleChapters = function(_, chapters)
                return chapters
            end,
            isChapterDownloaded = function()
                return true
            end,
        }

        local list = actions.buildMainActions(owner, manga, {
            include_open_chapters = true,
            include_select_all = true,
        })

        assert.are.equal("open_chapters", list[1].id)
        assert.are.equal("tx:Open chapters", list[1].text)
        assert.are.equal("tx:Select all", list[2].text)
        assert.are.equal("tx:Manga information", list[3].text)
        assert.are.equal("tx:Open first unread", list[4].text)
        assert.are.equal("tx:Refresh chapters", list[5].text)
        assert.are.equal("tx:Bulk downloads", list[6].text)
        assert.are.equal("tx:Download ahead", list[7].text)
        assert.are.equal("tx:Delete read downloads", list[8].text)
        assert.are.equal("remove_from_library", list[9].id)
        assert.are.equal("tx:Remove from library", list[9].text)
        assert.is_true(list[9].destructive)
    end)

    it("translates bulk and download-ahead labels", function()
        local actions = require("suwayomi/manga/action_menu")

        assert.are.equal("tx:Download first unread", actions.buildBulkDownloadActions()[1].text)
        assert.are.equal("download_all_chapters", actions.buildBulkDownloadActions()[6].id)
        assert.are.equal("tx:Download all chapters", actions.buildBulkDownloadActions()[6].text)
        assert.are.equal("tx:Keep next 5 downloaded", actions.buildKeepDownloadedActions()[1].text)
        assert.are.equal("tx:Stop download ahead", actions.buildKeepDownloadedActions()[4].text)
    end)
end)
