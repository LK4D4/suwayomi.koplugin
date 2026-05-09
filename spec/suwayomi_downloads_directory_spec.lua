package.path = "?.lua;" .. package.path

-- Directory-flow specs own the shared chooser, persistence, summary, and
-- retry-callback behavior used by chapter, manga, downloads, and settings code.
local helper = require("spec/support/controller_module_spec_helper")

describe("suwayomi/downloads/directory", function()
    local settings
    local ui
    local lfs
    local device

    local function reset_modules()
        for _, name in ipairs({
            "suwayomi/downloads/directory",
            "suwayomi/settings",
            "suwayomi/ui",
            "lfs",
            "device",
        }) do
            package.loaded[name] = nil
            package.preload[name] = nil
        end
        _G.G_reader_settings = nil
    end

    local function load_directory(options)
        options = options or {}
        helper.stubControllerDependencies()
        reset_modules()

        settings = {
            download_directory = options.download_directory or "",
            loadDownloadDirectory = function(self)
                return self.download_directory
            end,
            saveDownloadDirectory = function(self, path)
                self.download_directory = path
                return path
            end,
        }
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

    after_each(reset_modules)

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
        local plugin = {}
        for name, method in pairs(Directory.methods) do
            plugin[name] = method
        end

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
        local plugin = {}
        for name, method in pairs(Directory.methods) do
            plugin[name] = method
        end

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
        local plugin = {}
        for name, method in pairs(Directory.methods) do
            plugin[name] = method
        end

        assert.are.equal("/device-home/Books/Manga", plugin:getDownloadDirectoryChooserStartDir())
        assert.are.same({ "/device-home/Books/Manga" }, lfs.created)
    end)

    it("summarizes the saved download directory with its last two path parts", function()
        local Directory = load_directory({
            download_directory = "/storage/emulated/0/Books/Manga/",
        })
        local plugin = {}
        for name, method in pairs(Directory.methods) do
            plugin[name] = method
        end

        assert.are.equal("Books/Manga", plugin:getDownloadDirectorySummary())

        settings.download_directory = ""
        assert.are.equal("not set", plugin:getDownloadDirectorySummary())
    end)

    it("chooses, saves, reports, and callbacks with the saved directory", function()
        local Directory = load_directory({
            existing = {
                ["/start"] = "directory",
            },
            download_directory = "/start",
        })
        local callback_path
        local plugin = {
            messages = {},
            showMessage = function(self, message)
                table.insert(self.messages, message)
            end,
        }
        for name, method in pairs(Directory.methods) do
            plugin[name] = method
        end

        plugin:chooseDownloadDirectory(function(path)
            callback_path = path
        end)
        ui.calls[1].callback("/chosen")

        assert.are.equal("/start", ui.calls[1].start_dir)
        assert.are.equal("/chosen", settings.download_directory)
        assert.are.equal("/chosen", callback_path)
        assert.are.same({ "Suwayomi download directory saved: /chosen" }, plugin.messages)
    end)

    it("returns a saved directory without opening the chooser", function()
        local Directory = load_directory({
            download_directory = "/books",
        })
        local plugin = {}
        for name, method in pairs(Directory.methods) do
            plugin[name] = method
        end

        assert.are.equal("/books", plugin:getDownloadDirectoryOrChoose(function() end))
        assert.are.equal(0, #ui.calls)
    end)

    it("opens the chooser and retries via callback when no directory is saved", function()
        local Directory = load_directory()
        local callback_path
        local plugin = {
            messages = {},
            showMessage = function(self, message)
                table.insert(self.messages, message)
            end,
        }
        for name, method in pairs(Directory.methods) do
            plugin[name] = method
        end

        assert.is_nil(plugin:getDownloadDirectoryOrChoose(function(path)
            callback_path = path
        end))
        ui.calls[1].callback("/chosen")

        assert.are.equal("/chosen", callback_path)
        assert.are.same({ "Suwayomi download directory saved: /chosen" }, plugin.messages)
    end)
end)
