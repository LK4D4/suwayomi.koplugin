-- Boundary: ReaderReturn.
--
-- Responsibility: Persist chapter return context and restore Suwayomi chapter menus from KOReader reader mode.
-- Owned state: Settings-backed reader return context table keyed by local chapter path.
-- Dependencies: KOReader reader/filemanager UI modules, Suwayomi settings/API, and plugin chapter menu methods.
-- External data: Document paths, persisted contexts, and API responses are treated as optional and checked before use.

local SuwayomiAPI = require("suwayomi/api")
local SuwayomiSettings = require("suwayomi/settings")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local ReaderReturn = {}
ReaderReturn.__index = ReaderReturn

function ReaderReturn:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

local function copyTable(source)
    if type(source) ~= "table" then
        return nil
    end
    local target = {}
    for key, value in pairs(source) do
        if type(value) == "table" then
            target[key] = copyTable(value)
        else
            target[key] = value
        end
    end
    return target
end

local function present(value)
    value = tostring(value or "")
    if value == "" then
        return nil
    end
    return value
end

function Methods:saveReaderReturnContext(manga, chapter, chapter_path)
    if not chapter_path or chapter_path == "" or type(manga) ~= "table" or type(chapter) ~= "table" then
        return nil
    end

    local contexts = SuwayomiSettings:loadReaderReturnContexts() or {}
    local context = {
        path = chapter_path,
        manga_id = present(manga.id),
        manga_title = manga.title,
        chapter_id = present(chapter.id),
        chapter_name = chapter.name,
        source = copyTable(manga.source),
    }
    contexts[chapter_path] = context
    SuwayomiSettings:saveReaderReturnContexts(contexts)
    return context
end

function Methods:getCurrentReaderDocumentPath()
    local document = self.document or (self.ui and self.ui.document)
    return document and document.file or nil
end

function Methods:getReaderReturnContextForPath(path)
    if not path or path == "" then
        return nil
    end

    local contexts = SuwayomiSettings:loadReaderReturnContexts() or {}
    if type(contexts[path]) == "table" then
        return contexts[path]
    end

    local ledger = SuwayomiSettings:loadChapterLedger() or {}
    for _, entry in pairs(ledger) do
        if type(entry) == "table" and entry.path == path then
            return {
                path = entry.path,
                manga_id = present(entry.manga_id),
                manga_title = entry.manga_title,
                chapter_id = present(entry.chapter_id),
                chapter_name = entry.chapter_name,
            }
        end
    end
    return nil
end

function Methods:getCurrentReaderReturnContext()
    return self:getReaderReturnContextForPath(self:getCurrentReaderDocumentPath())
end

function Methods:fetchReaderReturnChapters(context)
    if not context or not context.manga_id then
        self:showMessage(_("This book is not linked to Suwayomi chapters."))
        return nil
    end

    local credentials = SuwayomiSettings:load()
    local result = self:withLoadingMessage("reader-return-chapters", _("Loading chapters..."), function()
        return SuwayomiAPI.fetchChaptersForManga(credentials, context.manga_id)
    end)
    if not result then
        return nil
    end
    if not result.ok then
        self:showMessage(_(result.error))
        return nil
    end
    if not result.chapters or #result.chapters == 0 then
        self:showMessage(_("This manga has no chapters."))
        return nil
    end
    return result
end

function Methods:closeReaderToFileManager(callback)
    UIManager:nextTick(function()
        local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
        if ok_reader and ReaderUI and ReaderUI.instance and ReaderUI.instance.onClose then
            ReaderUI.instance:onClose()
        end

        local ok_filemanager, FileManager = pcall(require, "apps/filemanager/filemanager")
        if ok_filemanager and FileManager then
            if FileManager.instance and FileManager.instance.reinit then
                FileManager.instance:reinit()
            elseif FileManager.showFiles then
                FileManager:showFiles()
            end
        end

        if callback then
            callback()
        end
    end)
end

function Methods:returnToSuwayomiChapters(context)
    context = context or self:getCurrentReaderReturnContext()
    if not context then
        self:showMessage(_("This book is not linked to Suwayomi chapters."))
        return false
    end

    local result = self:fetchReaderReturnChapters(context)
    if not result then
        return false
    end

    local manga = {
        id = context.manga_id,
        title = context.manga_title or context.manga_id,
        source = copyTable(context.source),
    }
    self:closeReaderToFileManager(function()
        self:showChapterResultForManga(manga, result)
    end)
    return true
end

ReaderReturn.methods = Methods

return ReaderReturn
