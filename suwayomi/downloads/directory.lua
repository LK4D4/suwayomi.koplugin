-- Boundary: DownloadsDirectory.
--
-- Responsibility: Owns the shared download-directory chooser, persistence, summary, and retry callback flow.
-- Owned state: Persists only through suwayomi/settings.lua; callbacks execute on plugin instances.
-- Dependencies: KOReader UI helpers, settings, filesystem probing, and the plugin i18n facade.
-- External data: Settings values, selected paths, and filesystem paths remain untrusted until checked locally.

local UIManager = require("ui/uimanager")
local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")
local I18n = require("suwayomi/i18n")

local DownloadsDirectory = {}
DownloadsDirectory.__index = DownloadsDirectory

-- Controllers expose new(deps) for a consistent boundary; methods remain plugin-bound mixins so this refactor can move code without changing callback behavior.
function DownloadsDirectory:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

local function directoryExists(lfs, path)
    return path and path ~= "" and lfs.attributes(path, "mode") == "directory"
end

local function normalizeDownloadDirectory(path)
    if type(path) ~= "string" then
        return ""
    end
    return path
end

local function joinPath(base, name)
    if base:sub(-1) == "/" then
        return base .. name
    end
    return base .. "/" .. name
end

local function getDefaultMangaDirectory(lfs, home_dir)
    if not directoryExists(lfs, home_dir) then
        return nil
    end

    local books_dir = joinPath(home_dir, "Books")
    if not directoryExists(lfs, books_dir) then
        return nil
    end

    local manga_dir = joinPath(books_dir, "Manga")
    if directoryExists(lfs, manga_dir) then
        return manga_dir
    end

    if lfs.mkdir then
        local created = lfs.mkdir(manga_dir)
        if created and directoryExists(lfs, manga_dir) then
            return manga_dir
        end
    end
    return nil
end

local function runCallback(callback, saved_path, options)
    if not callback then
        return
    end
    if options and options.next_tick and UIManager and UIManager.nextTick then
        UIManager:nextTick(function()
            callback(saved_path)
        end)
        return
    end
    callback(saved_path)
end

function Methods:getDownloadDirectoryChooserStartDir()
    local ok, lfs = pcall(require, "suwayomi/fs")
    if not ok or not lfs or not lfs.attributes then
        return nil
    end

    local download_directory = normalizeDownloadDirectory(SuwayomiSettings:loadDownloadDirectory())
    if directoryExists(lfs, download_directory) then
        return download_directory
    end

    local reader_settings = _G.G_reader_settings
    if reader_settings and reader_settings.readSetting then
        local home_dir = reader_settings:readSetting("home_dir")
        if directoryExists(lfs, home_dir) then
            return home_dir
        end
    end

    local device_ok, Device = pcall(require, "device")
    if device_ok and Device and directoryExists(lfs, Device.home_dir) then
        local default_manga_dir = getDefaultMangaDirectory(lfs, Device.home_dir)
        if default_manga_dir then
            return default_manga_dir
        end
        return Device.home_dir
    end
    return nil
end

function Methods:getDownloadDirectorySummary()
    local path = normalizeDownloadDirectory(SuwayomiSettings:loadDownloadDirectory())
    if not path or path == "" then
        return I18n.t("not set")
    end

    path = tostring(path):gsub("/+$", "")
    local parts = {}
    for part in path:gmatch("[^/]+") do
        table.insert(parts, part)
    end
    if #parts >= 2 then
        return parts[#parts - 1] .. "/" .. parts[#parts]
    end
    return path
end

function Methods:chooseDownloadDirectory(callback, options)
    SuwayomiUI.showDirectoryChooser(function(path)
        local saved_path = SuwayomiSettings:saveDownloadDirectory(path)
        if not (options and options.suppress_saved_message) then
            self:showMessage(I18n.t("Suwayomi download directory saved."))
        end
        runCallback(callback, saved_path, options)
    end, self:getDownloadDirectoryChooserStartDir())
end

function Methods:getDownloadDirectoryOrChoose(callback, options)
    local download_directory = normalizeDownloadDirectory(SuwayomiSettings:loadDownloadDirectory())
    if download_directory and download_directory ~= "" then
        return download_directory
    end

    self:chooseDownloadDirectory(callback, options)
    return nil
end

DownloadsDirectory.methods = Methods

return DownloadsDirectory
