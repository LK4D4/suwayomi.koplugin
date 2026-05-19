package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/reader_return", function()
    local state

    local function reset_modules()
        for _, name in ipairs({
            "suwayomi/reader_return",
            "suwayomi/settings",
            "suwayomi/api",
            "suwayomi/network/request_job",
            "ui/uimanager",
            "apps/reader/readerui",
            "apps/filemanager/filemanager",
            "gettext",
        }) do
            package.loaded[name] = nil
            package.preload[name] = nil
        end
    end

    local function install_stubs(options)
        options = options or {}
        helper.stubControllerDependencies()
        reset_modules()
        state = {
            contexts = options.contexts or {},
            ledger = options.ledger or {},
            events = {},
            fetched_manga_ids = {},
            network_requests = {},
            canceled_requests = {},
            messages = {},
        }

        package.preload.gettext = function()
            return function(text)
                return text
            end
        end
        package.preload["suwayomi/settings"] = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example" }
                end,
                loadReaderReturnContexts = function()
                    return state.contexts
                end,
                saveReaderReturnContexts = function(_, contexts)
                    state.contexts = contexts
                    table.insert(state.events, "save-contexts")
                    return contexts
                end,
                loadChapterLedger = function()
                    return state.ledger
                end,
            }
        end
        package.preload["suwayomi/api"] = function()
            return {
                fetchChaptersForManga = function(_, manga_id)
                    table.insert(state.events, "fetch")
                    table.insert(state.fetched_manga_ids, manga_id)
                    return options.fetch_result or {
                        ok = true,
                        chapters = {
                            { id = "c1", name = "Chapter 1" },
                        },
                    }
                end,
            }
        end
        package.preload["suwayomi/network/request_job"] = function()
            return {
                cancel = function(active)
                    table.insert(state.canceled_requests, active)
                    active.canceled = true
                    if active.on_cancel then
                        active.on_cancel()
                    end
                end,
                start = function(request_options)
                    table.insert(state.network_requests, request_options)
                    table.insert(state.events, "network-request")
                    local active = {
                        pid = 2468,
                        on_cancel = request_options.on_cancel,
                    }
                    if options.defer_network_finish then
                        return active
                    end
                    if request_options.on_finish then
                        request_options.on_finish(options.fetch_result or {
                            ok = true,
                            chapters = {
                                { id = "c1", name = "Chapter 1" },
                            },
                        })
                    end
                    return active
                end,
            }
        end
        package.preload["ui/uimanager"] = function()
            return {
                nextTick = function(_, callback)
                    if options.defer_next_tick then
                        state.next_tick_callback = callback
                    elseif callback then
                        callback()
                    end
                end,
            }
        end
        package.preload["apps/reader/readerui"] = function()
            return {
                instance = {
                    onClose = function()
                        table.insert(state.events, "close-reader")
                    end,
                },
            }
        end
        package.preload["apps/filemanager/filemanager"] = function()
            return {
                instance = {
                    reinit = function()
                        table.insert(state.events, "reinit-filemanager")
                    end,
                },
                showFiles = function()
                    table.insert(state.events, "show-filemanager")
                end,
            }
        end
    end

    local function build_plugin(options)
        options = options or {}
        install_stubs(options)
        local ReaderReturn = require("suwayomi/reader_return")
        local plugin = {
            ui = {
                document = {
                    file = options.document_path or "/downloads/Local/Manga/Chapter 1.cbz",
                },
            },
            messages = state.messages,
            withLoadingMessage = function()
                error("reader return should not block the UI thread")
            end,
            showLoadingMessage = function(_, message)
                table.insert(state.events, "loading:" .. message)
                return { message = message }
            end,
            closeLoadingMessage = function(_, loading_message)
                table.insert(state.events, "close-loading:" .. tostring(loading_message and loading_message.message))
            end,
            showMessage = function(self, message)
                table.insert(self.messages, message)
            end,
            showChapterResultForManga = function(_, manga, result, show_options)
                table.insert(state.events, "show-chapters")
                state.shown_manga = manga
                state.shown_result = result
                state.shown_options = show_options
                return true
            end,
            buildReaderReturnCloseTarget = function(_, _, manga)
                if manga and manga.in_library == true then
                    return { kind = "library" }
                end
                if manga and manga.source and manga.source.id then
                    return { kind = "source", source = manga.source }
                end
                return nil
            end,
        }
        for name, method in pairs(ReaderReturn.methods) do
            plugin[name] = method
        end
        return plugin
    end

    after_each(function()
        reset_modules()
    end)

    it("exports reader return methods", function()
        helper.assertControllerModule("suwayomi/reader_return", {
            "saveReaderReturnContext",
            "saveReaderReturnContextsForChapters",
            "getCurrentReaderReturnContext",
            "returnToSuwayomiChapters",
        })
    end)

    it("saves return context keyed by local chapter path", function()
        local plugin = build_plugin()

        plugin:saveReaderReturnContext(
            { id = "m1", title = "Fable Orbit", in_library = true, source = { id = "local", name = "Local source" } },
            { id = "c1", name = "Chapter 1" },
            "/downloads/Local/Fable Orbit/Chapter 1.cbz"
        )

        assert.are.same({
            path = "/downloads/Local/Fable Orbit/Chapter 1.cbz",
            manga_id = "m1",
            manga_title = "Fable Orbit",
            in_library = true,
            chapter_id = "c1",
            chapter_name = "Chapter 1",
            source = { id = "local", name = "Local source" },
        }, state.contexts["/downloads/Local/Fable Orbit/Chapter 1.cbz"])
    end)

    it("replaces scalar persisted contexts when saving a return context", function()
        local plugin = build_plugin({
            contexts = "not-a-table",
        })

        assert.has_no.errors(function()
            plugin:saveReaderReturnContext(
                { id = "m1", title = "Manga", source = { id = "local", name = "Local source" } },
                { id = "c1", name = "Chapter 1" },
                "/downloads/Local/Manga/Chapter 1.cbz"
            )
        end)

        assert.are.equal("c1", state.contexts["/downloads/Local/Manga/Chapter 1.cbz"].chapter_id)
    end)

    it("saves return contexts for downloaded chapter paths in one settings write", function()
        local plugin = build_plugin()

        plugin:saveReaderReturnContextsForChapters({
            id = "m1",
            title = "Manga",
            source = { id = "local", name = "Local source" },
        }, {
            {
                chapter = { id = "c1", name = "Chapter 1" },
                path = "/downloads/Local/Manga/Chapter 1.cbz",
            },
            {
                chapter = { id = "c2", name = "Chapter 2" },
                path = "/downloads/Local/Manga/Chapter 2.cbz",
            },
        })

        assert.are.same({ "save-contexts" }, state.events)
        assert.are.equal("c1", state.contexts["/downloads/Local/Manga/Chapter 1.cbz"].chapter_id)
        assert.are.equal("c2", state.contexts["/downloads/Local/Manga/Chapter 2.cbz"].chapter_id)
        assert.are.same(
            { id = "local", name = "Local source" },
            state.contexts["/downloads/Local/Manga/Chapter 2.cbz"].source
        )
    end)

    it("updates saved return contexts when library membership changes", function()
        local plugin = build_plugin({
            contexts = {
                ["/downloads/Local/Paper Comet/Chapter 1.cbz"] = {
                    path = "/downloads/Local/Paper Comet/Chapter 1.cbz",
                    manga_id = "m1",
                    manga_title = "Paper Comet",
                    chapter_id = "c1",
                    chapter_name = "Chapter 1",
                    source = { id = "local", name = "Local source" },
                },
            },
        })

        plugin:saveReaderReturnContextsForChapters({
            id = "m1",
            title = "Paper Comet",
            in_library = true,
            source = { id = "local", name = "Local source" },
        }, {
            {
                chapter = { id = "c1", name = "Chapter 1" },
                path = "/downloads/Local/Paper Comet/Chapter 1.cbz",
            },
        })

        assert.are.same({ "save-contexts" }, state.events)
        assert.is_true(state.contexts["/downloads/Local/Paper Comet/Chapter 1.cbz"].in_library)
    end)

    it("finds current reader context from persisted contexts", function()
        local plugin = build_plugin({
            contexts = {
                ["/downloads/Local/Manga/Chapter 1.cbz"] = {
                    path = "/downloads/Local/Manga/Chapter 1.cbz",
                    manga_id = "m1",
                    manga_title = "Manga",
                    chapter_id = "c1",
                    chapter_name = "Chapter 1",
                },
            },
        })

        local context = plugin:getCurrentReaderReturnContext()

        assert.are.equal("m1", context.manga_id)
        assert.are.equal("Chapter 1", context.chapter_name)
    end)

    it("finds current reader context from KOReader switched document path fields", function()
        local plugin = build_plugin({
            contexts = {
                ["/downloads/Local/Manga/Chapter 1.cbz"] = {
                    path = "/downloads/Local/Manga/Chapter 1.cbz",
                    manga_id = "m1",
                    manga_title = "Manga",
                },
            },
        })
        plugin.ui.document = nil
        plugin.ui.document_path = "/downloads/Local/Manga/Chapter 1.cbz"

        local context = plugin:getCurrentReaderReturnContext()

        assert.are.equal("m1", context.manga_id)
    end)

    it("falls back to chapter ledger path entries", function()
        local plugin = build_plugin({
            contexts = {},
            ledger = {
                ["m1:c1"] = {
                    path = "/downloads/Local/Manga/Chapter 1.cbz",
                    manga_id = "m1",
                    manga_title = "Manga",
                    chapter_id = "c1",
                    chapter_name = "Chapter 1",
                },
            },
        })

        local context = plugin:getCurrentReaderReturnContext()

        assert.are.equal("m1", context.manga_id)
        assert.are.equal("/downloads/Local/Manga/Chapter 1.cbz", context.path)
    end)

    it("infers the current reader context from linked sibling chapter files", function()
        local plugin = build_plugin({
            document_path = "/downloads/Local/Manga/Chapter 2.cbz",
            contexts = {
                ["/downloads/Local/Manga/Chapter 1.cbz"] = {
                    path = "/downloads/Local/Manga/Chapter 1.cbz",
                    manga_id = "m1",
                    manga_title = "Manga",
                    in_library = true,
                    source = { id = "local", name = "Local source" },
                },
            },
        })

        local context = plugin:getCurrentReaderReturnContext()

        assert.are.equal("m1", context.manga_id)
        assert.are.equal("Manga", context.manga_title)
        assert.are.equal("/downloads/Local/Manga/Chapter 2.cbz", context.path)
        assert.is_true(context.in_library)
        assert.is_nil(context.chapter_id)
        assert.are.same({ id = "local", name = "Local source" }, context.source)
    end)

    it("does not infer sibling context from ambiguous manga folders", function()
        local plugin = build_plugin({
            document_path = "/downloads/Local/Manga/Chapter 3.cbz",
            contexts = {
                ["/downloads/Local/Manga/Chapter 1.cbz"] = {
                    path = "/downloads/Local/Manga/Chapter 1.cbz",
                    manga_id = "m1",
                    manga_title = "Manga",
                },
                ["/downloads/Local/Manga/Chapter 2.cbz"] = {
                    path = "/downloads/Local/Manga/Chapter 2.cbz",
                    manga_id = "m2",
                    manga_title = "Other Manga",
                },
            },
        })

        assert.is_nil(plugin:getCurrentReaderReturnContext())
    end)

    it("fetches chapters asynchronously before closing reader and restores the chapter list", function()
        local plugin = build_plugin({
            contexts = {
                ["/downloads/Local/Manga/Chapter 1.cbz"] = {
                    path = "/downloads/Local/Manga/Chapter 1.cbz",
                    manga_id = "m1",
                    manga_title = "Manga",
                    in_library = true,
                    chapter_id = "c1",
                    chapter_name = "Chapter 1",
                    source = { id = "local", name = "Local source" },
                },
            },
        })

        assert.is_true(plugin:returnToSuwayomiChapters())

        assert.are.same({
            "network-request",
            "close-reader",
            "reinit-filemanager",
            "show-chapters",
        }, state.events)
        assert.are.equal("fetch_chapters_for_manga", state.network_requests[1].request.action)
        assert.are.equal("m1", state.network_requests[1].request.manga_id)
        assert.are.same({}, state.fetched_manga_ids)
        assert.are.equal("m1", state.shown_manga.id)
        assert.are.equal("Manga", state.shown_manga.title)
        assert.is_true(state.shown_manga.in_library)
        assert.are.same({ id = "local", name = "Local source" }, state.shown_manga.source)
        assert.are.equal("c1", state.shown_options.return_context.chapter_id)
        assert.are.equal("Chapter 1", state.shown_options.return_context.chapter_name)
        assert.is_table(state.shown_options.reader_return_close_target)
        assert.are.equal("library", state.shown_options.reader_return_close_target.kind)
    end)

    it("keeps reader open when chapter lookup fails", function()
        local plugin = build_plugin({
            contexts = {
                ["/downloads/Local/Manga/Chapter 1.cbz"] = {
                    path = "/downloads/Local/Manga/Chapter 1.cbz",
                    manga_id = "m1",
                    manga_title = "Manga",
                },
            },
            fetch_result = {
                ok = false,
                error = "Network unavailable.",
            },
        })

        assert.is_true(plugin:returnToSuwayomiChapters())

        assert.are.same({ "network-request" }, state.events)
        assert.are.equal("fetch_chapters_for_manga", state.network_requests[1].request.action)
        assert.are.same({}, state.fetched_manga_ids)
        assert.are.same({ "Network unavailable." }, plugin.messages)
    end)

    it("ignores stale reader-return results after the reader document changes", function()
        local plugin = build_plugin({
            defer_network_finish = true,
            contexts = {
                ["/downloads/Local/Manga/Chapter 1.cbz"] = {
                    path = "/downloads/Local/Manga/Chapter 1.cbz",
                    manga_id = "m1",
                    manga_title = "Manga",
                    chapter_id = "c1",
                    chapter_name = "Chapter 1",
                },
                ["/downloads/Local/Manga/Chapter 2.cbz"] = {
                    path = "/downloads/Local/Manga/Chapter 2.cbz",
                    manga_id = "m2",
                    manga_title = "Other Manga",
                    chapter_id = "c2",
                    chapter_name = "Chapter 2",
                },
            },
        })

        assert.is_true(plugin:returnToSuwayomiChapters())
        plugin.ui.document.file = "/downloads/Local/Manga/Chapter 2.cbz"
        state.network_requests[1].on_finish({
            ok = true,
            chapters = {
                { id = "c1", name = "Chapter 1" },
            },
        })

        assert.are.same({ "network-request" }, state.events)
        assert.is_nil(state.shown_manga)
    end)

    it("ignores stale reader-return results when context changes before deferred close", function()
        local plugin = build_plugin({
            defer_network_finish = true,
            defer_next_tick = true,
            contexts = {
                ["/downloads/Local/Manga/Chapter 1.cbz"] = {
                    path = "/downloads/Local/Manga/Chapter 1.cbz",
                    manga_id = "m1",
                    manga_title = "Manga",
                    chapter_id = "c1",
                    chapter_name = "Chapter 1",
                },
                ["/downloads/Local/Manga/Chapter 2.cbz"] = {
                    path = "/downloads/Local/Manga/Chapter 2.cbz",
                    manga_id = "m2",
                    manga_title = "Other Manga",
                    chapter_id = "c2",
                    chapter_name = "Chapter 2",
                },
            },
        })

        assert.is_true(plugin:returnToSuwayomiChapters())
        state.network_requests[1].on_finish({
            ok = true,
            chapters = {
                { id = "c1", name = "Chapter 1" },
            },
        })
        plugin.ui.document.file = "/downloads/Local/Manga/Chapter 2.cbz"
        state.next_tick_callback()

        assert.are.same({ "network-request" }, state.events)
        assert.is_nil(state.shown_manga)
    end)
end)
