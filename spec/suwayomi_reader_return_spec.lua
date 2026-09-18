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
            server_url = "https://suwayomi.example",
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
                    return { server_url = state.server_url }
                end,
                normalizeEndpointScope = function(_, url) return url end,
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
        package.preload["suwayomi/network/request_job"] = function()
            return {
                start = function()
                    error("reader return must not wait for a network request")
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
                        state.reader_plugin.suwayomi_host_retired = true
                        state.reader_plugin:cancelReaderReturnRequest()
                        require("apps/reader/readerui").instance = nil
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
            showChaptersForManga = function()
                error("reader return must publish through the live FileManager host")
            end,
            showMessage = function(self, message)
                table.insert(self.messages, message)
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
        local reader = require("apps/reader/readerui").instance
        reader.document = plugin.ui.document
        plugin.ui = reader
        state.reader_plugin = plugin
        local filemanager = require("apps/filemanager/filemanager").instance
        filemanager.suwayomi = {
            ui = filemanager,
            showChaptersForManga = function(destination, manga, show_options)
                table.insert(state.events, "show-chapters")
                state.shown_destination = destination
                state.shown_manga = manga
                state.shown_options = show_options
                return true
            end,
        }
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
            "cancelReaderReturnRequest",
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

    it("preserves library state from exact chapter ledger path entries", function()
        local plugin = build_plugin({
            contexts = {},
            ledger = {
                ["m1:c1"] = {
                    path = "/downloads/Local/Manga/Chapter 1.cbz",
                    manga_id = "m1",
                    manga_title = "Manga",
                    in_library = true,
                    chapter_id = "c1",
                    chapter_name = "Chapter 1",
                },
            },
        })

        local context = plugin:getCurrentReaderReturnContext()

        assert.are.equal("m1", context.manga_id)
        assert.is_true(context.in_library)
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

    it("retains recorded order and descriptive metadata across saved-context refresh", function()
        local path = "/downloads/Local/Manga/Chapter 1.cbz"
        local plugin = build_plugin()
        plugin:saveReaderReturnContext({
            id = "m1", title = "Manga", thumbnail_url = "/cover",
            endpoint_scope = "https://suwayomi.example",
        }, {
            id = "c1", name = "Chapter 1", source_order = 4, chapter_number = 1, scanlator = "Group",
        }, path)
        plugin:saveReaderReturnContextsForChapters({
            id = "m1", title = "Manga", thumbnail_url = "/cover",
        }, {
            { path = path, chapter = {
                id = "c1", name = "Chapter 1", source_order = 5, chapter_number = 1, scanlator = "Group",
            } },
        })

        local context = plugin:getCurrentReaderReturnContext()
        assert.are.equal(5, context.source_order)
        assert.are.equal(1, context.chapter_number)
        assert.are.equal("Group", context.scanlator)
        assert.are.equal("/cover", context.thumbnail_url)
        assert.are.equal("https://suwayomi.example", context.endpoint_scope)
    end)

    it("preserves a sibling's recorded server scope without inventing chapter identity", function()
        local plugin = build_plugin({
            document_path = "/downloads/Local/Manga/Chapter 2.cbz",
            contexts = {
                ["/downloads/Local/Manga/Chapter 1.cbz"] = {
                    path = "/downloads/Local/Manga/Chapter 1.cbz",
                    manga_id = "m1", manga_title = "Manga",
                    endpoint_scope = "https://other.example",
                },
            },
        })

        local context = plugin:getCurrentReaderReturnContext()
        assert.are.equal("https://other.example", context.endpoint_scope)
        assert.is_nil(context.chapter_id)
        assert.is_false(plugin:returnToSuwayomiChapters())
        assert.are.same({}, state.events)
    end)

    it("does not infer identity from same-ID siblings recorded on different servers", function()
        local plugin = build_plugin({
            document_path = "/downloads/Local/Manga/Chapter 3.cbz",
            contexts = {
                first = {
                    path = "/downloads/Local/Manga/Chapter 1.cbz",
                    manga_id = "m1", endpoint_scope = "https://suwayomi.example",
                },
                second = {
                    path = "/downloads/Local/Manga/Chapter 2.cbz",
                    manga_id = "m1", endpoint_scope = "https://other.example",
                },
            },
        })

        assert.is_nil(plugin:getCurrentReaderReturnContext())
    end)

    local function linked_reader(options)
        options = options or {}
        local path = "/downloads/Local/Manga/Chapter 1.cbz"
        options.contexts = {
            [path] = {
                path = path,
                manga_id = "m1",
                manga_title = "Manga",
                in_library = true,
                chapter_id = "c1",
                chapter_name = "Chapter 1",
                source = { id = "local", name = "Local source" },
                endpoint_scope = "https://suwayomi.example",
            },
        }
        return build_plugin(options)
    end

    it("closes normally and immediately restores chapters on the live FileManager host", function()
        local plugin = linked_reader()

        assert.is_true(plugin:returnToSuwayomiChapters())

        assert.are.same({ "close-reader", "reinit-filemanager", "show-chapters" }, state.events)
        assert.is_true(plugin.suwayomi_host_retired)
        assert.are.equal(require("apps/filemanager/filemanager").instance.suwayomi, state.shown_destination)
        assert.are.equal("m1", state.shown_manga.id)
        assert.are.equal("Manga", state.shown_manga.title)
        assert.are.equal("https://suwayomi.example", state.shown_manga.endpoint_scope)
        assert.is_nil(state.shown_manga.local_only)
        assert.are.equal("c1", state.shown_options.return_context.chapter_id)
        assert.are.equal("Chapter 1", state.shown_options.return_context.chapter_name)
        assert.are.equal("library", state.shown_options.reader_return_close_target.kind)
    end)

    it("preserves the existing cleanup schedule before normal reader close", function()
        local plugin = linked_reader()
        plugin.scheduleFinishedChapterCleanup = function(_, delay_seconds)
            table.insert(state.events, "cleanup-schedule:" .. tostring(delay_seconds))
        end

        assert.is_true(plugin:returnToSuwayomiChapters())

        assert.are.same({
            "cleanup-schedule:0", "close-reader", "reinit-filemanager", "show-chapters",
        }, state.events)
    end)

    it("returns legacy context for local reconstruction without assigning a server", function()
        local plugin = linked_reader()
        local context = plugin:getCurrentReaderReturnContext()
        context.endpoint_scope = nil
        context.in_library = false

        assert.is_true(plugin:returnToSuwayomiChapters())

        assert.is_true(state.shown_manga.local_only)
        assert.is_nil(state.shown_manga.endpoint_scope)
        assert.is_nil(state.shown_options.return_context.endpoint_scope)
        assert.are.equal("c1", state.shown_options.return_context.chapter_id)
    end)

    it("returns an unassociated recorded path even without manga or chapter IDs", function()
        local plugin = linked_reader()
        local context = plugin:getCurrentReaderReturnContext()
        context.endpoint_scope = nil
        context.manga_id = nil
        context.chapter_id = nil

        assert.is_true(plugin:returnToSuwayomiChapters())

        assert.is_true(state.shown_manga.local_only)
        assert.is_nil(state.shown_manga.id)
        assert.are.equal("/downloads/Local/Manga", state.shown_manga.local_manga_path)
        assert.are.equal(context.path, state.shown_options.return_context.path)
    end)

    it("returns a current-scoped recorded file without manga IDs as local-only", function()
        local plugin = linked_reader()
        local context = plugin:getCurrentReaderReturnContext()
        context.manga_id, context.chapter_id = nil, nil

        assert.is_true(plugin:returnToSuwayomiChapters())

        assert.is_true(state.shown_manga.local_only)
        assert.is_nil(state.shown_manga.id)
        assert.are.equal("/downloads/Local/Manga", state.shown_manga.local_manga_path)
        assert.are.equal(context.endpoint_scope, state.shown_manga.endpoint_scope)
        assert.are.same({ "close-reader", "reinit-filemanager", "show-chapters" }, state.events)
    end)

    it("does not return a known foreign manga through a colliding configured-server ID", function()
        local plugin = linked_reader()
        plugin:getCurrentReaderReturnContext().endpoint_scope = "https://other.example"

        assert.is_false(plugin:returnToSuwayomiChapters())

        assert.are.same({}, state.events)
        assert.is_nil(state.shown_manga)
    end)

    it("ignores a deferred return after the reader document changes", function()
        local plugin = linked_reader({ defer_next_tick = true })
        assert.is_true(plugin:returnToSuwayomiChapters())

        plugin.ui.document.file = "/downloads/Local/Manga/Chapter 2.cbz"
        state.next_tick_callback()

        assert.are.same({}, state.events)
        assert.is_nil(state.shown_manga)
    end)

    it("does not close a replacement reader even when it opens the same path", function()
        local plugin = linked_reader({ defer_next_tick = true })
        assert.is_true(plugin:returnToSuwayomiChapters())
        require("apps/reader/readerui").instance = {
            document = { file = plugin.ui.document.file },
            onClose = function() error("must not close the replacement reader") end,
        }
        state.next_tick_callback()

        assert.are.same({}, state.events)
        assert.is_nil(state.shown_manga)
    end)

    it("ignores a deferred return after its saved context changes in place", function()
        local plugin = linked_reader({ defer_next_tick = true })
        assert.is_true(plugin:returnToSuwayomiChapters())

        plugin:getCurrentReaderReturnContext().manga_id = "m2"
        state.next_tick_callback()

        assert.are.same({}, state.events)
        assert.is_nil(state.shown_manga)
    end)

    it("cancels deferred return without closing the reader", function()
        local plugin = linked_reader({ defer_next_tick = true })
        assert.is_true(plugin:returnToSuwayomiChapters())
        assert.is_true(plugin:cancelReaderReturnRequest())
        state.next_tick_callback()

        assert.are.same({}, state.events)
        assert.is_nil(state.shown_manga)
    end)

    it("ignores deferred return after reader host retirement", function()
        local plugin = linked_reader({ defer_next_tick = true })
        assert.is_true(plugin:returnToSuwayomiChapters())
        plugin.suwayomi_host_retired = true
        state.next_tick_callback()

        assert.are.same({}, state.events)
        assert.is_nil(state.shown_manga)
    end)

    it("rejects return from an already retired reader host", function()
        local plugin = linked_reader()
        plugin.suwayomi_host_retired = true

        assert.is_false(plugin:returnToSuwayomiChapters())
        assert.are.same({}, state.events)
    end)

    it("keeps the reader open if configured server changes before deferred close", function()
        local plugin = linked_reader({ defer_next_tick = true })
        assert.is_true(plugin:returnToSuwayomiChapters())
        state.server_url = "https://other.example"
        state.next_tick_callback()

        assert.are.same({}, state.events)
        assert.is_nil(state.shown_manga)
    end)

    it("does not publish if the configured server changes during reader teardown", function()
        local plugin = linked_reader()
        require("apps/filemanager/filemanager").instance.reinit = function()
            state.server_url = "https://other.example"
        end

        assert.is_true(plugin:returnToSuwayomiChapters())

        assert.are.same({ "close-reader" }, state.events)
        assert.is_nil(state.shown_manga)
    end)

    it("does not publish if saved identity changes during reader teardown", function()
        local plugin = linked_reader()
        local context = plugin:getCurrentReaderReturnContext()
        require("apps/filemanager/filemanager").instance.reinit = function()
            context.endpoint_scope = "https://other.example"
        end

        assert.is_true(plugin:returnToSuwayomiChapters())

        assert.are.same({ "close-reader" }, state.events)
        assert.is_nil(state.shown_manga)
    end)

    it("publishes through the replacement FileManager plugin created by reinit", function()
        local plugin = linked_reader()
        local filemanager = require("apps/filemanager/filemanager").instance
        local old_destination = filemanager.suwayomi
        local replacement = {
            ui = filemanager,
            showChaptersForManga = old_destination.showChaptersForManga,
        }
        filemanager.reinit = function()
            old_destination.suwayomi_host_retired = true
            filemanager.suwayomi = replacement
        end

        assert.is_true(plugin:returnToSuwayomiChapters())

        assert.are.equal(replacement, state.shown_destination)
    end)

    it("does not publish through a retired FileManager destination", function()
        local plugin = linked_reader()
        require("apps/filemanager/filemanager").instance.suwayomi.suwayomi_host_retired = true

        assert.is_true(plugin:returnToSuwayomiChapters())

        assert.are.same({ "close-reader", "reinit-filemanager" }, state.events)
        assert.is_nil(state.shown_manga)
    end)

    it("does not publish through a plugin attached to a different FileManager", function()
        local plugin = linked_reader()
        require("apps/filemanager/filemanager").instance.suwayomi.ui = {}

        assert.is_true(plugin:returnToSuwayomiChapters())

        assert.are.same({ "close-reader", "reinit-filemanager" }, state.events)
        assert.is_nil(state.shown_manga)
    end)
end)
