package.path = "?.lua;" .. package.path

-- Downloads UI specs cover snapshot-to-menu rendering. Queue/controller specs
-- own state transitions, retries, cancellation, and navigation callbacks.
describe("suwayomi/ui/downloads", function()
    local shown_dialog

    before_each(function()
        shown_dialog = nil

        package.loaded["suwayomi/ui/downloads"] = nil
        package.loaded["suwayomi/ui/list_menu"] = nil
        package.loaded["suwayomi/ui/menu_utils"] = nil
        package.loaded.gettext = nil
        package.loaded["ui/widget/menu"] = nil
        package.loaded["ui/widget/titlebar"] = nil
        package.loaded["ui/uimanager"] = nil

        package.preload.gettext = function()
            return function(text)
                return text
            end
        end

        package.preload["ui/widget/menu"] = function()
            return {
                new = function(_, options)
                    return options
                end,
            }
        end

        package.preload["ui/widget/titlebar"] = function()
            return {
                new = function(_, options)
                    return options
                end,
            }
        end

        package.preload["ui/uimanager"] = function()
            return {
                show = function(_, widget)
                    shown_dialog = widget
                end,
            }
        end

        package.preload["suwayomi/ui/list_menu"] = function()
            return {
                show = function(options)
                    options.renderer = "list_menu"
                    options.title_bar_fm_style = true
                    options.is_popout = false
                    if options.on_title_bar_left_tap then
                        options.onLeftButtonTap = function()
                            return options.on_title_bar_left_tap(options)
                        end
                    end
                    shown_dialog = options
                    return options
                end,
            }
        end
    end)

    after_each(function()
        package.preload.gettext = nil
        package.preload["ui/widget/menu"] = nil
        package.preload["ui/widget/titlebar"] = nil
        package.preload["ui/uimanager"] = nil
        package.preload["suwayomi/ui/list_menu"] = nil
    end)

    it("builds downloads menu rows for active queued and failed items", function()
        local downloads = require("suwayomi/ui/downloads")

        local rows = downloads.buildDownloadsMenuTable({
            active = {
                {
                    key = "m-active:144",
                    manga = { title = "Frieren" },
                    chapter = { name = "Ch. 144" },
                    progress = { current = 3, total = 24 },
                },
            },
            queued = {
                {
                    key = "m-queued:192",
                    manga = { title = "Dandadan" },
                    chapter = { name = "Ch. 192" },
                },
            },
            failed = {
                {
                    key = "m-failed:205",
                    manga = { title = "Chainsaw Man" },
                    chapter = { name = "Ch. 205" },
                    progress = { error = "network timeout" },
                },
            },
        }, {})

        assert.are.equal("Frieren / Ch. 144", rows[1].text)
        assert.are.equal("Downloading 3/24", rows[1].mandatory)
        assert.are.equal("Dandadan / Ch. 192", rows[2].text)
        assert.are.equal("Queued", rows[2].mandatory)
        assert.are.equal("Chainsaw Man / Ch. 205", rows[3].text)
        assert.are.equal("Failed", rows[3].mandatory)
        assert.are.equal("network timeout", rows[3].subtitle)
        assert.are.equal("Clear failed", rows[4].text)
    end)

    it("builds persistent empty-state rows with folder and queue summary", function()
        local downloads = require("suwayomi/ui/downloads")

        local rows = downloads.buildDownloadsMenuTable({
            active = {},
            queued = {},
            failed = {},
        }, {}, {
            download_directory_summary = "Books/Manga",
        })

        assert.are.equal("Download folder", rows[1].text)
        assert.are.equal("Books/Manga", rows[1].subtitle)
        assert.are.equal("Queue", rows[2].text)
        assert.are.equal("0 active, 0 queued, 0 failed", rows[2].subtitle)
        assert.are.equal("No downloads queued.", rows[3].text)
        assert.are.equal("Downloaded chapters are in Books/Manga.", rows[4].text)
        assert.is_nil(rows[1].callback)
        assert.is_nil(rows[2].callback)
        assert.is_nil(rows[3].callback)
        assert.is_nil(rows[4].callback)
        assert.is_false(rows[1].select_enabled)
        assert.is_false(rows[2].select_enabled)
        assert.is_false(rows[3].select_enabled)
        assert.is_false(rows[4].select_enabled)
    end)

    it("shows downloads menu and passes the native menu to row callbacks", function()
        local downloads = require("suwayomi/ui/downloads")
        local cancelled_key
        local retried_key
        local selected_active_key
        local active_menu
        local queued_menu
        local failed_menu
        local clear_menu
        local cleared = false

        downloads.showDownloadsMenu({
            active = {
                {
                    key = "m-active:144",
                    manga = { title = "Frieren" },
                    chapter = { name = "Ch. 144" },
                    progress = { current = 3, total = 24 },
                },
            },
            queued = {
                {
                    key = "m-queued:192",
                    manga = { title = "Dandadan" },
                    chapter = { name = "Ch. 192" },
                },
            },
            failed = {
                {
                    key = "m-failed:205",
                    manga = { title = "Chainsaw Man" },
                    chapter = { name = "Ch. 205" },
                    progress = { error = "network timeout" },
                },
            },
        }, {
            onSelectActive = function(job, menu)
                selected_active_key = job.key
                active_menu = menu
            end,
            onSelectQueued = function(job, menu)
                cancelled_key = job.key
                queued_menu = menu
            end,
            onRetryFailed = function(job, menu)
                retried_key = job.key
                failed_menu = menu
            end,
            onClearFailed = function(menu)
                cleared = true
                clear_menu = menu
            end,
        })

        assert.are.equal("Suwayomi Downloads", shown_dialog.title)
        assert.are.equal("list_menu", shown_dialog.renderer)

        shown_dialog.item_table[1].callback()
        shown_dialog.item_table[2].callback()
        shown_dialog.item_table[3].callback()
        shown_dialog.item_table[4].callback()

        assert.are.equal("m-active:144", selected_active_key)
        assert.are.equal("m-queued:192", cancelled_key)
        assert.are.equal("m-failed:205", retried_key)
        assert.are.equal(shown_dialog, active_menu)
        assert.are.equal(shown_dialog, queued_menu)
        assert.are.equal(shown_dialog, failed_menu)
        assert.are.equal(shown_dialog, clear_menu)
        assert.is_true(cleared)
    end)

    it("applies requested downloads title-bar behavior", function()
        local downloads = require("suwayomi/ui/downloads")
        local tapped_home = false

        downloads.showDownloadsMenu({}, {}, {
            title = "Downloads (2)",
            title_bar_left_icon = "appbar.menu",
            on_title_bar_left_tap = function(menu)
                tapped_home = menu == shown_dialog
                return true
            end,
        })

        assert.are.equal("Downloads (2)", shown_dialog.title)
        assert.is_nil(shown_dialog.custom_title_bar)
        assert.are.equal("appbar.menu", shown_dialog.title_bar_left_icon)
        assert.is_true(shown_dialog.title_bar_fm_style)
        assert.is_false(shown_dialog.is_popout)

        shown_dialog.onLeftButtonTap()

        assert.is_true(tapped_home)
    end)

    it("passes close callbacks through the downloads menu", function()
        local downloads = require("suwayomi/ui/downloads")
        local closed = false

        downloads.showDownloadsMenu({}, {}, {
            close_callback = function()
                closed = true
            end,
        })

        shown_dialog.close_callback()

        assert.is_true(closed)
    end)
end)
