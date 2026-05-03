package.path = "?.lua;" .. package.path

describe("suwayomi plugin", function()
    local registered_actions
    local registered_menu_plugin
    local login_dialog_options
    local language_menu_options
    local shown_messages
    local shown_sources
    local directory_chooser_callback
    local saved_download_directory
    local trapper_wrapped
    local trapper_subprocess_calls
    local scheduled_callbacks
    local original_io_open
    local progress_files

    local function reset_plugin_environment()
        registered_actions = {}
        registered_menu_plugin = nil
        login_dialog_options = nil
        language_menu_options = nil
        shown_messages = {}
        shown_sources = nil
        directory_chooser_callback = nil
        saved_download_directory = nil
        trapper_wrapped = 0
        trapper_subprocess_calls = {}
        scheduled_callbacks = {}
        progress_files = {}
        original_io_open = original_io_open or io.open
        io.open = function(path, mode)
            if tostring(path):match("%.suwayomi_dl_progress_") then
                if mode == "w" then
                    local chunks = {}
                    return {
                        write = function(_, ...)
                            for _, value in ipairs({...}) do
                                table.insert(chunks, value)
                            end
                        end,
                        close = function()
                            progress_files[path] = table.concat(chunks)
                        end,
                    }
                end

                local content = progress_files[path]
                if not content then
                    return nil
                end
                local lines = {}
                for line in content:gmatch("([^\n]*)\n?") do
                    if line ~= "" then
                        table.insert(lines, line)
                    end
                end
                local index = 0
                return {
                    lines = function()
                        return function()
                            index = index + 1
                            return lines[index]
                        end
                    end,
                    close = function() end,
                }
            end
            return original_io_open(path, mode)
        end

        package.loaded.main = nil
        package.loaded.dispatcher = nil
        package.loaded["ffi/util"] = nil
        package.loaded.gettext = nil
        package.loaded["ui/trapper"] = nil
        package.loaded["ui/uimanager"] = nil
        package.loaded["ui/widget/infomessage"] = nil
        package.loaded["ui/widget/container/widgetcontainer"] = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_download_queue = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil
        package.loaded.lfs = nil

        package.preload.dispatcher = function()
            return {
                registerAction = function(_, name, definition)
                    table.insert(registered_actions, {
                        name = name,
                        definition = definition,
                    })
                end,
            }
        end

        package.preload.gettext = function()
            return function(text)
                return text
            end
        end

        package.preload["ffi/util"] = function()
            return {
                template = function(template_string, ...)
                    local result = template_string
                    local values = {...}
                    for index, value in ipairs(values) do
                        result = result:gsub("%%" .. index, tostring(value))
                    end
                    return result
                end,
                runInSubProcess = function(callback)
                    callback()
                    return 1234
                end,
                isSubProcessDone = function()
                    return true
                end,
            }
        end

        package.preload["ui/uimanager"] = function()
            return {
                show = function(_, widget)
                    table.insert(shown_messages, widget.text)
                end,
                nextTick = function(_, callback)
                    callback()
                end,
                scheduleIn = function(_, _, callback)
                    table.insert(scheduled_callbacks, callback)
                end,
                setDirty = function() end,
                forceRePaint = function() end,
            }
        end

        package.preload["ui/trapper"] = function()
            return {
                wrap = function(_, callback)
                    trapper_wrapped = trapper_wrapped + 1
                    return callback()
                end,
                dismissableRunInSubprocess = function(_, callback, message)
                    table.insert(trapper_subprocess_calls, message)
                    return true, callback()
                end,
            }
        end

        package.preload["ui/widget/infomessage"] = function()
            return {
                new = function(_, options)
                    return options
                end,
            }
        end

        package.preload["ui/widget/container/widgetcontainer"] = function()
            local WidgetContainer = {}

            function WidgetContainer:extend(definition)
                definition.__index = definition
                return setmetatable(definition, {
                    __index = self,
                    __call = function(class, instance)
                        instance = instance or {}
                        setmetatable(instance, class)
                        return instance
                    end,
                })
            end

            return WidgetContainer
        end

        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return {
                        ok = true,
                        sources = {
                            { id = "1", name = "MangaDex (EN)", lang = "en" },
                            { id = "2", name = "MangaDex (RU)", lang = "ru" },
                            { id = "3", name = "ComicK (DE)", lang = "de" },
                            { id = "4", name = "Local source", lang = "localsourcelang" },
                        },
                    }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                getPartialPath = function(_, chapter_path)
                    return chapter_path .. ".part"
                end,
                chapterExists = function()
                    return false
                end,
                downloadChapterWithProgress = function(self, _, download_directory, manga, chapter, progress_path)
                    self:writeProgress(progress_path, "downloaded", 1, 1, download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz")
                end,
                writeProgress = function(_, progress_path, state, current, total, path, error_message)
                    local handle = io.open(progress_path, "w")
                    if not handle then
                        return
                    end
                    handle:write("state=", tostring(state or ""), "\n")
                    handle:write("current=", tostring(current or 0), "\n")
                    handle:write("total=", tostring(total or 0), "\n")
                    handle:write("path=", tostring(path or ""), "\n")
                    if error_message then
                        handle:write("error=", tostring(error_message), "\n")
                    end
                    handle:close()
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showDirectoryChooser = function(callback)
                    directory_chooser_callback = callback
                end,
                showLoginDialog = function(options)
                    login_dialog_options = options
                end,
                showLanguageMenu = function(options)
                    language_menu_options = options
                end,
                showSourcesMenu = function(sources)
                    shown_sources = sources
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return {
                        server_url = "https://suwayomi.example",
                        username = "alice",
                        password = "secret",
                        auth_method = "basic_auth",
                        source_languages = { "en", "ru" },
                    }
                end,
                save = function(_, credentials)
                    login_dialog_options.saved_credentials = credentials
                    return credentials
                end,
                loadSourceLanguages = function()
                    return { "en", "ru" }
                end,
                saveSourceLanguages = function(_, languages)
                    return languages
                end,
                loadDownloadDirectory = function()
                    return ""
                end,
                saveDownloadDirectory = function(_, path)
                    saved_download_directory = path
                    return path
                end,
                loadDownloadQueue = function()
                    return {}
                end,
                saveDownloadQueue = function(_, jobs)
                    return jobs
                end,
                loadChapterLedger = function()
                    return {}
                end,
                saveChapterLedger = function(_, ledger)
                    return ledger
                end,
            }
        end
    end

    before_each(reset_plugin_environment)

    local function run_scheduled_callbacks()
        while #scheduled_callbacks > 0 do
            local callback = table.remove(scheduled_callbacks, 1)
            callback()
        end
    end

    after_each(function()
        package.preload.dispatcher = nil
        package.preload["ffi/util"] = nil
        package.preload.gettext = nil
        package.preload["ui/trapper"] = nil
        package.preload["ui/uimanager"] = nil
        package.preload["ui/widget/infomessage"] = nil
        package.preload["ui/widget/container/widgetcontainer"] = nil
        package.preload.suwayomi_api = nil
        package.preload.suwayomi_download_queue = nil
        package.preload.suwayomi_downloader = nil
        package.preload.suwayomi_ui = nil
        package.preload.suwayomi_settings = nil
        package.preload.lfs = nil
        if original_io_open then
            io.open = original_io_open
        end
    end)

    it("registers a dispatcher action and main-menu entry on init", function()
        local plugin_class = require("main")
        local plugin = plugin_class{
            ui = {
                menu = {
                    registerToMainMenu = function(_, instance)
                        registered_menu_plugin = instance
                    end,
                },
            },
        }

        plugin:init()

        assert.are.equal(plugin, registered_menu_plugin)
        assert.are.equal(1, #registered_actions)
        assert.are.equal("suwayomi_action", registered_actions[1].name)
        assert.are.equal("Suwayomi", registered_actions[1].definition.title)
    end)

    it("adds the plugin under the search menu section", function()
        local plugin_class = require("main")
        local menu_items = {}

        plugin_class:addToMainMenu(menu_items)

        assert.is_table(menu_items.suwayomi_dl)
        assert.are.equal("Suwayomi", menu_items.suwayomi_dl.text)
        assert.are.equal("search", menu_items.suwayomi_dl.sorting_hint)
        assert.are.equal(4, #menu_items.suwayomi_dl.sub_item_table)
    end)

    it("opens the login dialog with persisted credentials", function()
        local plugin_class = require("main")
        local menu_items = {}
        local plugin = plugin_class{}

        plugin:addToMainMenu(menu_items)
        menu_items.suwayomi_dl.sub_item_table[2].callback()

        assert.is_table(login_dialog_options)
        assert.are.equal("https://suwayomi.example", login_dialog_options.credentials.server_url)
        assert.are.equal("alice", login_dialog_options.credentials.username)
        assert.are.equal("secret", login_dialog_options.credentials.password)
        assert.are.equal("basic_auth", login_dialog_options.credentials.auth_method)
    end)

    it("formats the saved login message without crashing", function()
        local plugin_class = require("main")
        local menu_items = {}
        local plugin = plugin_class{}

        plugin:addToMainMenu(menu_items)
        menu_items.suwayomi_dl.sub_item_table[2].callback()

        login_dialog_options.onSave({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })

        assert.are.equal("Suwayomi login settings saved for https://suwayomi.example.", shown_messages[#shown_messages])
    end)

    it("loads sources and opens the sources menu when browse succeeds", function()
        local plugin_class = require("main")
        local menu_items = {}
        local plugin = plugin_class{}

        plugin:addToMainMenu(menu_items)
        menu_items.suwayomi_dl.sub_item_table[1].callback()

        assert.are.same({
            { id = "1", name = "MangaDex (EN)", lang = "en" },
            { id = "2", name = "MangaDex (RU)", lang = "ru" },
            { id = "4", name = "Local source", lang = "localsourcelang" },
        }, shown_sources)
    end)

    it("downloads a selected chapter and shows the saved folder", function()
        local downloader_called
        local shown_chapter_menu
        local fake_chapter_menu = {
            updateItems = function() end,
        }

        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "MangaDex", lang = "en" } } }
                end,
                fetchMangaForSource = function(_, source_id)
                    assert.are.equal("s1", source_id)
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function(_, manga_id)
                    assert.are.equal("m1", manga_id)
                    return {
                        ok = true,
                        chapters = {
                            { id = "398", name = "Official_Vol. 1 Ch. 1" },
                            { id = "399", name = "Ch. 2" },
                        },
                    }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title, download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function(_, path)
                    return path:match("Ch%. 2%.cbz$") ~= nil
                end,
                startChapterDownload = function(_, credentials, download_directory, manga, chapter)
                    downloader_called = {
                        credentials = credentials,
                        download_directory = download_directory,
                        manga = manga,
                        chapter = chapter,
                    }
                    return {
                        ok = true,
                        path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
                        total = 1,
                        job = {},
                    }
                end,
                downloadNextPage = function()
                    return { ok = true, done = true, current = 1, total = 1, path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz" }
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showSourcesMenu = function(sources, onSelect)
                    onSelect(sources[1])
                end,
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                end,
                showChapterMenu = function(options, onSelect)
                    shown_chapter_menu = options
                    onSelect(options.chapters[1])
                    return fake_chapter_menu
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadSourceLanguages = function() return { "en" } end,
                loadDownloadDirectory = function() return "/books" end,
                saveDownloadDirectory = function(_, path) return path end,
                save = function(_, value) return value end,
                saveSourceLanguages = function(_, value) return value end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}

        plugin:browseSuwayomi()
        run_scheduled_callbacks()

        assert.are.equal(0, trapper_wrapped)
        assert.are.equal(0, #trapper_subprocess_calls)
        assert.are.equal("/books", downloader_called.download_directory)
        assert.are.equal("Sousou no Frieren", downloader_called.manga.title)
        assert.are.equal("Official_Vol. 1 Ch. 1", downloader_called.chapter.name)
        assert.are.equal("Sousou no Frieren", shown_chapter_menu.title)
        assert.are.equal("Official_Vol. 1 Ch. 1  ↓", shown_chapter_menu.chapters[1].menu_text)
        assert.are.equal("Ch. 2  ↓", shown_chapter_menu.chapters[2].menu_text)
        assert.are.equal(0, #shown_messages)
    end)

    it("updates chapter row text while a queued chapter downloads", function()
        local shown_chapter_menu
        local menu_updates = 0
        local fake_chapter_menu = {
            updateItems = function()
                menu_updates = menu_updates + 1
            end,
        }

        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "MangaDex", lang = "en" } } }
                end,
                fetchMangaForSource = function()
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function()
                    return { ok = true, chapters = { { id = "398", name = "Official_Vol. 1 Ch. 1" } } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            local steps = 0
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title, download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function()
                    return false
                end,
                startChapterDownload = function()
                    return {
                        ok = true,
                        path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
                        total = 2,
                        job = {},
                    }
                end,
                downloadNextPage = function()
                    steps = steps + 1
                    return {
                        ok = true,
                        done = steps == 2,
                        current = steps,
                        total = 2,
                        path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
                    }
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showSourcesMenu = function(sources, onSelect)
                    onSelect(sources[1])
                end,
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                end,
                showChapterMenu = function(options, onSelect)
                    shown_chapter_menu = options
                    onSelect(options.chapters[1])
                    return fake_chapter_menu
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadSourceLanguages = function() return { "en" } end,
                loadDownloadDirectory = function() return "/books" end,
                saveDownloadDirectory = function(_, path) return path end,
                save = function(_, value) return value end,
                saveSourceLanguages = function(_, value) return value end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}

        plugin:browseSuwayomi()

        assert.are.equal("Official_Vol. 1 Ch. 1  ⏳", shown_chapter_menu.chapters[1].menu_text)
        run_scheduled_callbacks()

        assert.is_true(menu_updates >= 2)
        assert.are.equal("Official_Vol. 1 Ch. 1  ↓", shown_chapter_menu.chapters[1].menu_text)
        assert.are.equal(0, #shown_messages)
    end)

    it("shows Suwayomi read chapters as read and saves them in the ledger", function()
        local shown_chapter_menu
        local saved_ledger

        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "MangaDex", lang = "en" } } }
                end,
                fetchMangaForSource = function()
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function()
                    return {
                        ok = true,
                        chapters = {
                            { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = true },
                            { id = "399", name = "Ch. 2", is_read = false },
                        },
                    }
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showSourcesMenu = function(sources, onSelect)
                    onSelect(sources[1])
                end,
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                end,
                showChapterMenu = function(options)
                    shown_chapter_menu = options
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadSourceLanguages = function() return { "en" } end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger or {} end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin:browseSuwayomi()

        assert.are.equal("Official_Vol. 1 Ch. 1  ✓", shown_chapter_menu.chapters[1].menu_text)
        assert.are.equal("Ch. 2", shown_chapter_menu.chapters[2].menu_text)
        assert.is_true(saved_ledger["m1:398"].read)
    end)

    it("shows chapter actions on tap instead of downloading immediately", function()
        local shown_actions_menu

        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "MangaDex", lang = "en" } } }
                end,
                fetchMangaForSource = function()
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function()
                    return { ok = true, chapters = { { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = false } } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function()
                    return false
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showSourcesMenu = function(sources, onSelect)
                    onSelect(sources[1])
                end,
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                end,
                showChapterMenu = function(options, onSelect)
                    onSelect(options.chapters[1])
                end,
                showChapterActionsMenu = function(options)
                    shown_actions_menu = options
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadSourceLanguages = function() return { "en" } end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return {} end,
                saveChapterLedger = function(_, ledger) return ledger end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin:browseSuwayomi()

        assert.are.equal("Official_Vol. 1 Ch. 1", shown_actions_menu.title)
        assert.are.equal("Download", shown_actions_menu.actions[1].text)
        assert.are.equal("Mark as read", shown_actions_menu.actions[2].text)
        assert.are.equal("Mark previous as read", shown_actions_menu.actions[3].text)
        assert.are.equal("Mark this and previous as read", shown_actions_menu.actions[4].text)
    end)

    it("uses tap to toggle chapters while selection mode is active", function()
        local shown_chapter_menu
        local tap_chapter
        local hold_chapter
        local shown_actions_menu
        local menu_updates = 0
        local fake_chapter_menu = {
            updateItems = function()
                menu_updates = menu_updates + 1
            end,
        }

        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "MangaDex", lang = "en" } } }
                end,
                fetchMangaForSource = function()
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function()
                    return {
                        ok = true,
                        chapters = {
                            { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = false },
                            { id = "399", name = "Official_Vol. 1 Ch. 2", is_read = false },
                        },
                    }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function()
                    return false
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showSourcesMenu = function(sources, onSelect)
                    onSelect(sources[1])
                end,
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                end,
                showChapterMenu = function(options, onSelect, onHold)
                    shown_chapter_menu = options
                    tap_chapter = onSelect
                    hold_chapter = onHold
                    return fake_chapter_menu
                end,
                updateChapterMenu = function(_, options, onSelect, onHold)
                    shown_chapter_menu = options
                    tap_chapter = onSelect
                    hold_chapter = onHold
                    fake_chapter_menu:updateItems()
                end,
                showChapterActionsMenu = function(options)
                    shown_actions_menu = options
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadSourceLanguages = function() return { "en" } end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return {} end,
                saveChapterLedger = function(_, ledger) return ledger end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin:browseSuwayomi()

        assert.are.equal("appbar.menu", shown_chapter_menu.title_bar_left_icon)
        assert.is_function(shown_chapter_menu.on_title_bar_left_tap)

        hold_chapter(shown_chapter_menu.chapters[1])

        assert.are.equal("1 selected", shown_chapter_menu.title)
        assert.are.equal("[x] Official_Vol. 1 Ch. 1", shown_chapter_menu.chapters[1].menu_text)
        assert.are.equal("[ ] Official_Vol. 1 Ch. 2", shown_chapter_menu.chapters[2].menu_text)
        assert.is_true(plugin.selection_mode)
        assert.is_true(plugin:isChapterSelected("m1", "398"))
        assert.are.equal(1, menu_updates)

        tap_chapter(shown_chapter_menu.chapters[2])

        assert.is_nil(shown_actions_menu)
        assert.are.equal("2 selected", shown_chapter_menu.title)
        assert.are.equal("[x] Official_Vol. 1 Ch. 1", shown_chapter_menu.chapters[1].menu_text)
        assert.are.equal("[x] Official_Vol. 1 Ch. 2", shown_chapter_menu.chapters[2].menu_text)
        assert.is_true(plugin:isChapterSelected("m1", "399"))
        assert.are.equal(2, menu_updates)

        plugin:toggleChapterSelection({ id = "m1" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        assert.are.equal("1 selected", shown_chapter_menu.title)
        assert.are.equal("[ ] Official_Vol. 1 Ch. 1", shown_chapter_menu.chapters[1].menu_text)
        assert.are.equal("[x] Official_Vol. 1 Ch. 2", shown_chapter_menu.chapters[2].menu_text)
        assert.is_false(plugin:isChapterSelected("m1", "398"))
        assert.is_true(plugin.selection_mode)

        plugin:toggleChapterSelection({ id = "m1" }, { id = "399", name = "Official_Vol. 1 Ch. 2" })

        assert.are.equal("Sousou no Frieren", shown_chapter_menu.title)
        assert.are.equal("Official_Vol. 1 Ch. 1", shown_chapter_menu.chapters[1].menu_text)
        assert.are.equal("Official_Vol. 1 Ch. 2", shown_chapter_menu.chapters[2].menu_text)
        assert.is_false(plugin:isChapterSelected("m1", "399"))
        assert.is_false(plugin.selection_mode)

        tap_chapter(shown_chapter_menu.chapters[1])

        assert.are.equal("Official_Vol. 1 Ch. 1", shown_actions_menu.title)
    end)

    it("shows bulk actions for selected chapters and queues selected downloads", function()
        local shown_chapter_menu
        local tap_chapter
        local hold_chapter
        local tap_bulk_actions
        local shown_actions_menu
        local download_calls = {}
        local menu_updates = 0
        local fake_chapter_menu = {
            updateItems = function()
                menu_updates = menu_updates + 1
            end,
        }

        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "Local source", lang = "localsourcelang" } } }
                end,
                fetchMangaForSource = function()
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function()
                    return {
                        ok = true,
                        chapters = {
                            { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = false },
                            { id = "399", name = "Official_Vol. 1 Ch. 2", is_read = false },
                            { id = "400", name = "Official_Vol. 1 Ch. 3", is_read = false },
                        },
                    }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                getPartialPath = function(_, chapter_path)
                    return chapter_path .. ".part"
                end,
                chapterExists = function()
                    return false
                end,
                downloadChapterWithProgress = function(self, _, download_directory, manga, chapter, progress_path)
                    table.insert(download_calls, chapter.id)
                    self:writeProgress(progress_path, "downloaded", 1, 1, download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz")
                end,
                writeProgress = function(_, progress_path, state, current, total, path)
                    local handle = io.open(progress_path, "w")
                    handle:write("state=", tostring(state or ""), "\n")
                    handle:write("current=", tostring(current or 0), "\n")
                    handle:write("total=", tostring(total or 0), "\n")
                    handle:write("path=", tostring(path or ""), "\n")
                    handle:close()
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showSourcesMenu = function(sources, onSelect)
                    onSelect(sources[1])
                end,
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                end,
                showChapterMenu = function(options, onSelect, onHold)
                    shown_chapter_menu = options
                    tap_bulk_actions = options.on_title_bar_left_tap
                    tap_chapter = onSelect
                    hold_chapter = onHold
                    return fake_chapter_menu
                end,
                updateChapterMenu = function(_, options, onSelect, onHold)
                    shown_chapter_menu = options
                    tap_bulk_actions = options.on_title_bar_left_tap
                    tap_chapter = onSelect
                    hold_chapter = onHold
                    fake_chapter_menu:updateItems()
                end,
                showChapterActionsMenu = function(options)
                    shown_actions_menu = options
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadSourceLanguages = function() return { "localsourcelang" } end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return {} end,
                saveChapterLedger = function(_, ledger) return ledger end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin:browseSuwayomi()

        hold_chapter(shown_chapter_menu.chapters[1])
        tap_chapter(shown_chapter_menu.chapters[3])

        assert.are.equal("2 selected", shown_chapter_menu.title)
        assert.are.equal("appbar.menu", shown_chapter_menu.title_bar_left_icon)
        assert.are.equal("[x] Official_Vol. 1 Ch. 1", shown_chapter_menu.chapters[1].menu_text)
        assert.are.equal("[ ] Official_Vol. 1 Ch. 2", shown_chapter_menu.chapters[2].menu_text)
        assert.are.equal("[x] Official_Vol. 1 Ch. 3", shown_chapter_menu.chapters[3].menu_text)

        tap_bulk_actions()

        assert.are.equal("2 selected chapters", shown_actions_menu.title)
        assert.are.equal("Download selected", shown_actions_menu.actions[1].text)
        assert.are.equal("Delete selected from device", shown_actions_menu.actions[2].text)
        assert.are.equal("Mark selected as read", shown_actions_menu.actions[3].text)
        assert.are.equal("Mark selected as unread", shown_actions_menu.actions[4].text)
        assert.are.equal("Clear selection", shown_actions_menu.actions[5].text)
        assert.are.equal("Download next 5 unread", shown_actions_menu.actions[6].text)
        assert.are.equal("Download next 10 unread", shown_actions_menu.actions[7].text)

        plugin:performBulkChapterAction("download_selected")
        run_scheduled_callbacks()

        assert.are.same({ "398", "400" }, download_calls)
        assert.is_false(plugin.selection_mode)
        assert.are.equal("Official_Vol. 1 Ch. 1  ↓", shown_chapter_menu.chapters[1].menu_text)
        assert.are.equal("Official_Vol. 1 Ch. 3  ↓", shown_chapter_menu.chapters[3].menu_text)
        assert.is_true(menu_updates > 0)
    end)

    it("opens chapter bulk actions from the titlebar without selection", function()
        local shown_chapter_menu
        local tap_bulk_actions
        local shown_actions_menu

        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "Local source", lang = "localsourcelang" } } }
                end,
                fetchMangaForSource = function()
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function()
                    return { ok = true, chapters = { { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = false } } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function()
                    return false
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showSourcesMenu = function(sources, onSelect)
                    onSelect(sources[1])
                end,
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                end,
                showChapterMenu = function(options)
                    shown_chapter_menu = options
                    tap_bulk_actions = options.on_title_bar_left_tap
                end,
                showChapterActionsMenu = function(options)
                    shown_actions_menu = options
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadSourceLanguages = function() return { "localsourcelang" } end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return {} end,
                saveChapterLedger = function(_, ledger) return ledger end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin:browseSuwayomi()

        tap_bulk_actions()

        assert.are.equal("Chapter downloads", shown_actions_menu.title)
        assert.are.equal("Download next 5 unread", shown_actions_menu.actions[1].text)
        assert.are.equal("Download next 10 unread", shown_actions_menu.actions[2].text)
        assert.are.equal("Download next 50 unread", shown_actions_menu.actions[3].text)
        assert.are.equal("Keep next 5 unread downloaded", shown_actions_menu.actions[4].text)
        assert.are.equal("Keep next 10 unread downloaded", shown_actions_menu.actions[5].text)
        assert.are.equal("Keep next 50 unread downloaded", shown_actions_menu.actions[6].text)
        assert.are.equal("Delete read chapters from device", shown_actions_menu.actions[7].text)
        assert.is_false(plugin.selection_mode)
        assert.are.equal("Sousou no Frieren", shown_chapter_menu.title)
    end)

    it("queues the next unread chapter downloads and skips unavailable chapters", function()
        local saved_queue = {}

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                getPartialPath = function(_, chapter_path)
                    return chapter_path .. ".part"
                end,
                chapterExists = function(_, chapter_path)
                    return chapter_path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 3.cbz"
                end,
                downloadChapterWithProgress = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return saved_queue end,
                saveDownloadQueue = function(_, jobs)
                    saved_queue = jobs
                    return jobs
                end,
                loadChapterLedger = function() return {} end,
                saveChapterLedger = function(_, ledger) return ledger end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapters = {
            { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = true },
            { id = "399", name = "Official_Vol. 1 Ch. 2", is_read = false },
            { id = "400", name = "Official_Vol. 1 Ch. 3", is_read = false },
            { id = "401", name = "Official_Vol. 1 Ch. 4", is_read = false },
            { id = "402", name = "Official_Vol. 1 Ch. 5", is_read = false },
            { id = "403", name = "Official_Vol. 1 Ch. 6", is_read = false },
            { id = "404", name = "Official_Vol. 1 Ch. 7", is_read = false },
            { id = "405", name = "Official_Vol. 1 Ch. 8", is_read = false },
        }
        plugin.current_chapter_context = {
            manga = manga,
            chapters = chapters,
        }
        plugin:getDownloadQueue():enqueue(manga, chapters[4], "/books")

        local queued = plugin:performBulkChapterAction("download_next_5_unread")

        assert.is_true(queued)
        assert.are.equal(6, #saved_queue)
        assert.are.equal("401", saved_queue[1].chapter.id)
        assert.are.equal("399", saved_queue[2].chapter.id)
        assert.are.equal("402", saved_queue[3].chapter.id)
        assert.are.equal("403", saved_queue[4].chapter.id)
        assert.are.equal("404", saved_queue[5].chapter.id)
        assert.are.equal("405", saved_queue[6].chapter.id)
        assert.are.same({}, shown_messages)
    end)

    it("coalesces chapter menu refreshes when queueing bulk downloads", function()
        local saved_queue = {}
        local menu_updates = 0

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                getPartialPath = function(_, chapter_path)
                    return chapter_path .. ".part"
                end,
                chapterExists = function()
                    return false
                end,
                downloadChapterWithProgress = function() end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                updateChapterMenu = function()
                    menu_updates = menu_updates + 1
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return saved_queue end,
                saveDownloadQueue = function(_, jobs)
                    saved_queue = jobs
                    return jobs
                end,
                loadChapterLedger = function() return {} end,
                saveChapterLedger = function(_, ledger) return ledger end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin.current_chapter_menu = {}
        plugin.current_chapter_context = {
            manga = { id = "m1", title = "Sousou no Frieren" },
            chapters = {
                { id = "399", name = "Official_Vol. 1 Ch. 2", is_read = false },
                { id = "400", name = "Official_Vol. 1 Ch. 3", is_read = false },
                { id = "401", name = "Official_Vol. 1 Ch. 4", is_read = false },
                { id = "402", name = "Official_Vol. 1 Ch. 5", is_read = false },
                { id = "403", name = "Official_Vol. 1 Ch. 6", is_read = false },
            },
        }

        local queued = plugin:performBulkChapterAction("download_next_5_unread")

        assert.is_true(queued)
        assert.are.equal(5, #saved_queue)
        assert.are.equal(1, menu_updates)
    end)

    it("keeps the next unread chapter buffer downloaded or queued", function()
        local saved_queue = {}

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                getPartialPath = function(_, chapter_path)
                    return chapter_path .. ".part"
                end,
                chapterExists = function(_, chapter_path)
                    return chapter_path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 3.cbz"
                end,
                downloadChapterWithProgress = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return saved_queue end,
                saveDownloadQueue = function(_, jobs)
                    saved_queue = jobs
                    return jobs
                end,
                loadChapterLedger = function() return {} end,
                saveChapterLedger = function(_, ledger) return ledger end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapters = {
            { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = true },
            { id = "399", name = "Official_Vol. 1 Ch. 2", is_read = false },
            { id = "400", name = "Official_Vol. 1 Ch. 3", is_read = false },
            { id = "401", name = "Official_Vol. 1 Ch. 4", is_read = false },
            { id = "402", name = "Official_Vol. 1 Ch. 5", is_read = false },
            { id = "403", name = "Official_Vol. 1 Ch. 6", is_read = false },
            { id = "404", name = "Official_Vol. 1 Ch. 7", is_read = false },
        }
        plugin.current_chapter_context = {
            manga = manga,
            chapters = chapters,
        }
        plugin:getDownloadQueue():enqueue(manga, chapters[4], "/books")

        local handled = plugin:performBulkChapterAction("keep_next_5_unread")

        assert.is_true(handled)
        assert.are.equal(4, #saved_queue)
        assert.are.equal("401", saved_queue[1].chapter.id)
        assert.are.equal("399", saved_queue[2].chapter.id)
        assert.are.equal("402", saved_queue[3].chapter.id)
        assert.are.equal("403", saved_queue[4].chapter.id)
        assert.are.same({}, shown_messages)
    end)

    it("reports when the unread download buffer is already satisfied", function()
        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function()
                    return true
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return {} end,
                saveChapterLedger = function(_, ledger) return ledger end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin.current_chapter_context = {
            manga = { id = "m1", title = "Sousou no Frieren" },
            chapters = {
                { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = false },
                { id = "399", name = "Official_Vol. 1 Ch. 2", is_read = false },
            },
        }

        plugin:performBulkChapterAction("keep_next_5_unread")

        assert.are.equal("Next unread chapter buffer is already downloaded or queued.", shown_messages[#shown_messages])
    end)

    it("deletes read chapters from device without selecting them", function()
        local removed_paths = {}
        local refreshed_chapter_menu
        local saved_ledger = {
            ["m1:398"] = {
                manga_id = "m1",
                manga_title = "Sousou no Frieren",
                chapter_id = "398",
                chapter_name = "Official_Vol. 1 Ch. 1",
                read = true,
                path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
            },
            ["m1:399"] = {
                manga_id = "m1",
                manga_title = "Sousou no Frieren",
                chapter_id = "399",
                chapter_name = "Official_Vol. 1 Ch. 2",
                read = false,
                path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 2.cbz",
            },
        }
        local original_remove = os.remove

        os.remove = function(path)
            table.insert(removed_paths, path)
            return true
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function(_, chapter_path)
                    for _, removed_path in ipairs(removed_paths) do
                        if removed_path == chapter_path then
                            return false
                        end
                    end
                    return chapter_path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz"
                        or chapter_path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 2.cbz"
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                updateChapterMenu = function(_, options)
                    refreshed_chapter_menu = options
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin.current_chapter_menu = {}
        plugin.current_chapter_context = {
            manga = { id = "m1", title = "Sousou no Frieren" },
            chapters = {
                { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = true },
                { id = "399", name = "Official_Vol. 1 Ch. 2", is_read = false },
            },
        }
        plugin:setChapterDownloadStatus(
            plugin.current_chapter_context.manga,
            plugin.current_chapter_context.chapters[1],
            { state = "downloaded" }
        )

        local deleted = plugin:performBulkChapterAction("delete_read_downloaded")
        os.remove = original_remove

        assert.is_true(deleted)
        assert.are.equal("/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz", removed_paths[1])
        assert.are.equal("Official_Vol. 1 Ch. 1  ✓", refreshed_chapter_menu.chapters[1].menu_text)
        assert.is_nil(saved_ledger["m1:398"].path)
        assert.are.equal("/books/Sousou no Frieren/Official_Vol. 1 Ch. 2.cbz", saved_ledger["m1:399"].path)
        assert.are.same({}, shown_messages)
    end)

    it("reports when there are no read chapters to delete", function()
        package.preload.suwayomi_settings = function()
            return {
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin.current_chapter_context = {
            manga = { id = "m1", title = "Sousou no Frieren" },
            chapters = {
                { id = "399", name = "Official_Vol. 1 Ch. 2", is_read = false },
            },
        }

        plugin:performBulkChapterAction("delete_read_downloaded")

        assert.are.equal("No read chapters to delete.", shown_messages[#shown_messages])
    end)

    it("reports queued and skipped counts for selected downloads", function()
        local saved_queue = {}

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                getPartialPath = function(_, chapter_path)
                    return chapter_path .. ".part"
                end,
                chapterExists = function(_, chapter_path)
                    return chapter_path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 2.cbz"
                end,
                downloadChapterWithProgress = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return saved_queue end,
                saveDownloadQueue = function(_, jobs)
                    saved_queue = jobs
                    return jobs
                end,
                loadChapterLedger = function() return {} end,
                saveChapterLedger = function(_, ledger) return ledger end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local first = { id = "398", name = "Official_Vol. 1 Ch. 1" }
        local downloaded = { id = "399", name = "Official_Vol. 1 Ch. 2" }
        local queued = { id = "400", name = "Official_Vol. 1 Ch. 3" }
        plugin.current_chapter_context = {
            manga = manga,
            chapters = { first, downloaded, queued },
        }
        plugin.selected_chapters = { ["m1:398"] = true, ["m1:399"] = true, ["m1:400"] = true }
        plugin.selection_mode = true
        plugin:getDownloadQueue():enqueue(manga, queued, "/books")

        plugin:performBulkChapterAction("download_selected")

        assert.are.equal(2, #saved_queue)
        assert.is_false(plugin.selection_mode)
        assert.are.same({}, shown_messages)
    end)

    it("shows a short-lived message when bulk download only skips chapters", function()
        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function()
                    return true
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return {} end,
                saveChapterLedger = function(_, ledger) return ledger end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin.current_chapter_context = {
            manga = { id = "m1", title = "Sousou no Frieren" },
            chapters = {
                { id = "398", name = "Official_Vol. 1 Ch. 1" },
            },
        }
        plugin.selected_chapters = { ["m1:398"] = true }
        plugin.selection_mode = true

        plugin:performBulkChapterAction("download_selected")

        assert.are.equal("No new downloads queued. Skipped 1 already downloaded or queued.", shown_messages[#shown_messages])
    end)

    it("limits excessive selected bulk download requests", function()
        local saved_queue = {}

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                getPartialPath = function(_, chapter_path)
                    return chapter_path .. ".part"
                end,
                chapterExists = function()
                    return false
                end,
                downloadChapterWithProgress = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return saved_queue end,
                saveDownloadQueue = function(_, jobs)
                    saved_queue = jobs
                    return jobs
                end,
                loadChapterLedger = function() return {} end,
                saveChapterLedger = function(_, ledger) return ledger end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local chapters = {}
        local selected = {}
        for index = 1, 55 do
            local chapter = { id = tostring(400 + index), name = "Chapter " .. tostring(index), is_read = false }
            table.insert(chapters, chapter)
            selected["m1:" .. tostring(400 + index)] = true
        end
        plugin.current_chapter_context = {
            manga = manga,
            chapters = chapters,
        }
        plugin.selected_chapters = selected
        plugin.selection_mode = true

        plugin:performBulkChapterAction("download_selected")

        assert.are.equal(50, #saved_queue)
        assert.are.equal("401", saved_queue[1].chapter.id)
        assert.are.equal("450", saved_queue[50].chapter.id)
        assert.are.equal("Queued first 50 downloads. Refine the chapter selection to queue more.", shown_messages[#shown_messages])
    end)

    it("deletes selected downloaded chapters from bulk actions", function()
        local saved_ledger = {
            ["m1:398"] = {
                manga_id = "m1",
                manga_title = "Sousou no Frieren",
                chapter_id = "398",
                chapter_name = "Official_Vol. 1 Ch. 1",
                path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
                read = true,
            },
            ["m1:400"] = {
                manga_id = "m1",
                manga_title = "Sousou no Frieren",
                chapter_id = "400",
                chapter_name = "Official_Vol. 1 Ch. 3",
                path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 3.cbz",
            },
        }
        local existing = {
            ["/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz"] = true,
            ["/books/Sousou no Frieren/Official_Vol. 1 Ch. 3.cbz"] = true,
        }
        local removed_paths = {}
        local menu_updates = 0
        local original_remove = os.remove

        os.remove = function(path)
            table.insert(removed_paths, path)
            existing[path] = nil
            return true
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function(_, chapter_path)
                    return existing[chapter_path] == true
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin.current_chapter_context = {
            manga = { id = "m1", title = "Sousou no Frieren" },
            chapters = {
                { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = true },
                { id = "399", name = "Official_Vol. 1 Ch. 2", is_read = false },
                { id = "400", name = "Official_Vol. 1 Ch. 3", is_read = false },
            },
        }
        plugin.current_chapter_menu = {
            updateItems = function()
                menu_updates = menu_updates + 1
            end,
        }
        plugin.selected_chapters = { ["m1:398"] = true, ["m1:400"] = true }
        plugin.selection_mode = true

        local bulk_actions = plugin:getBulkChapterActions()
        assert.are.equal("Delete selected from device", bulk_actions[2].text)

        plugin:performBulkChapterAction("delete_selected")
        os.remove = original_remove

        assert.are.same({
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.sdr/metadata.cbz.lua",
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.sdr/metadata.cbz.lua.old",
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.sdr",
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 3.cbz",
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 3.sdr/metadata.cbz.lua",
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 3.sdr/metadata.cbz.lua.old",
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 3.sdr",
        }, removed_paths)
        assert.is_nil(saved_ledger["m1:398"].path)
        assert.is_true(saved_ledger["m1:398"].read)
        assert.is_nil(saved_ledger["m1:400"])
        assert.is_false(plugin.selection_mode)
        assert.are.equal(1, menu_updates)
        assert.are.same({}, shown_messages)
    end)

    it("cancels queued downloads and skips active downloads before bulk delete", function()
        local removed_paths = {}
        local original_remove = os.remove
        local existing = {
            ["/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz"] = true,
            ["/books/Sousou no Frieren/Official_Vol. 1 Ch. 2.cbz"] = true,
        }

        os.remove = function(path)
            table.insert(removed_paths, path)
            existing[path] = nil
            return true
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                getPartialPath = function(_, chapter_path)
                    return chapter_path .. ".part"
                end,
                chapterExists = function(_, chapter_path)
                    return existing[chapter_path] == true
                end,
                downloadChapterWithProgress = function() end,
            }
        end

        local saved_queue = {}
        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return saved_queue end,
                saveDownloadQueue = function(_, jobs)
                    saved_queue = jobs
                    return jobs
                end,
                loadChapterLedger = function() return {} end,
                saveChapterLedger = function(_, ledger) return ledger end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local queued = { id = "398", name = "Official_Vol. 1 Ch. 1" }
        local active = { id = "399", name = "Official_Vol. 1 Ch. 2" }
        plugin.current_chapter_context = {
            manga = manga,
            chapters = { queued, active },
        }
        plugin.selected_chapters = { ["m1:398"] = true, ["m1:399"] = true }
        plugin.selection_mode = true

        plugin:getDownloadQueue():enqueue(manga, queued, "/books")
        plugin:getDownloadQueue():enqueue(manga, active, "/books")
        plugin:getDownloadQueue().active = {
            key = "m1:399",
            manga = manga,
            chapter = active,
            download_directory = "/books",
            progress_path = "/books/.suwayomi_dl_progress_m1_399.txt",
        }
        plugin:getDownloadQueue():setStatus(manga, active, { state = "downloading" })

        plugin:performBulkChapterAction("delete_selected")
        os.remove = original_remove

        assert.are.same({
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.sdr/metadata.cbz.lua",
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.sdr/metadata.cbz.lua.old",
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.sdr",
        }, removed_paths)
        assert.is_nil(plugin:getDownloadQueue():getStatus(manga, queued))
        assert.are.equal("downloading", plugin:getDownloadQueue():getStatus(manga, active).state)
        assert.is_true(existing["/books/Sousou no Frieren/Official_Vol. 1 Ch. 2.cbz"])
        assert.are.equal("Deleted 1 selected chapter from device. 1 download is still in progress.", shown_messages[#shown_messages])
    end)

    it("reports missing and active counts during bulk delete", function()
        local removed_paths = {}
        local original_remove = os.remove
        local existing = {
            ["/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz"] = true,
            ["/books/Sousou no Frieren/Official_Vol. 1 Ch. 3.cbz"] = true,
        }

        os.remove = function(path)
            table.insert(removed_paths, path)
            existing[path] = nil
            return true
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                getPartialPath = function(_, chapter_path)
                    return chapter_path .. ".part"
                end,
                chapterExists = function(_, chapter_path)
                    return existing[chapter_path] == true
                end,
                downloadChapterWithProgress = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return {} end,
                saveChapterLedger = function(_, ledger) return ledger end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        local manga = { id = "m1", title = "Sousou no Frieren" }
        local downloaded = { id = "398", name = "Official_Vol. 1 Ch. 1" }
        local missing = { id = "399", name = "Official_Vol. 1 Ch. 2" }
        local active = { id = "400", name = "Official_Vol. 1 Ch. 3" }
        plugin.current_chapter_context = {
            manga = manga,
            chapters = { downloaded, missing, active },
        }
        plugin.selected_chapters = { ["m1:398"] = true, ["m1:399"] = true, ["m1:400"] = true }
        plugin.selection_mode = true

        plugin:getDownloadQueue():enqueue(manga, active, "/books")
        plugin:getDownloadQueue().active = {
            key = "m1:400",
            manga = manga,
            chapter = active,
            download_directory = "/books",
            progress_path = "/books/.suwayomi_dl_progress_m1_400.txt",
        }
        plugin:getDownloadQueue():setStatus(manga, active, { state = "downloading" })

        plugin:performBulkChapterAction("delete_selected")
        os.remove = original_remove

        assert.are.equal("/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz", removed_paths[1])
        assert.are.equal("downloading", plugin:getDownloadQueue():getStatus(manga, active).state)
        assert.are.equal(
            "Deleted 1 selected chapter from device. Skipped 1 not downloaded. 1 download is still in progress.",
            shown_messages[#shown_messages]
        )
    end)

    it("marks selected chapters read and schedules one background sync", function()
        local saved_ledger = {}
        local marked_ids = {}
        local menu_updates = 0

        package.preload.suwayomi_api = function()
            return {
                markChapterRead = function(_, chapter_id)
                    table.insert(marked_ids, chapter_id)
                    return { ok = true, chapter = { id = chapter_id, is_read = true } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function()
                    return false
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin.current_chapter_context = {
            manga = { id = "m1", title = "Sousou no Frieren" },
            chapters = {
                { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = false },
                { id = "399", name = "Official_Vol. 1 Ch. 2", is_read = false },
            },
        }
        plugin.current_chapter_menu = {
            updateItems = function()
                menu_updates = menu_updates + 1
            end,
        }
        plugin.selected_chapters = { ["m1:398"] = true, ["m1:399"] = true }
        plugin.selection_mode = true

        plugin:performBulkChapterAction("mark_read_selected")

        assert.is_true(saved_ledger["m1:398"].read)
        assert.is_true(saved_ledger["m1:398"].pending_read_sync)
        assert.is_true(saved_ledger["m1:399"].read)
        assert.is_true(saved_ledger["m1:399"].pending_read_sync)
        assert.is_true(plugin.current_chapter_context.chapters[1].is_read)
        assert.is_true(plugin.current_chapter_context.chapters[2].is_read)
        assert.is_false(plugin.selection_mode)
        assert.are.equal(1, menu_updates)
        assert.are.same({}, shown_messages)

        run_scheduled_callbacks()

        table.sort(marked_ids)
        assert.are.same({ "398", "399" }, marked_ids)
        assert.is_nil(saved_ledger["m1:398"].pending_read_sync)
        assert.is_nil(saved_ledger["m1:399"].pending_read_sync)
    end)

    it("marks selected chapters unread and schedules one background sync", function()
        local saved_ledger = {
            ["m1:398"] = {
                manga_id = "m1",
                manga_title = "Sousou no Frieren",
                chapter_id = "398",
                chapter_name = "Official_Vol. 1 Ch. 1",
                read = true,
                pending_read_sync = true,
                path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
            },
            ["m1:399"] = {
                manga_id = "m1",
                manga_title = "Sousou no Frieren",
                chapter_id = "399",
                chapter_name = "Official_Vol. 1 Ch. 2",
                read = true,
                pending_read_sync = true,
            },
        }
        local marked_ids = {}
        local menu_updates = 0

        package.preload.suwayomi_api = function()
            return {
                markChapterUnread = function(_, chapter_id)
                    table.insert(marked_ids, chapter_id)
                    return { ok = true, chapter = { id = chapter_id, is_read = false } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function(_, chapter_path)
                    return chapter_path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz"
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin.current_chapter_context = {
            manga = { id = "m1", title = "Sousou no Frieren" },
            chapters = {
                { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = true },
                { id = "399", name = "Official_Vol. 1 Ch. 2", is_read = true },
            },
        }
        plugin.current_chapter_menu = {
            updateItems = function()
                menu_updates = menu_updates + 1
            end,
        }
        plugin.selected_chapters = { ["m1:398"] = true, ["m1:399"] = true }
        plugin.selection_mode = true

        plugin:performBulkChapterAction("mark_unread_selected")

        assert.is_false(saved_ledger["m1:398"].read)
        assert.is_true(saved_ledger["m1:398"].pending_read_sync)
        assert.is_false(saved_ledger["m1:398"].pending_read_state)
        assert.is_equal("/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz", saved_ledger["m1:398"].path)
        assert.is_false(saved_ledger["m1:399"].read)
        assert.is_true(saved_ledger["m1:399"].pending_read_sync)
        assert.is_false(saved_ledger["m1:399"].pending_read_state)
        assert.is_false(plugin.current_chapter_context.chapters[1].is_read)
        assert.is_false(plugin.current_chapter_context.chapters[2].is_read)
        assert.is_false(plugin.selection_mode)
        assert.are.equal(1, menu_updates)
        assert.are.same({}, shown_messages)

        run_scheduled_callbacks()

        table.sort(marked_ids)
        assert.are.same({ "398", "399" }, marked_ids)
        assert.is_nil(saved_ledger["m1:398"].pending_read_sync)
        assert.is_nil(saved_ledger["m1:398"].pending_read_state)
        assert.is_nil(saved_ledger["m1:399"].pending_read_sync)
        assert.is_nil(saved_ledger["m1:399"].pending_read_state)
    end)

    it("opens a downloaded chapter from the chapter actions menu", function()
        local opened_path

        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "MangaDex", lang = "en" } } }
                end,
                fetchMangaForSource = function()
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function()
                    return { ok = true, chapters = { { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = false } } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function(_, chapter_path)
                    return chapter_path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz"
                end,
            }
        end

        package.preload["apps/reader/readerui"] = function()
            return {
                showReader = function(_, path)
                    opened_path = path
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return {} end,
                saveChapterLedger = function(_, ledger) return ledger end,
            }
        end

        package.loaded.main = nil
        package.loaded["apps/reader/readerui"] = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin:performChapterAction(
            { id = "m1", title = "Sousou no Frieren" },
            { id = "398", name = "Official_Vol. 1 Ch. 1" },
            "open"
        )

        assert.are.equal("/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz", opened_path)
        package.preload["apps/reader/readerui"] = nil
    end)

    it("deletes a downloaded chapter from the chapter actions menu", function()
        local saved_ledger = {
            ["m1:398"] = {
                manga_id = "m1",
                manga_title = "Sousou no Frieren",
                chapter_id = "398",
                chapter_name = "Official_Vol. 1 Ch. 1",
                path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
                read = true,
            },
        }
        local removed_paths = {}
        local original_remove = os.remove
        local chapter_present = true

        os.remove = function(path)
            table.insert(removed_paths, path)
            if path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz" then
                chapter_present = false
            end
            return true
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function(_, chapter_path)
                    return chapter_present and chapter_path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz"
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin.current_chapter_context = {
            manga = { id = "m1", title = "Sousou no Frieren" },
            chapters = { { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = true } },
        }

        plugin:performChapterAction(
            { id = "m1", title = "Sousou no Frieren" },
            { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = true },
            "delete"
        )

        os.remove = original_remove

        assert.are.same({
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.sdr/metadata.cbz.lua",
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.sdr/metadata.cbz.lua.old",
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.sdr",
        }, removed_paths)
        assert.is_nil(saved_ledger["m1:398"].path)
        assert.is_true(saved_ledger["m1:398"].read)
    end)

    it("shows mark as unread for chapters already marked read", function()
        local actions

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function()
                    return false
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return {} end,
                saveChapterLedger = function(_, ledger) return ledger end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        actions = plugin:getChapterActions(
            { id = "m1", title = "Sousou no Frieren" },
            { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = true }
        )

        assert.are.equal("Download", actions[1].text)
        assert.are.equal("Mark as unread", actions[2].text)
    end)

    it("marks a chapter read locally before syncing it in the background", function()
        local saved_ledger = {}
        local marked_chapter_id

        package.preload.suwayomi_api = function()
            return {
                markChapterRead = function(_, chapter_id)
                    marked_chapter_id = chapter_id
                    return { ok = true, chapter = { id = chapter_id, is_read = true } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function(_, chapter_path)
                    return chapter_path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz"
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin.current_chapter_context = {
            manga = { id = "m1", title = "Sousou no Frieren" },
            chapters = { { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = false } },
        }

        plugin:markChapterRead(
            { id = "m1", title = "Sousou no Frieren" },
            { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = false }
        )

        assert.is_true(saved_ledger["m1:398"].read)
        assert.is_true(saved_ledger["m1:398"].pending_read_sync)
        assert.is_true(plugin.current_chapter_context.chapters[1].is_read)
        assert.is_nil(marked_chapter_id)

        run_scheduled_callbacks()

        assert.are.equal("398", marked_chapter_id)
        assert.is_nil(saved_ledger["m1:398"].pending_read_sync)
    end)

    it("marks the chosen chapter and previous chapters read for a clean-state read boundary", function()
        local saved_ledger = {}
        local marked_ids = {}
        local menu_updates = 0

        package.preload.suwayomi_api = function()
            return {
                markChapterRead = function(_, chapter_id)
                    table.insert(marked_ids, chapter_id)
                    return { ok = true, chapter = { id = chapter_id, is_read = true } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function()
                    return false
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        local manga = { id = "m1", title = "Sousou no Frieren" }
        plugin.current_chapter_context = {
            manga = manga,
            chapters = {
                { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = false },
                { id = "399", name = "Official_Vol. 1 Ch. 2", is_read = false },
                { id = "400", name = "Official_Vol. 1 Ch. 3", is_read = false },
                { id = "401", name = "Official_Vol. 1 Ch. 4", is_read = false },
            },
        }
        plugin.current_chapter_menu = {
            updateItems = function()
                menu_updates = menu_updates + 1
            end,
        }

        plugin:performChapterAction(manga, plugin.current_chapter_context.chapters[3], "mark_through_read")

        assert.is_true(saved_ledger["m1:398"].read)
        assert.is_true(saved_ledger["m1:399"].read)
        assert.is_true(saved_ledger["m1:400"].read)
        assert.is_nil(saved_ledger["m1:401"])
        assert.is_true(plugin.current_chapter_context.chapters[1].is_read)
        assert.is_true(plugin.current_chapter_context.chapters[2].is_read)
        assert.is_true(plugin.current_chapter_context.chapters[3].is_read)
        assert.is_false(plugin.current_chapter_context.chapters[4].is_read)
        assert.are.equal(1, menu_updates)

        run_scheduled_callbacks()

        table.sort(marked_ids)
        assert.are.same({ "398", "399", "400" }, marked_ids)
    end)

    it("marks only previous chapters read when choosing the first unread chapter", function()
        local saved_ledger = {}
        local marked_ids = {}

        package.preload.suwayomi_api = function()
            return {
                markChapterRead = function(_, chapter_id)
                    table.insert(marked_ids, chapter_id)
                    return { ok = true, chapter = { id = chapter_id, is_read = true } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function()
                    return false
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        local manga = { id = "m1", title = "Sousou no Frieren" }
        plugin.current_chapter_context = {
            manga = manga,
            chapters = {
                { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = false },
                { id = "399", name = "Official_Vol. 1 Ch. 2", is_read = false },
                { id = "400", name = "Official_Vol. 1 Ch. 3", is_read = false },
            },
        }

        plugin:performChapterAction(manga, plugin.current_chapter_context.chapters[3], "mark_previous_read")

        assert.is_true(saved_ledger["m1:398"].read)
        assert.is_true(saved_ledger["m1:399"].read)
        assert.is_nil(saved_ledger["m1:400"])
        assert.is_true(plugin.current_chapter_context.chapters[1].is_read)
        assert.is_true(plugin.current_chapter_context.chapters[2].is_read)
        assert.is_false(plugin.current_chapter_context.chapters[3].is_read)

        run_scheduled_callbacks()

        table.sort(marked_ids)
        assert.are.same({ "398", "399" }, marked_ids)
    end)

    it("does not keep stale ledger read state when Suwayomi and KOReader are unread", function()
        local shown_chapter_menu
        local saved_ledger = {
            ["m1:398"] = {
                manga_id = "m1",
                chapter_id = "398",
                read = true,
            },
        }

        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "MangaDex", lang = "en" } } }
                end,
                fetchMangaForSource = function()
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function()
                    return { ok = true, chapters = { { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = false } } }
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showSourcesMenu = function(sources, onSelect)
                    onSelect(sources[1])
                end,
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                end,
                showChapterMenu = function(options)
                    shown_chapter_menu = options
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadSourceLanguages = function() return { "en" } end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin:browseSuwayomi()

        assert.are.equal("Official_Vol. 1 Ch. 1", shown_chapter_menu.chapters[1].menu_text)
        assert.is_nil(saved_ledger["m1:398"])
    end)

    it("marks a downloaded chapter read when KOReader sidecar metadata is complete", function()
        local shown_chapter_menu
        local saved_ledger = {
            ["m1:401"] = {
                manga_id = "m1",
                manga_title = "Sousou no Frieren",
                chapter_id = "401",
                chapter_name = "Official_Vol. 1 Ch. 4",
                path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 4.cbz",
                read = false,
            },
        }
        local original_open = io.open

        io.open = function(path, mode)
            if path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 4.sdr/metadata.cbz.lua" then
                return {
                    read = function()
                        return [[
return {
    ["doc_path"] = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 4.cbz",
    ["percent_finished"] = 1,
    ["summary"] = {
        ["status"] = "complete",
    },
}
]]
                    end,
                    close = function() end,
                }
            end
            return original_open(path, mode)
        end

        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "MangaDex", lang = "en" } } }
                end,
                fetchMangaForSource = function()
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function()
                    return { ok = true, chapters = { { id = "401", name = "Official_Vol. 1 Ch. 4", is_read = false } } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function(_, chapter_path)
                    return chapter_path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 4.cbz"
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showSourcesMenu = function(sources, onSelect)
                    onSelect(sources[1])
                end,
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                end,
                showChapterMenu = function(options)
                    shown_chapter_menu = options
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadSourceLanguages = function() return { "en" } end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin:browseSuwayomi()

        assert.are.equal("Official_Vol. 1 Ch. 4  ✓ ↓", shown_chapter_menu.chapters[1].menu_text)
        assert.is_true(saved_ledger["m1:401"].read)
        assert.is_true(saved_ledger["m1:401"].pending_read_sync)
    end)

    it("marks a downloaded chapter read when KOReader history contains the chapter", function()
        local shown_chapter_menu
        local saved_ledger = {
            ["m1:402"] = {
                manga_id = "m1",
                manga_title = "Sousou no Frieren",
                chapter_id = "402",
                chapter_name = "Official_Vol. 1 Ch. 5",
                path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 5.cbz",
                read = false,
            },
        }
        local original_open = io.open

        io.open = function(path, mode)
            if path == "/settings/history.lua" then
                return {
                    read = function()
                        return [[
return {
    [1] = {
        ["time"] = 1776971183,
        ["file"] = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 5.cbz",
    },
}
]]
                    end,
                    close = function() end,
                }
            end
            if path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 5.sdr/metadata.cbz.lua" then
                return nil
            end
            return original_open(path, mode)
        end

        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "Local source", lang = "localsourcelang" } } }
                end,
                fetchMangaForSource = function()
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function()
                    return { ok = true, chapters = { { id = "402", name = "Official_Vol. 1 Ch. 5", is_read = false } } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function(_, chapter_path)
                    return chapter_path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 5.cbz"
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showSourcesMenu = function(sources, onSelect)
                    onSelect(sources[1])
                end,
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                end,
                showChapterMenu = function(options)
                    shown_chapter_menu = options
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                getSettingsDir = function() return "/settings" end,
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadSourceLanguages = function() return { "localsourcelang" } end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin:browseSuwayomi()

        assert.are.equal("Official_Vol. 1 Ch. 5  ✓ ↓", shown_chapter_menu.chapters[1].menu_text)
        assert.is_true(saved_ledger["m1:402"].read)
        assert.is_true(saved_ledger["m1:402"].pending_read_sync)
    end)

    it("writes KOReader sidecar metadata when marking a downloaded chapter read", function()
        local saved_ledger = {}
        local files = {
            ["/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.sdr/metadata.cbz.lua"] = [[
return {
    ["doc_path"] = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
    ["bookmark"] = {
        ["page"] = 4,
    },
}
]],
        }
        local original_open = io.open

        io.open = function(path, mode)
            if path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.sdr/metadata.cbz.lua" then
                if mode == "r" then
                    local content = files[path]
                    if not content then
                        return nil
                    end
                    return {
                        read = function()
                            return content
                        end,
                        close = function() end,
                    }
                end
                if mode == "w" then
                    local chunks = {}
                    return {
                        write = function(_, ...)
                            for _, value in ipairs({...}) do
                                table.insert(chunks, value)
                            end
                        end,
                        close = function()
                            files[path] = table.concat(chunks)
                        end,
                    }
                end
            end
            return original_open(path, mode)
        end

        package.preload.lfs = function()
            return {
                attributes = function(path, attribute)
                    if path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.sdr" and attribute == "mode" then
                        return "directory"
                    end
                end,
                mkdir = function()
                    return true
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function(_, chapter_path)
                    return chapter_path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz"
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil
        package.loaded.lfs = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}

        plugin:markChapterRead(
            { id = "m1", title = "Sousou no Frieren" },
            { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = false }
        )
        io.open = original_open

        local metadata = assert(loadstring(files["/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.sdr/metadata.cbz.lua"]))()
        assert.are.equal(1, metadata.percent_finished)
        assert.are.equal("complete", metadata.summary.status)
        assert.are.equal(4, metadata.bookmark.page)
    end)

    it("writes KOReader sidecar metadata when Suwayomi reports a downloaded chapter read", function()
        local shown_chapter_menu
        local saved_ledger = {}
        local files = {}
        local dirs = {
            ["/books/Sousou no Frieren"] = true,
        }
        local original_open = io.open

        io.open = function(path, mode)
            if path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.sdr/metadata.cbz.lua" then
                if mode == "r" then
                    return nil
                end
                if mode == "w" then
                    local chunks = {}
                    return {
                        write = function(_, ...)
                            for _, value in ipairs({...}) do
                                table.insert(chunks, value)
                            end
                        end,
                        close = function()
                            files[path] = table.concat(chunks)
                        end,
                    }
                end
            end
            return original_open(path, mode)
        end

        package.preload.lfs = function()
            return {
                attributes = function(path, attribute)
                    if attribute == "mode" and dirs[path] then
                        return "directory"
                    end
                end,
                mkdir = function(path)
                    dirs[path] = true
                    return true
                end,
            }
        end

        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "MangaDex", lang = "en" } } }
                end,
                fetchMangaForSource = function()
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function()
                    return { ok = true, chapters = { { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = true } } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function(_, chapter_path)
                    return chapter_path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz"
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showSourcesMenu = function(sources, onSelect)
                    onSelect(sources[1])
                end,
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                end,
                showChapterMenu = function(options)
                    shown_chapter_menu = options
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadSourceLanguages = function() return { "en" } end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil
        package.loaded.lfs = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin:browseSuwayomi()
        io.open = original_open

        assert.are.equal("Official_Vol. 1 Ch. 1  ✓ ↓", shown_chapter_menu.chapters[1].menu_text)
        local metadata = assert(loadstring(files["/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.sdr/metadata.cbz.lua"]))()
        assert.are.equal(1, metadata.percent_finished)
        assert.are.equal("complete", metadata.summary.status)
    end)

    it("clears KOReader sidecar read fields when marking a downloaded chapter unread", function()
        local saved_ledger = {
            ["m1:398"] = {
                manga_id = "m1",
                manga_title = "Sousou no Frieren",
                chapter_id = "398",
                chapter_name = "Official_Vol. 1 Ch. 1",
                read = true,
                path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
            },
        }
        local files = {
            ["/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.sdr/metadata.cbz.lua"] = [[
return {
    ["doc_path"] = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
    ["percent_finished"] = 1,
    ["summary"] = {
        ["status"] = "complete",
        ["other"] = "kept",
    },
}
]],
        }
        local original_open = io.open

        io.open = function(path, mode)
            if path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.sdr/metadata.cbz.lua" then
                if mode == "r" then
                    local content = files[path]
                    if not content then
                        return nil
                    end
                    return {
                        read = function()
                            return content
                        end,
                        close = function() end,
                    }
                end
                if mode == "w" then
                    local chunks = {}
                    return {
                        write = function(_, ...)
                            for _, value in ipairs({...}) do
                                table.insert(chunks, value)
                            end
                        end,
                        close = function()
                            files[path] = table.concat(chunks)
                        end,
                    }
                end
            end
            return original_open(path, mode)
        end

        package.preload.lfs = function()
            return {
                attributes = function(path, attribute)
                    if path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.sdr" and attribute == "mode" then
                        return "directory"
                    end
                end,
                mkdir = function()
                    return true
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function(_, chapter_path)
                    return chapter_path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz"
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil
        package.loaded.lfs = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}

        plugin:markChapterUnread(
            { id = "m1", title = "Sousou no Frieren" },
            { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = true }
        )
        io.open = original_open

        local metadata = assert(loadstring(files["/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.sdr/metadata.cbz.lua"]))()
        assert.are.equal(0, metadata.percent_finished)
        assert.is_nil(metadata.summary.status)
        assert.are.equal("kept", metadata.summary.other)
    end)

    it("marks a known downloaded chapter read when KOReader closes it as finished", function()
        local saved_ledger = {
            ["m1:398"] = {
                manga_id = "m1",
                manga_title = "Sousou no Frieren",
                chapter_id = "398",
                chapter_name = "Official_Vol. 1 Ch. 1",
                path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
                read = false,
            },
        }
        local marked_chapter_id

        package.preload.suwayomi_api = function()
            return {
                markChapterRead = function(credentials, chapter_id)
                    marked_chapter_id = chapter_id
                    assert.are.equal("https://suwayomi.example", credentials.server_url)
                    return { ok = true, chapter = { id = chapter_id, is_read = true } }
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{
            ui = {
                document = {
                    file = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
                },
                doc_settings = {
                    readSetting = function(_, key)
                        if key == "summary" then
                            return { status = "finished" }
                        end
                    end,
                },
            },
        }

        plugin:onCloseDocument()

        assert.is_true(saved_ledger["m1:398"].read)
        assert.is_true(saved_ledger["m1:398"].pending_read_sync)
        assert.is_nil(marked_chapter_id)

        run_scheduled_callbacks()

        assert.are.equal("398", marked_chapter_id)
        assert.is_nil(saved_ledger["m1:398"].pending_read_sync)
    end)

    it("keeps a pending read sync when Suwayomi cannot be updated", function()
        local saved_ledger = {
            ["m1:398"] = {
                manga_id = "m1",
                manga_title = "Sousou no Frieren",
                chapter_id = "398",
                chapter_name = "Official_Vol. 1 Ch. 1",
                path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
                read = false,
            },
        }

        package.preload.suwayomi_api = function()
            return {
                markChapterRead = function()
                    return { ok = false, error = "offline" }
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{
            ui = {
                document = {
                    file = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
                },
                doc_settings = {
                    readSetting = function(_, key)
                        if key == "summary" then
                            return { status = "finished" }
                        end
                    end,
                },
            },
        }

        plugin:onCloseDocument()

        assert.is_true(saved_ledger["m1:398"].read)
        assert.is_true(saved_ledger["m1:398"].pending_read_sync)
    end)

    it("retries pending read syncs and clears them after Suwayomi accepts", function()
        local saved_ledger = {
            ["m1:398"] = {
                manga_id = "m1",
                manga_title = "Sousou no Frieren",
                chapter_id = "398",
                chapter_name = "Official_Vol. 1 Ch. 1",
                path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
                read = true,
                pending_read_sync = true,
            },
        }
        local marked_chapter_id

        package.preload.suwayomi_api = function()
            return {
                markChapterRead = function(credentials, chapter_id)
                    marked_chapter_id = chapter_id
                    assert.are.equal("https://suwayomi.example", credentials.server_url)
                    return { ok = true, chapter = { id = chapter_id, is_read = true } }
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}

        plugin:syncPendingReadMarks()

        assert.are.equal("398", marked_chapter_id)
        assert.is_true(saved_ledger["m1:398"].read)
        assert.is_nil(saved_ledger["m1:398"].pending_read_sync)
    end)

    it("syncs pending read marks in small scheduled batches", function()
        local saved_ledger = {
            ["m1:398"] = {
                manga_id = "m1",
                manga_title = "Sousou no Frieren",
                chapter_id = "398",
                chapter_name = "Official_Vol. 1 Ch. 1",
                read = true,
                pending_read_sync = true,
                pending_read_state = true,
            },
            ["m1:399"] = {
                manga_id = "m1",
                manga_title = "Sousou no Frieren",
                chapter_id = "399",
                chapter_name = "Official_Vol. 1 Ch. 2",
                read = true,
                pending_read_sync = true,
                pending_read_state = true,
            },
            ["m1:400"] = {
                manga_id = "m1",
                manga_title = "Sousou no Frieren",
                chapter_id = "400",
                chapter_name = "Official_Vol. 1 Ch. 3",
                read = true,
                pending_read_sync = true,
                pending_read_state = true,
            },
        }
        local marked_ids = {}

        package.preload.suwayomi_api = function()
            return {
                markChapterRead = function(_, chapter_id)
                    table.insert(marked_ids, chapter_id)
                    return { ok = true, chapter = { id = chapter_id, is_read = true } }
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin.read_sync_batch_size = 2

        plugin:schedulePendingReadSync()
        local first_callback = table.remove(scheduled_callbacks, 1)
        first_callback()

        assert.are.equal(2, #marked_ids)
        assert.are.equal(1, #scheduled_callbacks)
        assert.is_true(plugin:hasPendingReadSync(saved_ledger))

        local second_callback = table.remove(scheduled_callbacks, 1)
        second_callback()

        assert.are.equal(3, #marked_ids)
        assert.are.equal(0, #scheduled_callbacks)
        assert.is_false(plugin:hasPendingReadSync(saved_ledger))
    end)

    it("keeps pending read sync while a retry still fails during browsing", function()
        local shown_chapter_menu
        local saved_ledger = {
            ["m1:398"] = {
                manga_id = "m1",
                manga_title = "Sousou no Frieren",
                chapter_id = "398",
                chapter_name = "Official_Vol. 1 Ch. 1",
                path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
                read = true,
                pending_read_sync = true,
            },
        }

        package.preload.suwayomi_api = function()
            return {
                markChapterRead = function()
                    return { ok = false, error = "offline" }
                end,
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "MangaDex", lang = "en" } } }
                end,
                fetchMangaForSource = function()
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function()
                    return { ok = true, chapters = { { id = "398", name = "Official_Vol. 1 Ch. 1", is_read = false } } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title,
                        download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function(_, chapter_path)
                    return chapter_path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz"
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showSourcesMenu = function(sources, onSelect)
                    onSelect(sources[1])
                end,
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                end,
                showChapterMenu = function(options)
                    shown_chapter_menu = options
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadSourceLanguages = function() return { "en" } end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return {} end,
                saveDownloadQueue = function(_, jobs) return jobs end,
                loadChapterLedger = function() return saved_ledger end,
                saveChapterLedger = function(_, ledger)
                    saved_ledger = ledger
                    return ledger
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin:browseSuwayomi()

        assert.are.equal("Official_Vol. 1 Ch. 1  ✓ ↓", shown_chapter_menu.chapters[1].menu_text)
        assert.is_true(saved_ledger["m1:398"].pending_read_sync)
    end)

    it("shows the downloader error when chapter download fails", function()
        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "MangaDex", lang = "en" } } }
                end,
                fetchMangaForSource = function(_, source_id)
                    assert.are.equal("s1", source_id)
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function(_, manga_id)
                    assert.are.equal("m1", manga_id)
                    return { ok = true, chapters = { { id = "398", name = "Official_Vol. 1 Ch. 1" } } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title, download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function()
                    return false
                end,
                startChapterDownload = function()
                    return { ok = false, error = "Set up a download directory first." }
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showSourcesMenu = function(sources, onSelect)
                    onSelect(sources[1])
                end,
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                end,
                showChapterMenu = function(options, onSelect)
                    onSelect(options.chapters[1])
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadSourceLanguages = function() return { "en" } end,
                loadDownloadDirectory = function() return "/books" end,
                saveDownloadDirectory = function(_, path) return path end,
                save = function(_, value) return value end,
                saveSourceLanguages = function(_, value) return value end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}

        plugin:browseSuwayomi()
        run_scheduled_callbacks()

        assert.are.equal("Set up a download directory first.", shown_messages[#shown_messages])
    end)

    it("shows a neutral message when the chapter already exists locally", function()
        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "MangaDex", lang = "en" } } }
                end,
                fetchMangaForSource = function()
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function()
                    return { ok = true, chapters = { { id = "398", name = "Official_Vol. 1 Ch. 1" } } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title, download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function()
                    return true
                end,
                startChapterDownload = function()
                    return { ok = true, skipped = true, path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz" }
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showSourcesMenu = function(sources, onSelect)
                    onSelect(sources[1])
                end,
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                end,
                showChapterMenu = function(options, onSelect)
                    onSelect(options.chapters[1])
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadSourceLanguages = function() return { "en" } end,
                loadDownloadDirectory = function() return "/books" end,
                saveDownloadDirectory = function(_, path) return path end,
                save = function(_, value) return value end,
                saveSourceLanguages = function(_, value) return value end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}

        plugin:browseSuwayomi()
        run_scheduled_callbacks()

        assert.are.equal(0, #shown_messages)
    end)

    it("opens the directory chooser and retries the chapter when no download directory is set", function()
        local downloader_calls = 0

        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "MangaDex", lang = "en" } } }
                end,
                fetchMangaForSource = function()
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function()
                    return { ok = true, chapters = { { id = "398", name = "Official_Vol. 1 Ch. 1" } } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title, download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function()
                    return false
                end,
                startChapterDownload = function(_, _, download_directory)
                    downloader_calls = downloader_calls + 1
                    assert.are.equal("/storage/emulated/0/Books/Manga", download_directory)
                    return {
                        ok = true,
                        total = 1,
                        path = "/storage/emulated/0/Books/Manga/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
                        job = {},
                    }
                end,
                downloadNextPage = function()
                    return {
                        ok = true,
                        done = true,
                        current = 1,
                        total = 1,
                        path = "/storage/emulated/0/Books/Manga/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
                    }
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showSourcesMenu = function(sources, onSelect)
                    onSelect(sources[1])
                end,
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                end,
                showChapterMenu = function(options, onSelect)
                    onSelect(options.chapters[1])
                end,
                showDirectoryChooser = function(callback)
                    directory_chooser_callback = callback
                end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadSourceLanguages = function() return { "en" } end,
                loadDownloadDirectory = function()
                    return saved_download_directory or ""
                end,
                saveDownloadDirectory = function(_, path)
                    saved_download_directory = path
                    return path
                end,
                save = function(_, value) return value end,
                saveSourceLanguages = function(_, value) return value end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}

        plugin:browseSuwayomi()
        directory_chooser_callback("/storage/emulated/0/Books/Manga")
        run_scheduled_callbacks()

        assert.are.equal("/storage/emulated/0/Books/Manga", saved_download_directory)
        assert.are.equal(0, trapper_wrapped)
        assert.are.equal(1, downloader_calls)
        assert.are.equal("Suwayomi download directory saved: /storage/emulated/0/Books/Manga", shown_messages[#shown_messages])
    end)

    it("does not enqueue the same chapter twice while it is already queued", function()
        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "MangaDex", lang = "en" } } }
                end,
                fetchMangaForSource = function()
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function()
                    return { ok = true, chapters = { { id = "398", name = "Official_Vol. 1 Ch. 1" } } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            local start_calls = 0
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title, download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function()
                    return false
                end,
                startChapterDownload = function()
                    start_calls = start_calls + 1
                    return { ok = true, total = 1, path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz", job = { start_calls = start_calls } }
                end,
                downloadNextPage = function()
                    return { ok = true, done = true, current = 1, total = 1, path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz" }
                end,
            }
        end

        local select_chapter
        package.preload.suwayomi_ui = function()
            return {
                showSourcesMenu = function(sources, onSelect)
                    onSelect(sources[1])
                end,
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                end,
                showChapterMenu = function(options, onSelect)
                    select_chapter = function()
                        onSelect(options.chapters[1])
                    end
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadSourceLanguages = function() return { "en" } end,
                loadDownloadDirectory = function() return "/books" end,
                saveDownloadDirectory = function(_, path) return path end,
                save = function(_, value) return value end,
                saveSourceLanguages = function(_, value) return value end,
            }
        end

        package.loaded.main = nil
        package.loaded["ui/trapper"] = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}

        plugin:browseSuwayomi()
        select_chapter()
        select_chapter()

        assert.are.equal("Chapter download is already in progress.", shown_messages[#shown_messages])
    end)

    it("persists queued chapter downloads and removes them after success", function()
        local saved_queue

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title, download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                chapterExists = function()
                    return false
                end,
                startChapterDownload = function()
                    return {
                        ok = true,
                        path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
                        total = 1,
                        job = {},
                    }
                end,
                downloadNextPage = function()
                    return {
                        ok = true,
                        done = true,
                        current = 1,
                        total = 1,
                        path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
                    }
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadDirectory = function() return "/books" end,
                loadDownloadQueue = function() return saved_queue or {} end,
                saveDownloadQueue = function(_, jobs)
                    saved_queue = jobs
                    return jobs
                end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}
        plugin:enqueueChapterDownload(
            { id = "m1", title = "Sousou no Frieren" },
            { id = "398", name = "Official_Vol. 1 Ch. 1" }
        )

        assert.are.equal(1, #saved_queue)
        assert.are.equal("queued", saved_queue[1].state)
        assert.are.equal("m1:398", saved_queue[1].key)

        run_scheduled_callbacks()

        assert.are.same({}, saved_queue)
    end)

    it("requeues interrupted persistent downloads on startup", function()
        local saved_queue = {
            {
                key = "m1:398",
                state = "downloading",
                download_directory = "/books",
                manga = { id = "m1", title = "Sousou no Frieren" },
                chapter = { id = "398", name = "Official_Vol. 1 Ch. 1" },
            },
        }
        local removed_paths = {}
        local start_calls = 0

        package.preload.suwayomi_downloader = function()
            return {
                getTargetPath = function(_, download_directory, manga, chapter)
                    return download_directory .. "/" .. manga.title, download_directory .. "/" .. manga.title .. "/" .. chapter.name .. ".cbz"
                end,
                getPartialPath = function(_, chapter_path)
                    return chapter_path .. ".part"
                end,
                chapterExists = function()
                    return false
                end,
                startChapterDownload = function()
                    start_calls = start_calls + 1
                    return {
                        ok = true,
                        path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
                        total = 1,
                        job = {},
                    }
                end,
                downloadNextPage = function()
                    return {
                        ok = true,
                        done = true,
                        current = 1,
                        total = 1,
                        path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
                    }
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadDownloadQueue = function() return saved_queue end,
                saveDownloadQueue = function(_, jobs)
                    saved_queue = jobs
                    return jobs
                end,
            }
        end

        local original_remove = os.remove
        os.remove = function(path)
            table.insert(removed_paths, path)
            return true
        end

        package.loaded.main = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{
            ui = {
                menu = {
                    registerToMainMenu = function() end,
                },
            },
        }
        plugin:init()

        run_scheduled_callbacks()
        os.remove = original_remove

        assert.are.same({
            "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz.part",
            "/books/.suwayomi_dl_progress_m1_398.txt",
            "/books/.suwayomi_dl_progress_m1_398.txt",
        }, removed_paths)
        assert.are.equal(1, start_calls)
        assert.are.same({}, saved_queue)
    end)

    it("shows a message when browse fails", function()
        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return {
                        ok = false,
                        error = "Authentication failed.",
                    }
                end,
            }
        end
        package.loaded.main = nil
        package.loaded.suwayomi_api = nil

        local plugin_class = require("main")
        local menu_items = {}
        local plugin = plugin_class{}

        plugin:addToMainMenu(menu_items)
        menu_items.suwayomi_dl.sub_item_table[1].callback()

        assert.are.equal("Authentication failed.", shown_messages[#shown_messages])
    end)

    it("opens the language setup menu with the configured languages checked", function()
        local plugin_class = require("main")
        local menu_items = {}
        local plugin = plugin_class{}

        plugin:addToMainMenu(menu_items)
        menu_items.suwayomi_dl.sub_item_table[3].callback()

        assert.is_table(language_menu_options)
        assert.are.equal("en", language_menu_options.languages[1].code)
        assert.are.equal("EN", language_menu_options.languages[1].label)
        assert.are.equal(true, language_menu_options.languages[1].enabled)
        assert.are.equal(true, language_menu_options.languages[2].enabled)
        assert.are.equal(false, language_menu_options.languages[3].enabled)
    end)

    it("saves the chosen download directory and shows a confirmation", function()
        local plugin_class = require("main")
        local menu_items = {}
        local plugin = plugin_class{}

        plugin:addToMainMenu(menu_items)
        menu_items.suwayomi_dl.sub_item_table[4].callback()

        directory_chooser_callback("/storage/emulated/0/Books/Manga")

        assert.are.equal("/storage/emulated/0/Books/Manga", saved_download_directory)
        assert.are.equal("Suwayomi download directory saved: /storage/emulated/0/Books/Manga", shown_messages[#shown_messages])
    end)
end)
