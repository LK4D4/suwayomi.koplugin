describe("suwayomi/ui/manga_rows", function()
    before_each(function()
        package.loaded["suwayomi/ui/manga_rows"] = nil
        package.preload["gettext"] = function()
            return function(text) return text end
        end
    end)

    after_each(function()
        package.preload["gettext"] = nil
        package.loaded["suwayomi/ui/manga_rows"] = nil
    end)

    it("uses title, id, then an empty title fallback", function()
        local rows = require("suwayomi/ui/manga_rows")

        assert.are.equal("Frieren", rows.getTitle({ title = "Frieren", id = "m1" }))
        assert.are.equal("m2", rows.getTitle({ id = "m2" }))
        assert.are.equal("", rows.getTitle(nil))
    end)

    it("shows in-library state only when requested and true", function()
        local rows = require("suwayomi/ui/manga_rows")

        assert.are.equal("In Library", rows.getMandatory({ in_library = true }, {
            show_in_library = true,
        }))
        assert.is_nil(rows.getMandatory({ in_library = false }, {
            show_in_library = true,
        }))
        assert.is_nil(rows.getMandatory({ in_library = true }, {
            show_in_library = false,
        }))
    end)

    it("builds rows without mutating manga tables", function()
        local rows = require("suwayomi/ui/manga_rows")
        local manga = { id = "m1", title = "Frieren", in_library = true }
        local selected

        local row = rows.buildRow(manga, {
            show_in_library = true,
            on_select = function(value)
                selected = value
            end,
        })

        assert.are.equal("Frieren", row.text)
        assert.are.equal("In Library", row.mandatory)
        assert.are.same(manga, row.manga)
        assert.is_nil(manga.menu_text)

        row.callback()
        assert.are.same(manga, selected)
    end)

    it("builds menu tables in source order", function()
        local rows = require("suwayomi/ui/manga_rows")
        local selected = {}
        local manga = {
            { id = "m1", title = "Added", in_library = true },
            { id = "m2", title = "New", in_library = false },
        }

        local menu_table = rows.buildMenuTable(manga, {
            show_in_library = true,
            on_select = function(value)
                table.insert(selected, value.id)
            end,
        })

        assert.are.equal("Added", menu_table[1].text)
        assert.are.equal("In Library", menu_table[1].mandatory)
        assert.are.equal("New", menu_table[2].text)
        assert.is_nil(menu_table[2].mandatory)

        menu_table[1].callback()
        menu_table[2].callback()
        assert.are.same({ "m1", "m2" }, selected)
    end)
end)
