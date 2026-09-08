-- Shared KOReader runtime harness for main.lua composition tests.
--
-- Keep this helper limited to plugin shell wiring. Domain controller behavior
-- belongs in focused controller specs, while main_spec uses this harness to
-- verify module installation, dispatcher registration, and lifecycle callbacks.

local Helper = {}

local function clone(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[clone(key)] = clone(item)
    end
    return result
end

local MODULES_TO_CLEAR = {
    "main",
    "dispatcher",
    "ffi/util",
    "gettext",
    "ui/uimanager",
    "ui/font",
    "ui/widget/infomessage",
    "ui/widget/textboxwidget",
    "ui/widget/container/widgetcontainer",
    "ui/elements/reader_menu_order",
    "apps/reader/readerui",
    "suwayomi/api",
    "suwayomi/subprocess/job",
    "suwayomi/client",
    "suwayomi/fs",
    "suwayomi/downloads/queue",
    "suwayomi/downloads/service",
    "suwayomi/downloads/cleanup_adapter",
    "suwayomi/downloads/downloader",
    "suwayomi/downloads/active_jobs",
    "suwayomi/downloads/job_store",
    "suwayomi/downloads/progress_file",
    "suwayomi/downloads/status_formatter",
    "suwayomi/readsync/worker",
    "suwayomi/browse/global_search_worker",
    "suwayomi/browse/source_fetch_worker",
    "suwayomi/ui",
    "suwayomi/navigation",
    "suwayomi/settings",
    "suwayomi/debug",
    "suwayomi/i18n",
    "suwayomi/plugin/home",
    "suwayomi/plugin/settings_controller",
    "suwayomi/reader_return",
    "suwayomi/browse/source_catalog",
    "suwayomi/browse/controller",
    "suwayomi/downloads/directory",
    "suwayomi/manga/controller",
    "suwayomi/chapters/context",
    "suwayomi/chapters/menu",
    "suwayomi/chapters/actions",
    "suwayomi/chapters/local_downloads",
    "suwayomi/chapters/delete_actions",
    "suwayomi/chapters/read_actions",
    "suwayomi/chapters/finished_cleanup",
    "suwayomi/downloads/controller",
    "suwayomi/readsync/ledger",
    "suwayomi/readsync/koreader_metadata",
    "suwayomi/readsync/controller",
    "datastorage",
    "luasettings",
    "lfs",
    "device",
}

function Helper.clearModules()
    for _, name in ipairs(MODULES_TO_CLEAR) do
        package.loaded[name] = nil
    end
end

function Helper.clearPreloads()
    for _, name in ipairs(MODULES_TO_CLEAR) do
        package.preload[name] = nil
    end
end

local function identity_gettext(text)
    return text
end

function Helper.install(options)
    options = options or {}
    Helper.clearModules()
    Helper.clearPreloads()

    local state = {
        registered_actions = {},
        registered_menu_plugin = nil,
        shown_home_dialog = nil,
        home_downloads_labels = {},
        queue_instances = {},
        client_instances = {},
        debug_events = {},
        api_debug_logger = nil,
        closed_widgets = {},
        lifecycle_events = {},
        queue_status_callbacks = {},
        scheduled = {},
        chapter_ledger = clone(options.chapter_ledger or {}),
        finished_cleanup_journal = clone(options.finished_cleanup_journal or {
            version = 1,
            next_sequence = 1,
            mangas = {},
        }),
        reader_ui = {
            instance = options.reader_ui_instance,
        },
        reader_menu_order = options.reader_menu_order or {
            main = { "history", "open_previous_document" },
        },
    }

    package.preload.dispatcher = function()
        return {
            registerAction = function(_, name, definition)
                table.insert(state.registered_actions, {
                    name = name,
                    definition = definition,
                })
            end,
        }
    end

    package.preload.gettext = function()
        return identity_gettext
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
                if callback then
                    callback()
                end
                return 1234
            end,
            isSubProcessDone = function()
                return true
            end,
            realpath = function(path)
                return path
            end,
        }
    end

    package.preload["ui/uimanager"] = function()
        return {
            show = function() end,
            close = function(_, widget)
                table.insert(state.closed_widgets, widget)
                if type(widget) == "table" and widget.close_callback then
                    widget.close_callback()
                end
            end,
            nextTick = function(_, callback)
                if callback then
                    callback()
                end
            end,
            scheduleIn = function(_, delay, callback)
                table.insert(state.scheduled, { delay = delay, callback = callback })
            end,
            setDirty = function() end,
            forceRePaint = function() end,
        }
    end

    package.preload["ui/widget/infomessage"] = function()
        return {
            new = function(_, widget_options)
                return widget_options or {}
            end,
        }
    end

    package.preload["ui/font"] = function()
        return { getFace = function() return {} end }
    end

    package.preload["ui/widget/textboxwidget"] = function()
        return { new = function()
            return {
                getAllLineCount = function() return 1 end,
                getVisLineCount = function() return 15 end,
                free = function() end,
            }
        end }
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

    package.preload["suwayomi/api"] = function()
        return {
            setDebugLogger = function(logger)
                state.api_debug_logger = logger
            end,
        }
    end

    package.preload["suwayomi/client"] = function()
        local Client = {}

        function Client:new(client_options)
            local instance = {
                options = client_options,
            }
            table.insert(state.client_instances, instance)
            return instance
        end

        return Client
    end

    package.preload["suwayomi/downloads/queue"] = function()
        local Queue = {}

        function Queue:new(queue_options)
            local instance = {
                options = queue_options,
                max_active_chapters = queue_options and queue_options.max_active_chapters,
                recovered = false,
            }

            function instance:recover()
                self.recovered = true
                table.insert(state.lifecycle_events, "queue-recover")
            end

            function instance:getSnapshot()
                return { active = {}, queued = {}, failed = {}, manual_deletion = {} }
            end

            function instance:checkStoreFence() return true end

            table.insert(state.queue_instances, instance)
            table.insert(state.queue_status_callbacks, queue_options.onStatusChanged)
            return instance
        end

        return Queue
    end

    package.preload["suwayomi/downloads/downloader"] = function()
        return {}
    end

    package.preload["suwayomi/readsync/worker"] = function()
        return {}
    end

    package.preload["suwayomi/browse/source_fetch_worker"] = function()
        return {}
    end

    package.preload["suwayomi/ui"] = function()
        return {
            showHomeDialog = function(dialog_options)
                state.shown_home_dialog = dialog_options
                return dialog_options
            end,
            updateHomeDownloadsLabel = function(dialog, text)
                for _, action in ipairs(dialog.actions or {}) do
                    if action.id == "downloads" then
                        action.text = text
                    end
                end
                table.insert(state.home_downloads_labels, text)
                return true
            end,
            showDirectoryChooser = function(callback, start_dir)
                state.directory_chooser_callback = callback
                state.directory_chooser_start_dir = start_dir
            end,
        }
    end

    package.preload["suwayomi/settings"] = function()
        local checked = require("spec/support/checked_queue_settings")()
        return {
            load = function()
                return options.credentials or {
                    server_url = "https://suwayomi.example",
                }
            end,
            loadMaxParallelChapterDownloads = function()
                return options.max_parallel_chapter_downloads or 2
            end,
            loadDownloadDirectory = function()
                return options.download_directory or "/books"
            end,
            saveDownloadDirectory = function(_, path)
                options.download_directory = path
                return path
            end,
            getStore = checked.getStore,
            isBlocked = checked.isBlocked,
            reconcile = checked.reconcile,
            loadDownloadQueue = checked.loadDownloadQueue,
            saveDownloadQueue = checked.saveDownloadQueue,
            loadDeleteChaptersSettings = function()
                return options.delete_chapters_settings or {
                    delete_after_mark_read = false,
                    delete_finished_while_reading = 0,
                }
            end,
            loadFinishedChapterCleanupJournal = function()
                return clone(state.finished_cleanup_journal)
            end,
            saveFinishedChapterCleanupJournal = function(_, journal)
                state.finished_cleanup_journal = clone(journal)
                return clone(journal)
            end,
            clearFinishedChapterCleanupJournal = function()
                state.finished_cleanup_journal = {
                    version = 1,
                    next_sequence = 1,
                    mangas = {},
                }
                return state.finished_cleanup_journal
            end,
            loadChapterLedger = function()
                return clone(state.chapter_ledger)
            end,
            saveChapterLedger = function(_, ledger)
                state.chapter_ledger = clone(ledger)
                return clone(ledger)
            end,
            loadReaderReturnContexts = function()
                return options.reader_return_contexts or {}
            end,
            saveReaderReturnContexts = function(_, contexts)
                options.reader_return_contexts = contexts
                return contexts
            end,
        }
    end

    package.preload["suwayomi/debug"] = function()
        return {
            now = function()
                return 100
            end,
            log = function(event)
                table.insert(state.debug_events, event)
            end,
        }
    end

    package.preload["ui/elements/reader_menu_order"] = function()
        return state.reader_menu_order
    end

    package.preload["apps/reader/readerui"] = function()
        return state.reader_ui
    end

    package.preload.datastorage = function()
        return {
            getSettingsDir = function()
                return "/settings"
            end,
        }
    end

    package.preload.luasettings = function()
        return {
            open = function()
                return {
                    readSetting = function(_, _, default)
                        return default
                    end,
                    saveSetting = function(self)
                        return self
                    end,
                    flush = function() end,
                }
            end,
        }
    end

    package.preload.lfs = function()
        return {
            attributes = function()
                return nil
            end,
            mkdir = function()
                return true
            end,
        }
    end

    package.preload.device = function()
        return {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
            },
            home_dir = "/device-home",
        }
    end

    return state
end

function Helper.teardown()
    Helper.clearModules()
    Helper.clearPreloads()
end

return Helper
