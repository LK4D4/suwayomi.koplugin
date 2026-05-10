package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/chapters/menu", function()
    it("exports chapter menu construction methods", function()
        helper.assertControllerModule("suwayomi/chapters/menu", {
            "buildChapterMenuItems",
            "buildChapterMenuOptions",
            "buildQuickChapterMenuItems",
            "showChapterActions",
        })
    end)

    it("quick refresh reflects updated read state instead of stale cached row status", function()
        helper.stubControllerDependencies()
        package.loaded["suwayomi/chapters/menu"] = nil
        local ChapterMenu = require("suwayomi/chapters/menu")
        local plugin = {
            current_chapter_context = {
                manga = { id = "m1", title = "Manga" },
                chapters = {},
            },
            current_chapter_options = {
                chapters = {
                    { id = "c1", name = "Chapter 1", menu_text = "Chapter 1" },
                },
            },
            getChapterDownloadKey = function(_, manga, chapter)
                return tostring(manga.id) .. ":" .. tostring(chapter.id)
            end,
            getChapterDownloadStatus = function()
                return nil
            end,
            stripChapterSelectionStatus = function(_, menu_status)
                return menu_status
            end,
            isChapterSelected = function()
                return false
            end,
            getDownloadQueue = function()
                return {
                    formatChapterMenuStatus = function(_, chapter, status)
                        if chapter.is_read == true or status.state == "read" then
                            return "Read"
                        end
                        return status.state
                    end,
                }
            end,
        }
        for name, method in pairs(ChapterMenu.methods) do
            plugin[name] = method
        end

        local items = plugin:buildQuickChapterMenuItems(
            plugin.current_chapter_context.manga,
            { { id = "c1", name = "Chapter 1", is_read = true } }
        )

        assert.are.equal("Read", items[1].menu_status)
    end)
end)
