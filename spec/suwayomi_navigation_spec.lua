package.path = "?.lua;" .. package.path

describe("suwayomi/navigation", function()
    local closed
    local ui_manager

    local function load_navigation()
        package.loaded["suwayomi/navigation"] = nil
        return require("suwayomi/navigation")
    end

    before_each(function()
        closed = {}
        ui_manager = {
            close = function(_, widget)
                table.insert(closed, widget)
                if type(widget) == "table" and widget.close_callback then
                    widget.close_callback()
                end
            end,
        }
    end)

    after_each(function()
        package.loaded["suwayomi/navigation"] = nil
    end)

    it("push tracks widgets in order and isCurrent follows the top", function()
        local Navigation = load_navigation()
        local navigator = Navigation.new(ui_manager)
        local first = {}
        local second = {}

        navigator:push("sources", first)
        assert.is_true(navigator:contains(first))
        assert.is_true(navigator:isCurrent(first))

        navigator:push("manga", second)
        assert.is_true(navigator:contains(first))
        assert.is_true(navigator:contains(second))
        assert.is_false(navigator:isCurrent(first))
        assert.is_true(navigator:isCurrent(second))
    end)

    it("replaceBranch closes old branch widgets and leaves only the new widget current", function()
        local Navigation = load_navigation()
        local navigator = Navigation.new(ui_manager)
        local first = {}
        local second = {}
        local replacement = {}

        navigator:push("sources", first)
        navigator:push("manga", second)
        navigator:replaceBranch("library", replacement)

        assert.are.same({ second, first }, closed)
        assert.is_false(navigator:contains(first))
        assert.is_false(navigator:contains(second))
        assert.is_true(navigator:contains(replacement))
        assert.is_true(navigator:isCurrent(replacement))
    end)

    it("closeAll closes each widget once top-first", function()
        local Navigation = load_navigation()
        local navigator = Navigation.new(ui_manager)
        local first = {}
        local second = {}
        local third = {}

        navigator:push("sources", first)
        navigator:push("manga", second)
        navigator:push("chapters", third)
        navigator:closeAll()

        assert.are.same({ third, second, first }, closed)
        assert.is_false(navigator:contains(first))
        assert.is_false(navigator:contains(second))
        assert.is_false(navigator:contains(third))
    end)

    it("current widget close_callback removes the widget and calls original callback", function()
        local Navigation = load_navigation()
        local navigator = Navigation.new(ui_manager)
        local original_calls = 0
        local widget = {
            close_callback = function()
                original_calls = original_calls + 1
            end,
        }

        navigator:push("sources", widget)
        widget.close_callback()

        assert.are.equal(0, #closed)
        assert.are.equal(1, original_calls)
        assert.is_false(navigator:contains(widget))
        assert.is_false(navigator:isCurrent(widget))
    end)

    it("non-current widget close_callback preserves navigation tracking", function()
        local Navigation = load_navigation()
        local navigator = Navigation.new(ui_manager)
        local original_calls = 0
        local parent = {
            close_callback = function()
                original_calls = original_calls + 1
            end,
        }
        local child = {}

        navigator:push("library", parent)
        navigator:push("manga-actions", child)
        parent.close_callback()

        assert.are.equal(0, #closed)
        assert.are.equal(1, original_calls)
        assert.is_true(navigator:contains(parent))
        assert.is_true(navigator:contains(child))
        assert.is_false(navigator:isCurrent(parent))
    end)

    it("closeAll still closes a parent widget after KOReader fires its close_callback", function()
        local Navigation = load_navigation()
        local navigator = Navigation.new(ui_manager)
        local library = {}
        local manga_actions = {}

        navigator:push("library", library)
        navigator:push("manga-actions", manga_actions)
        library.close_callback()
        navigator:closeAll()

        assert.are.same({ manga_actions, library }, closed)
        assert.is_false(navigator:contains(library))
        assert.is_false(navigator:contains(manga_actions))
    end)

    it("closeAll calls the original close_callback exactly once", function()
        local Navigation = load_navigation()
        local navigator = Navigation.new(ui_manager)
        local original_calls = 0
        local widget = {
            close_callback = function()
                original_calls = original_calls + 1
            end,
        }

        navigator:push("sources", widget)
        navigator:closeAll()

        assert.are.same({ widget }, closed)
        assert.are.equal(1, original_calls)
        assert.is_false(navigator:contains(widget))
    end)
end)
