package.path = "?.lua;" .. package.path

describe("suwayomi/source_filters", function()
    local SourceFilters

    before_each(function()
        package.loaded["suwayomi/source_filters"] = nil
        SourceFilters = require("suwayomi/source_filters")
    end)

    it("builds filter changes from valid drafts only", function()
        local schema = {
            { type = "CheckBoxFilter", name = "Completed", default = false },
            { type = "TriStateFilter", name = "Official", default = "IGNORE" },
            { type = "SelectFilter", name = "Demographic", values = { "Any", "Shounen" }, default = 0 },
            { type = "TextFilter", name = "Author", default = "" },
            { type = "SortFilter", name = "Sort", values = { "Relevance" }, default = { index = 0, ascending = false } },
            { type = "HeaderFilter", name = "Tags" },
        }
        local changes = SourceFilters.buildFilterChanges(schema, {
            { position = 1, type = "checkBoxState", state = true },
            { position = 2, type = "triState", state = "INCLUDE" },
            { position = 3, type = "selectState", state = 1 },
            { position = 4, type = "textState", state = "Abe" },
            { position = 5, type = "sortState", state = { index = 0, ascending = true } },
            { position = 1, type = "checkBoxState", state = false },
            { position = 6, type = "textState", state = "bad type" },
            { position = 99, type = "textState", state = "bad position" },
        })

        assert.are.equal(5, #changes)
        assert.are.equal(0, changes[1].position)
        assert.are.equal(true, changes[1].checkBoxState)
        assert.are.equal("INCLUDE", changes[2].triState)
        assert.are.equal(1, changes[3].selectState)
        assert.are.equal("Abe", changes[4].textState)
        assert.are.same({ index = 0, ascending = true }, changes[5].sortState)
    end)

    it("builds group filter changes", function()
        local schema = {
            {
                type = "GroupFilter",
                name = "Genres",
                filters = {
                    { type = "CheckBoxFilter", name = "Fantasy", default = false },
                    { type = "TriStateFilter", name = "Official", default = "IGNORE" },
                },
            },
        }
        local changes = SourceFilters.buildFilterChanges(schema, {
            {
                position = 1,
                group_change = { position = 1, type = "checkBoxState", state = true },
            },
            {
                position = 1,
                group_change = { position = 2, type = "textState", state = "bad type" },
            },
        })

        assert.are.equal(1, #changes)
        assert.are.equal(0, changes[1].position)
        assert.are.equal(0, changes[1].groupChange.position)
        assert.are.equal(true, changes[1].groupChange.checkBoxState)
    end)

    it("normalizes draft query and filter entries", function()
        local draft = SourceFilters.normalizeDraft({
            query = 123,
            filters = {
                { position = "2", type = "textState", state = 77 },
                { position = "3", type = "checkBoxState", state = 1 },
                {
                    position = "4",
                    group_change = { position = "1", type = "selectState", state = "2" },
                },
                "bad",
            },
        })

        assert.are.equal("123", draft.query)
        assert.are.equal(3, #draft.filters)
        assert.are.equal(2, draft.filters[1].position)
        assert.are.equal("77", draft.filters[1].state)
        assert.are.equal(false, draft.filters[2].state)
        assert.are.equal(4, draft.filters[3].position)
        assert.are.equal(1, draft.filters[3].group_change.position)
        assert.are.equal(2, draft.filters[3].group_change.state)
    end)
end)
