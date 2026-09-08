package.path = "?.lua;" .. package.path

-- Directory-flow specs own the shared chooser, persistence, summary, and
-- retry-callback behavior used by chapter, manga, downloads, and settings code.
local helper = require("spec/support/controller_module_spec_helper")
local Marker = require("spec/support/i18n_marker")

describe("suwayomi/downloads/directory", function()
    local settings
    local ui
    local lfs
    local device
    local marker_installed = false
    local service

    local function installMarker()
        if not marker_installed then
            Marker.install()
            marker_installed = true
        end
    end

    local function reset_modules()
        for _, name in ipairs({
            "suwayomi/downloads/directory",
            "suwayomi/settings",
            "suwayomi/ui",
            "suwayomi/fs",
            "lfs",
            "device",
            "datastorage", "luasettings", "ffi/util", "ui/uimanager",
            "suwayomi/downloads/service", "suwayomi/downloads/refill",
            "suwayomi/downloads/queue", "suwayomi/downloads/cleanup_adapter",
            "suwayomi/downloads/active_jobs", "suwayomi/downloads/job_store",
            "suwayomi/downloads/progress_file", "suwayomi/downloads/status_formatter",
            "suwayomi/downloads/archive", "suwayomi/downloads/downloader",
            "suwayomi/chapters/manual_deletion", "suwayomi/chapters/archive_identity",
            "suwayomi/chapters/finished_cleanup", "suwayomi/chapters/local_downloads",
            "suwayomi/chapters/delete_actions", "suwayomi/readsync/ledger",
            "suwayomi/readsync/koreader_metadata", "suwayomi/reader_return",
            "suwayomi/subprocess/job", "suwayomi/debug",
            "suwayomi/network/request_job", "suwayomi/network/request_worker",
            "suwayomi/api",
        }) do
            package.loaded[name] = nil
            package.preload[name] = nil
        end
        package.loaded["suwayomi/i18n"] = nil
        _G.G_reader_settings = nil
    end

    local function load_directory(options)
        options = options or {}
        reset_modules()
        helper.stubControllerDependencies()
        settings = dofile("suwayomi/settings.lua")
        settings:setStore(require("spec/support/checked_queue_settings")():getStore())
        assert(settings:getStore():saveKey("download_directory", options.download_directory or ""))
        ui = {
            calls = {},
            showDirectoryChooser = function(callback, start_dir)
                table.insert(ui.calls, { callback = callback, start_dir = start_dir })
            end,
        }
        lfs = {
            existing = options.existing or {},
            attributes = function(path, key)
                if key == "mode" and lfs.existing[path] then
                    return lfs.existing[path]
                end
                return nil
            end,
            mkdir = function(path)
                table.insert(lfs.created, path)
                lfs.existing[path] = "directory"
                return true
            end,
            created = {},
        }
        device = options.device

        package.preload["suwayomi/settings"] = function()
            return settings
        end
        package.preload["suwayomi/ui"] = function()
            return ui
        end
        package.preload.lfs = function()
            return lfs
        end
        if device then
            package.preload.device = function()
                return device
            end
        end

        return require("suwayomi/downloads/directory")
    end

    local function installPlugin(Directory, plugin)
        plugin = plugin or {}
        for name, method in pairs(Directory.methods) do
            plugin[name] = method
        end
        function plugin:getDownloadQueue()
            if not service then
                service = require("suwayomi/downloads/service"):new{
                    settings = settings,
                    ui_manager = {
                        scheduleIn = function() end,
                        unschedule = function() end,
                    },
                }
            end
            return service:getQueue()
        end
        return plugin
    end

    after_each(function()
        if service then service:shutdown(); service = nil end
        if marker_installed then
            Marker.uninstall()
            marker_installed = false
        end
        reset_modules()
    end)

    it("exports plugin-bound directory flow methods", function()
        local Directory = load_directory()

        assert(type(Directory) == "table")
        assert(type(Directory.new) == "function")
        assert(type(Directory.methods.getDownloadDirectoryChooserStartDir) == "function")
        assert(type(Directory.methods.getDownloadDirectorySummary) == "function")
        assert(type(Directory.methods.chooseDownloadDirectory) == "function")
        assert(type(Directory.methods.getDownloadDirectoryOrChoose) == "function")
    end)

    it("starts the chooser at a saved existing download directory", function()
        local Directory = load_directory({
            download_directory = "/books/Manga",
            existing = {
                ["/books/Manga"] = "directory",
            },
        })
        local plugin = installPlugin(Directory)

        assert.are.equal("/books/Manga", plugin:getDownloadDirectoryChooserStartDir())
    end)

    it("falls back to the KOReader home directory before device defaults", function()
        local Directory = load_directory({
            existing = {
                ["/reader-home"] = "directory",
                ["/device-home"] = "directory",
                ["/device-home/Books"] = "directory",
            },
            device = { home_dir = "/device-home" },
        })
        _G.G_reader_settings = {
            readSetting = function(_, key)
                if key == "home_dir" then
                    return "/reader-home"
                end
                return nil
            end,
        }
        local plugin = installPlugin(Directory)

        assert.are.equal("/reader-home", plugin:getDownloadDirectoryChooserStartDir())
    end)

    it("creates and uses the default device Books/Manga directory when available", function()
        local Directory = load_directory({
            existing = {
                ["/device-home"] = "directory",
                ["/device-home/Books"] = "directory",
            },
            device = { home_dir = "/device-home" },
        })
        local plugin = installPlugin(Directory)

        assert.are.equal("/device-home/Books/Manga", plugin:getDownloadDirectoryChooserStartDir())
        assert.are.same({ "/device-home/Books/Manga" }, lfs.created)
    end)

    it("summarizes the saved download directory with its last two path parts", function()
        local Directory = load_directory({
            download_directory = "/storage/emulated/0/Books/Manga/",
        })
        local plugin = installPlugin(Directory)

        assert.are.equal("Books/Manga", plugin:getDownloadDirectorySummary())

        assert(settings:saveDownloadDirectory(""))
        assert.are.equal("not set", plugin:getDownloadDirectorySummary())
    end)

    it("translates missing-directory summary and save toast while keeping paths raw", function()
        installMarker()
        local Directory = load_directory({
            existing = {
                ["/start"] = "directory",
            },
            download_directory = "",
        })
        local callback_path
        local plugin = installPlugin(Directory, {
            messages = {},
            showMessage = function(self, message)
                table.insert(self.messages, message)
            end,
        })

        assert.are.equal("tx:not set", plugin:getDownloadDirectorySummary())

        assert(settings:saveDownloadDirectory("/start"))
        plugin:chooseDownloadDirectory(function(path)
            callback_path = path
        end)
        ui.calls[1].callback("/chosen/raw/path")

        assert.are.equal("/chosen/raw/path", callback_path)
        assert.are.same({ "tx:Suwayomi download directory saved." }, plugin.messages)
    end)

    it("chooses, saves, reports, and callbacks with the saved directory", function()
        local Directory = load_directory({
            existing = {
                ["/start"] = "directory",
            },
            download_directory = "/start",
        })
        local callback_path
        local plugin = installPlugin(Directory, {
            messages = {},
            showMessage = function(self, message)
                table.insert(self.messages, message)
            end,
        })

        plugin:chooseDownloadDirectory(function(path)
            callback_path = path
        end)
        ui.calls[1].callback("/chosen")

        assert.are.equal("/start", ui.calls[1].start_dir)
        assert.are.equal("/chosen", settings:loadDownloadDirectory())
        assert.are.equal("/chosen", callback_path)
        assert.are.same({ "Suwayomi download directory saved." }, plugin.messages)
    end)

    it("can choose a directory without showing the save toast", function()
        local Directory = load_directory()
        local callback_path
        local plugin = installPlugin(Directory, {
            messages = {},
            showMessage = function(self, message)
                table.insert(self.messages, message)
            end,
        })

        plugin:chooseDownloadDirectory(function(path)
            callback_path = path
        end, { suppress_saved_message = true })
        ui.calls[1].callback("/chosen")

        assert.are.equal("/chosen", settings:loadDownloadDirectory())
        assert.are.equal("/chosen", callback_path)
        assert.are.same({}, plugin.messages)
    end)

    it("returns a saved directory without opening the chooser", function()
        local Directory = load_directory({
            download_directory = "/books",
        })
        local plugin = installPlugin(Directory)

        assert.are.equal("/books", plugin:getDownloadDirectoryOrChoose(function() end))
        assert.are.equal(0, #ui.calls)
    end)

    it("opens the chooser when the saved directory is not a string", function()
        local Directory = load_directory({
            download_directory = { path = "/books" },
        })
        local plugin = installPlugin(Directory, {
            messages = {},
            showMessage = function(self, message)
                table.insert(self.messages, message)
            end,
        })

        assert.is_nil(plugin:getDownloadDirectoryOrChoose(function() end))
        assert.are.equal(1, #ui.calls)
    end)

    it("opens the chooser and retries via callback when no directory is saved", function()
        local Directory = load_directory()
        local callback_path
        local plugin = installPlugin(Directory, {
            messages = {},
            showMessage = function(self, message)
                table.insert(self.messages, message)
            end,
        })

        assert.is_nil(plugin:getDownloadDirectoryOrChoose(function(path)
            callback_path = path
        end))
        ui.calls[1].callback("/chosen")

        assert.are.equal("/chosen", callback_path)
        assert.are.same({ "Suwayomi download directory saved." }, plugin.messages)
    end)
end)
