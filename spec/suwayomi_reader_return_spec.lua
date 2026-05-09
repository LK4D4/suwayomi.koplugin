package.path = "?.lua;" .. package.path

local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/reader_return", function()
    local state

    local function reset_modules()
        for _, name in ipairs({
            "suwayomi/reader_return",
            "suwayomi/settings",
            "suwayomi/api",
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
        package.preload["ui/uimanager"] = function()
            return {
                nextTick = function(_, callback)
                    if callback then
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
            withLoadingMessage = function(_, _, _, callback)
                table.insert(state.events, "loading")
                return callback()
            end,
            showMessage = function(self, message)
                table.insert(self.messages, message)
            end,
            showChapterResultForManga = function(_, manga, result)
                table.insert(state.events, "show-chapters")
                state.shown_manga = manga
                state.shown_result = result
                return true
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
            "getCurrentReaderReturnContext",
            "returnToSuwayomiChapters",
        })
    end)

    it("saves return context keyed by local chapter path", function()
        local plugin = build_plugin()

        plugin:saveReaderReturnContext(
            { id = "m1", title = "Manga", source = { id = "local", name = "Local source" } },
            { id = "c1", name = "Chapter 1" },
            "/downloads/Local/Manga/Chapter 1.cbz"
        )

        assert.are.same({
            path = "/downloads/Local/Manga/Chapter 1.cbz",
            manga_id = "m1",
            manga_title = "Manga",
            chapter_id = "c1",
            chapter_name = "Chapter 1",
            source = { id = "local", name = "Local source" },
        }, state.contexts["/downloads/Local/Manga/Chapter 1.cbz"])
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

    it("fetches chapters before closing reader and restores the chapter list", function()
        local plugin = build_plugin({
            contexts = {
                ["/downloads/Local/Manga/Chapter 1.cbz"] = {
                    path = "/downloads/Local/Manga/Chapter 1.cbz",
                    manga_id = "m1",
                    manga_title = "Manga",
                    chapter_id = "c1",
                    chapter_name = "Chapter 1",
                    source = { id = "local", name = "Local source" },
                },
            },
        })

        assert.is_true(plugin:returnToSuwayomiChapters())

        assert.are.same({
            "loading",
            "fetch",
            "close-reader",
            "reinit-filemanager",
            "show-chapters",
        }, state.events)
        assert.are.same({ "m1" }, state.fetched_manga_ids)
        assert.are.equal("m1", state.shown_manga.id)
        assert.are.equal("Manga", state.shown_manga.title)
        assert.are.same({ id = "local", name = "Local source" }, state.shown_manga.source)
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

        assert.is_false(plugin:returnToSuwayomiChapters())

        assert.are.same({ "loading", "fetch" }, state.events)
        assert.are.same({ "Network unavailable." }, plugin.messages)
    end)
end)
