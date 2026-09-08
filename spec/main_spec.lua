package.path = "?.lua;" .. package.path

local runtime_helper = require("spec/support/plugin_runtime_spec_helper")

describe("suwayomi plugin", function()
    local runtime

    before_each(function()
        runtime = runtime_helper.install()
    end)

    after_each(function()
        runtime_helper.teardown()
    end)

    local function build_plugin(instance)
        local plugin_class = require("main")
        return plugin_class(instance or {})
    end

    it("retires chapter requests on host CloseWidget without consuming the host event", function()
        local plugin = build_plugin()
        local canceled = false
        plugin.cancelReaderReturnRequest = function() canceled = true end
        assert.is_nil(plugin:onCloseWidget())
        assert.is_true(plugin.suwayomi_host_retired)
        assert.is_true(canceled)
        assert.is_false(plugin:showChaptersForManga({ id = "17" }))
    end)

    it("registers a file-manager dispatcher action and main-menu entry on init", function()
        local plugin = build_plugin({
            ui = {
                menu = {
                    registerToMainMenu = function(_, instance)
                        runtime.registered_menu_plugin = instance
                    end,
                },
            },
        })

        plugin:init()

        assert.are.equal(plugin, runtime.registered_menu_plugin)
        assert.are.equal(1, #runtime.registered_actions)
        assert.are.equal("suwayomi_action", runtime.registered_actions[1].name)
        assert.are.equal("Suwayomi", runtime.registered_actions[1].definition.title)
        assert.are.equal(true, runtime.registered_actions[1].definition.filemanager)
        assert.is_nil(runtime.registered_actions[1].definition.general)
    end)

    it("registers a conditional reader-menu entry when initialized in book mode", function()
        local plugin = build_plugin({
            ui = {
                document = { file = "/downloads/Local/Manga/Chapter 1.cbz" },
                menu = {
                    registerToMainMenu = function(_, instance)
                        runtime.registered_menu_plugin = instance
                    end,
                },
            },
            document = { file = "/downloads/Local/Manga/Chapter 1.cbz" },
        })

        plugin:init()

        assert.are.equal(plugin, runtime.registered_menu_plugin)
    end)

    it("adds the plugin under the search menu section and opens the Suwayomi hub", function()
        local menu_items = {}
        local plugin = build_plugin()

        plugin:addToMainMenu(menu_items)

        assert.is_table(menu_items.suwayomi)
        assert.are.equal("Suwayomi", menu_items.suwayomi.text)
        assert.are.equal("search", menu_items.suwayomi.sorting_hint)
        assert.is_function(menu_items.suwayomi.callback)
        assert.is_nil(menu_items.suwayomi.sub_item_table)

        menu_items.suwayomi.callback()

        assert.is_table(runtime.shown_home_dialog)
        assert.are.equal("Library", runtime.shown_home_dialog.actions[1].text)
        assert.are.equal("Browse", runtime.shown_home_dialog.actions[2].text)
        assert.are.equal("Downloads", runtime.shown_home_dialog.actions[3].text)
        assert.are.equal("Sync", runtime.shown_home_dialog.actions[4].text)
        assert.are.equal("Settings", runtime.shown_home_dialog.actions[5].text)
        assert.are.equal("Close plugin", runtime.shown_home_dialog.actions[6].text)
    end)

    it("closes the launching KOReader menu before opening the Suwayomi hub", function()
        local menu_items = {}
        local plugin = build_plugin()
        local parent_menu = { name = "search-menu" }

        plugin:addToMainMenu(menu_items)
        menu_items.suwayomi.callback(parent_menu)

        assert.are.same({ parent_menu }, runtime.closed_widgets)
        assert.is_table(runtime.shown_home_dialog)
    end)

    it("adds only the reader return action in book mode when the document is from Suwayomi", function()
        runtime_helper.teardown()
        runtime = runtime_helper.install({
            reader_return_contexts = {
                ["/downloads/Local/Manga/Chapter 1.cbz"] = {
                    path = "/downloads/Local/Manga/Chapter 1.cbz",
                    manga_id = "m1",
                    manga_title = "Manga",
                    chapter_id = "c1",
                    chapter_name = "Chapter 1",
                },
            },
        })
        local menu_items = {}
        local plugin = build_plugin({
            ui = {
                document = { file = "/downloads/Local/Manga/Chapter 1.cbz" },
            },
            document = { file = "/downloads/Local/Manga/Chapter 1.cbz" },
            returnToSuwayomiChapters = function(self)
                self.returned_to_chapters = true
            end,
        })

        plugin:addToMainMenu(menu_items)

        assert.is_nil(menu_items.suwayomi)
        assert.is_table(menu_items.suwayomi_reader_return)
        assert.are.equal("Go to Suwayomi", menu_items.suwayomi_reader_return.text)
        assert.are.equal("main", menu_items.suwayomi_reader_return.sorting_hint)
        assert.are.equal("suwayomi_reader_return", runtime.reader_menu_order.main[1])
        assert.are.equal("history", runtime.reader_menu_order.main[2])

        menu_items.suwayomi_reader_return.callback()

        assert.is_true(plugin.returned_to_chapters)
    end)

    it("does not duplicate the reader return action in the reader menu order", function()
        runtime_helper.teardown()
        runtime = runtime_helper.install({
            reader_return_contexts = {
                ["/downloads/Local/Manga/Chapter 1.cbz"] = {
                    path = "/downloads/Local/Manga/Chapter 1.cbz",
                    manga_id = "m1",
                },
            },
            reader_menu_order = {
                main = { "suwayomi_reader_return", "history" },
            },
        })
        local plugin = build_plugin({
            ui = {
                document = { file = "/downloads/Local/Manga/Chapter 1.cbz" },
            },
            document = { file = "/downloads/Local/Manga/Chapter 1.cbz" },
        })

        plugin:addToMainMenu({})

        assert.are.equal("suwayomi_reader_return", runtime.reader_menu_order.main[1])
        assert.are.equal("history", runtime.reader_menu_order.main[2])
        assert.is_nil(runtime.reader_menu_order.main[3])
    end)

    it("does not add a reader menu item for non-Suwayomi books", function()
        local menu_items = {}
        local plugin = build_plugin({
            ui = {
                document = { file = "/books/Other.cbz" },
            },
            document = { file = "/books/Other.cbz" },
        })

        plugin:addToMainMenu(menu_items)

        assert.is_nil(menu_items.suwayomi)
        assert.is_nil(menu_items.suwayomi_reader_return)
    end)

    it("constructs the client lazily and reuses it", function()
        local plugin = build_plugin()

        local first_client = plugin:getClient()
        local second_client = plugin:getClient()

        assert.are.equal(first_client, second_client)
        assert.are.equal(1, #runtime.client_instances)
        assert.are.equal(plugin, first_client.options.plugin)
        assert.is_function(first_client.options.gettext)
        assert.are.equal("Library", first_client.options.gettext("Library"))
    end)

    it("constructs the download queue lazily with saved settings and recovers it on init", function()
        runtime_helper.teardown()
        runtime = runtime_helper.install({
            max_parallel_chapter_downloads = 3,
        })

        local plugin = build_plugin({
            ui = {
                menu = {
                    registerToMainMenu = function(_, instance)
                        runtime.registered_menu_plugin = instance
                    end,
                },
            },
        })

        assert.are.equal(0, #runtime.queue_instances)

        plugin:init()

        local queue = runtime.queue_instances[1]
        assert.is_table(queue)
        assert.are.equal(queue, plugin:getDownloadQueue())
        assert.are.equal(3, queue.max_active_chapters)
        assert.is_true(queue.recovered)
        assert.are.equal(1, #runtime.queue_instances)
    end)

    it("reevaluates blocked cleanup before download-directory callbacks", function()
        local plugin = build_plugin()
        local events = {}
        plugin.onFinishedCleanupDownloadDirectoryChanged = function(self)
            self.finished_cleanup_revalidate_blocked = true
            table.insert(events, "cleanup-directory-changed")
        end

        plugin:chooseDownloadDirectory(function()
            table.insert(events, "caller")
        end)
        runtime.directory_chooser_callback("/new/books")

        assert.is_true(plugin.finished_cleanup_revalidate_blocked)
        assert.are.same({ "cleanup-directory-changed", "caller" }, events)
    end)

    it("drains suppressed download status refreshes after the outer callback finishes", function()
        local plugin = build_plugin()
        local refreshes = {}
        plugin.refreshChapterMenu = function(_, options)
            table.insert(refreshes, options)
        end

        local queue = plugin:getDownloadQueue()
        plugin:withChapterMenuRefreshSuppressed(function()
            plugin:onDownloadSnapshot(queue:getSnapshot())
            assert.are.equal(0, #refreshes)
            assert.is_true(plugin.pending_chapter_menu_refresh)
        end)

        assert.are.same({ { quick = true } }, refreshes)
        assert.is_nil(plugin.pending_chapter_menu_refresh)
    end)

    it("constructs navigation lazily and closes tracked Suwayomi screens", function()
        local plugin = build_plugin()
        local first = { name = "sources" }
        local second = { name = "manga" }

        assert.are.equal(plugin:getNavigation(), plugin:getNavigation())

        plugin:trackSuwayomiScreen("sources", first)
        plugin:trackSuwayomiScreen("manga", second)
        assert.is_true(plugin:isSuwayomiScreenActive(first))
        assert.is_true(plugin:isSuwayomiScreenActive(second))

        plugin:closeSuwayomiPlugin()

        assert.are.same({ second, first }, runtime.closed_widgets)
        assert.is_false(plugin:isSuwayomiScreenActive(first))
        assert.is_false(plugin:isSuwayomiScreenActive(second))
    end)

    it("refreshes the visible home failure count only when terminal failures change", function()
        local plugin = build_plugin({ refreshChapterMenu = function() end })
        local queue = plugin:getDownloadQueue()
        local failed_count = 0
        function queue:getFailedCount()
            return failed_count
        end

        local dialog = plugin:showHome()
        assert.are.equal("Downloads", dialog.actions[3].text)

        failed_count = 2
        plugin:onDownloadSnapshot(queue:getSnapshot())
        assert.are.equal("Downloads · 2 failed", dialog.actions[3].text)
        assert.are.equal(dialog, runtime.shown_home_dialog)
        plugin:onDownloadSnapshot(queue:getSnapshot())
        assert.are.equal(1, #runtime.home_downloads_labels)

        failed_count = 1
        plugin:withChapterMenuRefreshSuppressed(function()
            plugin:onDownloadSnapshot(queue:getSnapshot())
            assert.are.equal("Downloads · 2 failed", dialog.actions[3].text)
        end)
        assert.are.equal("Downloads · 1 failed", dialog.actions[3].text)

        failed_count = 0
        plugin:onDownloadSnapshot(queue:getSnapshot())
        assert.are.equal("Downloads", dialog.actions[3].text)
        assert.are.same({ "Downloads · 2 failed", "Downloads · 1 failed", "Downloads" }, runtime.home_downloads_labels)
        assert.is_true(plugin:isSuwayomiScreenActive(dialog))
        assert.are.same({}, runtime.closed_widgets)
    end)

    it("does not refresh closed home dialogs after download failures change", function()
        local plugin = build_plugin({ refreshChapterMenu = function() end })
        local queue = plugin:getDownloadQueue()
        local failed_count = 1
        function queue:getFailedCount()
            return failed_count
        end
        local dialog = plugin:showHome()
        assert.are.equal("Downloads · 1 failed", dialog.actions[3].text)

        dialog.onClose()
        failed_count = 2
        plugin:onDownloadSnapshot(queue:getSnapshot())

        assert.are.same({}, runtime.home_downloads_labels)
        assert.is_nil(plugin.current_home_dialog)
        assert.is_false(plugin:isSuwayomiScreenActive(dialog))

        local reopened = plugin:showHome()
        assert.are.equal("Downloads · 2 failed", reopened.actions[3].text)
        plugin:getNavigation():pop(reopened)
        failed_count = 0
        plugin:onDownloadSnapshot(queue:getSnapshot())
        assert.are.same({}, runtime.home_downloads_labels)
        assert.is_nil(plugin.current_home_dialog)
    end)

    it("marks plugin closing and cancels active work before closing screens", function()
        local close_callback_saw_closing
        local plugin = build_plugin({
            cancelReaderReturnRequest = function(self)
                self.reader_return_cancel_saw_closing = self.suwayomi_plugin_closing == true
            end,
            cancelMangaNetworkRequests = function(self)
                self.manga_cancel_saw_closing = self.suwayomi_plugin_closing == true
            end,
            cancelPendingReadSync = function(self)
                self.read_sync_cancel_saw_closing = self.suwayomi_plugin_closing == true
            end,
            cancelSourceFetchWorker = function(self)
                self.source_fetch_cancel_saw_closing = self.suwayomi_plugin_closing == true
            end,
            cancelExtensionWorker = function(self)
                self.extension_cancel_saw_closing = self.suwayomi_plugin_closing == true
            end,
        })
        local chapter_menu = {
            name = "chapters",
            close_callback = function()
                close_callback_saw_closing = plugin.suwayomi_plugin_closing == true
            end,
        }
        plugin.client = {
            cancelLibraryNetworkRequests = function(self)
                self.library_cancel_saw_closing = plugin.suwayomi_plugin_closing == true
            end,
        }

        plugin:trackSuwayomiScreen("chapters", chapter_menu)
        plugin:closeSuwayomiPlugin()

        assert.is_true(plugin.reader_return_cancel_saw_closing)
        assert.is_true(plugin.manga_cancel_saw_closing)
        assert.is_true(plugin.client.library_cancel_saw_closing)
        assert.is_true(plugin.read_sync_cancel_saw_closing)
        assert.is_true(plugin.source_fetch_cancel_saw_closing)
        assert.is_true(plugin.extension_cancel_saw_closing)
        assert.is_true(close_callback_saw_closing)
        assert.is_nil(plugin.suwayomi_plugin_closing)
    end)

    it("untracks only the active plugin screen when its cross closes", function()
        local plugin = build_plugin()
        local original_close_calls = 0
        local library = {
            name = "library",
            onClose = function()
                original_close_calls = original_close_calls + 1
                return true
            end,
        }
        local chapters = {
            name = "chapters",
            onClose = function()
                original_close_calls = original_close_calls + 1
                return true
            end,
        }

        plugin:trackSuwayomiScreen("library", library)
        plugin:trackSuwayomiScreen("chapters", chapters)

        assert.is_true(chapters:onClose())

        assert.are.same({}, runtime.closed_widgets)
        assert.are.equal(1, original_close_calls)
        assert.is_true(plugin:isSuwayomiScreenActive(library))
        assert.is_false(plugin:isSuwayomiScreenActive(chapters))
    end)

    it("does not track truthy non-widget route results", function()
        local plugin = build_plugin()
        local library = { name = "library" }

        plugin:trackSuwayomiScreen("library", library)
        assert.is_nil(plugin:trackSuwayomiScreen("library", true))

        plugin:closeSuwayomiPlugin()

        assert.are.same({ library }, runtime.closed_widgets)
    end)

    it("configures API debug logging and plugin read-sync defaults on init", function()
        local plugin = build_plugin({
            ui = {
                menu = {
                    registerToMainMenu = function() end,
                },
            },
        })

        plugin:init()

        assert.is_function(runtime.api_debug_logger)
        assert.are.equal(50, plugin.read_sync_batch_size)
        assert.are.equal(5, plugin.finished_cleanup_retry_delay_seconds)
        assert.are.equal(300, plugin.finished_cleanup_max_retry_delay_seconds)
        assert.are.equal(25, plugin.finished_cleanup_batch_size)
        assert.are.equal("plugin_init", runtime.debug_events[1].operation)
        assert.are.equal("start", runtime.debug_events[1].event)
        assert.are.equal("plugin_init", runtime.debug_events[2].operation)
        assert.are.equal("end", runtime.debug_events[2].event)
    end)

    it("installs controller methods onto the KOReader plugin shell", function()
        local plugin_class = require("main")
        local controllers = {
            require("suwayomi/plugin/home"),
            require("suwayomi/plugin/title_menu"),
            require("suwayomi/plugin/settings_controller"),
            require("suwayomi/reader_return"),
            require("suwayomi/browse/controller"),
            require("suwayomi/downloads/directory"),
            require("suwayomi/manga/controller"),
            require("suwayomi/chapters/context"),
            require("suwayomi/chapters/menu"),
            require("suwayomi/chapters/actions"),

            require("suwayomi/downloads/controller"),
            require("suwayomi/readsync/ledger"),
            require("suwayomi/readsync/koreader_metadata"),
            require("suwayomi/readsync/controller"),
        }

        for _, controller in ipairs(controllers) do
            for method_name, method in pairs(controller.methods or {}) do
                assert.are.equal(method, plugin_class[method_name])
            end
        end
    end)

    it("delegates main-menu actions through installed controller methods", function()
        local plugin = build_plugin({
            showLibrary = function(self)
                self.delegated_action = "library"
            end,
        })

        plugin:showHome()
        runtime.shown_home_dialog.actions[1].callback()

        assert.are.equal("library", plugin.delegated_action)
    end)

    it("routes the Close plugin home action through the navigation closer", function()
        local plugin = build_plugin({
            closeSuwayomiPlugin = function(self)
                self.closed_plugin = true
            end,
        })

        plugin:showHome()
        runtime.shown_home_dialog.actions[6].callback()

        assert.is_true(plugin.closed_plugin)
    end)

    it("tracks Suwayomi home so Close plugin closes home and the active plugin screen", function()
        local plugin = build_plugin()
        local library = { name = "library" }

        plugin:trackSuwayomiScreen("library", library)
        plugin:showHome()

        assert.is_true(plugin:isSuwayomiScreenActive(runtime.shown_home_dialog))
        assert.is_false(runtime.shown_home_dialog.actions[6].close_before_select)

        runtime.shown_home_dialog.actions[6].callback()

        assert.are.same({ runtime.shown_home_dialog, library }, runtime.closed_widgets)
        assert.is_false(plugin:isSuwayomiScreenActive(runtime.shown_home_dialog))
        assert.is_false(plugin:isSuwayomiScreenActive(library))
    end)

    it("closes a source filter branch when Close plugin is selected from home", function()
        local plugin = build_plugin()
        local sources = { name = "sources" }
        local filter_editor = { name = "source-filters" }
        local saved_filters = { name = "saved-filters" }

        plugin:trackSuwayomiScreen("browse-sources", sources)
        plugin:trackSuwayomiScreen("source-filters", filter_editor)
        plugin:trackSuwayomiScreen("saved-filters", saved_filters)
        plugin:showHome()

        runtime.shown_home_dialog.actions[6].callback()

        assert.are.same({ runtime.shown_home_dialog, saved_filters, filter_editor, sources }, runtime.closed_widgets)
        assert.is_false(plugin:isSuwayomiScreenActive(runtime.shown_home_dialog))
        assert.is_false(plugin:isSuwayomiScreenActive(saved_filters))
        assert.is_false(plugin:isSuwayomiScreenActive(filter_editor))
        assert.is_false(plugin:isSuwayomiScreenActive(sources))
    end)

    it("closes the source menu after source row selection fires its close callback", function()
        local plugin = build_plugin()
        local source_close_calls = 0
        local sources = {
            name = "sources",
            close_callback = function()
                source_close_calls = source_close_calls + 1
            end,
        }
        local filter_editor = { name = "source-filters" }
        local browse_results = { name = "browse-results" }

        plugin:trackSuwayomiScreen("browse-sources", sources)
        sources.close_callback()
        plugin:trackSuwayomiScreen("source-filters", filter_editor)
        plugin:trackSuwayomiScreen("browse-results", browse_results)
        plugin:showHome()

        runtime.shown_home_dialog.actions[6].callback()

        assert.are.same({ runtime.shown_home_dialog, browse_results, filter_editor, sources }, runtime.closed_widgets)
        assert.are.equal(2, source_close_calls)
        assert.is_false(plugin:isSuwayomiScreenActive(runtime.shown_home_dialog))
        assert.is_false(plugin:isSuwayomiScreenActive(browse_results))
        assert.is_false(plugin:isSuwayomiScreenActive(filter_editor))
        assert.is_false(plugin:isSuwayomiScreenActive(sources))
    end)

    it("preserves previous screens when navigating from the hub", function()
        local library = { name = "library" }
        local browse = { name = "browse" }
        local plugin = build_plugin({
            showLibrary = function()
                return library
            end,
        })

        plugin:trackSuwayomiScreen("browse", browse)
        plugin:showHome()
        runtime.shown_home_dialog.onClose()
        runtime.shown_home_dialog.actions[1].callback()

        assert.are.same({}, runtime.closed_widgets)
        assert.is_true(plugin:isSuwayomiScreenActive(browse))
        assert.is_true(plugin:isSuwayomiScreenActive(library))
    end)

    it("untracks Suwayomi home when a normal home action closes the dialog", function()
        local plugin = build_plugin()

        plugin:showHome()
        assert.is_true(plugin:isSuwayomiScreenActive(runtime.shown_home_dialog))

        runtime.shown_home_dialog.onClose()

        assert.is_false(plugin:isSuwayomiScreenActive(runtime.shown_home_dialog))
    end)
end)
