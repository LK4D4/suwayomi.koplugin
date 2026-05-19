-- Boundary: ReaderReturn.
--
-- Responsibility: Persist chapter return context and restore Suwayomi chapter menus from KOReader reader mode.
-- Owned state: Settings-backed reader return context table keyed by local chapter path.
-- Dependencies: KOReader reader/filemanager UI modules, Suwayomi settings/API, and plugin chapter menu methods.
-- External data: Document paths, persisted contexts, and API responses are treated as optional and checked before use.

local SuwayomiSettings = require("suwayomi/settings")
local NetworkRequestJob = require("suwayomi/network/request_job")
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

local function parentDirectory(path)
    return type(path) == "string" and path:match("^(.*)[/\\][^/\\]+$") or nil
end

local function buildContext(manga, chapter, chapter_path)
    if not chapter_path or chapter_path == "" or type(manga) ~= "table" or type(chapter) ~= "table" then
        return nil
    end

    return {
        path = chapter_path,
        manga_id = present(manga.id),
        manga_title = manga.title,
        in_library = manga.in_library,
        chapter_id = present(chapter.id),
        chapter_name = chapter.name,
        source = copyTable(manga.source),
    }
end

local function sourceMatches(left, right)
    if left == right then
        return true
    end
    if type(left) ~= "table" or type(right) ~= "table" then
        return false
    end
    for key, value in pairs(left) do
        if right[key] ~= value then
            return false
        end
    end
    for key, value in pairs(right) do
        if left[key] ~= value then
            return false
        end
    end
    return true
end

local function contextMatches(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then
        return false
    end
    return left.path == right.path
        and left.manga_id == right.manga_id
        and left.manga_title == right.manga_title
        and left.in_library == right.in_library
        and left.chapter_id == right.chapter_id
        and left.chapter_name == right.chapter_name
        and sourceMatches(left.source, right.source)
end

local function candidateFromLedgerEntry(entry)
    if type(entry) ~= "table" or not entry.path then
        return nil
    end
    return {
        path = entry.path,
        manga_id = present(entry.manga_id),
        manga_title = entry.manga_title,
        in_library = entry.in_library,
        chapter_id = present(entry.chapter_id),
        chapter_name = entry.chapter_name,
    }
end

local function inferSiblingContext(path, contexts, ledger)
    local current_dir = parentDirectory(path)
    if not current_dir then
        return nil
    end

    local inferred_manga_id
    local inferred_manga_title
    local inferred_in_library
    local inferred_source
    local function consider(candidate)
        if type(candidate) ~= "table" or parentDirectory(candidate.path) ~= current_dir then
            return true
        end
        local manga_id = present(candidate.manga_id)
        if not manga_id then
            return true
        end
        if inferred_manga_id and inferred_manga_id ~= manga_id then
            return false
        end
        inferred_manga_id = manga_id
        if not inferred_source and candidate.source then
            inferred_source = candidate.source
        end
        if inferred_in_library == nil and candidate.in_library ~= nil then
            inferred_in_library = candidate.in_library
        end
        if not inferred_manga_title and candidate.manga_title then
            inferred_manga_title = candidate.manga_title
        end
        return true
    end

    for _, context in pairs(contexts or {}) do
        if consider(context) == false then
            return nil
        end
    end
    for _, entry in pairs(ledger or {}) do
        if consider(candidateFromLedgerEntry(entry)) == false then
            return nil
        end
    end

    if not inferred_manga_id then
        return nil
    end
    return {
        path = path,
        manga_id = inferred_manga_id,
        manga_title = inferred_manga_title,
        in_library = inferred_in_library,
        source = copyTable(inferred_source),
    }
end

local function normalizeContextStore(contexts)
    if type(contexts) ~= "table" then
        return {}
    end
    return contexts
end

function Methods:saveReaderReturnContext(manga, chapter, chapter_path)
    local context = buildContext(manga, chapter, chapter_path)
    if not context then
        return nil
    end

    local contexts = normalizeContextStore(SuwayomiSettings:loadReaderReturnContexts())
    contexts[chapter_path] = context
    SuwayomiSettings:saveReaderReturnContexts(contexts)
    return context
end

function Methods:saveReaderReturnContextsForChapters(manga, entries)
    if type(manga) ~= "table" or type(entries) ~= "table" or #entries == 0 then
        return {}
    end

    local contexts = normalizeContextStore(SuwayomiSettings:loadReaderReturnContexts())
    local saved = {}
    local changed = false
    for _, entry in ipairs(entries) do
        local context = entry and buildContext(manga, entry.chapter, entry.path)
        if context then
            saved[#saved + 1] = context
            if not contextMatches(contexts[context.path], context) then
                contexts[context.path] = context
                changed = true
            end
        end
    end

    if changed then
        SuwayomiSettings:saveReaderReturnContexts(contexts)
    end
    return saved
end

function Methods:getCurrentReaderDocumentPath()
    local document = self.document or (self.ui and self.ui.document)
    return (self.ui and (self.ui.document_path or self.ui.document_pathname))
        or (document and (document.file or document.filename or document.path))
        or nil
end

function Methods:getReaderReturnContextForPath(path)
    if not path or path == "" then
        return nil
    end

    local contexts = normalizeContextStore(SuwayomiSettings:loadReaderReturnContexts())
    if type(contexts[path]) == "table" then
        return contexts[path]
    end

    local ledger = SuwayomiSettings:loadChapterLedger() or {}
    for _, entry in pairs(ledger) do
        if type(entry) == "table" and entry.path == path then
            return candidateFromLedgerEntry(entry)
        end
    end
    return inferSiblingContext(path, contexts, ledger)
end

function Methods:getCurrentReaderReturnContext()
    return self:getReaderReturnContextForPath(self:getCurrentReaderDocumentPath())
end

function Methods:fetchReaderReturnChapters(context)
    if not context or not context.manga_id then
        self:showMessage(_("This book is not linked to Suwayomi chapters."))
        return nil
    end

    self:showMessage(_("Chapters are loading."))
    return nil
end

function Methods:startReaderReturnChapterRequest(context)
    if not context or not context.manga_id then
        self:showMessage(_("This book is not linked to Suwayomi chapters."))
        return false
    end

    local previous = self.active_reader_return_request
    if previous and previous.active and NetworkRequestJob.cancel then
        NetworkRequestJob.cancel(previous.active)
    end

    local request_token = {
        path = context.path,
    }
    self.active_reader_return_request = request_token

    local credentials = SuwayomiSettings:load()
    local active = NetworkRequestJob.start({
        owner = self,
        credentials = credentials,
        request = {
            action = "fetch_chapters_for_manga",
            manga_id = context.manga_id,
        },
        loading_message = _("Loading chapters..."),
        result_prefix = "reader_return_chapters",
        timeout_seconds = self.reader_return_timeout_seconds or 30,
        timeout_message = _("Could not load chapters."),
        on_cancel = function()
            if self.active_reader_return_request == request_token then
                self.active_reader_return_request = nil
            end
        end,
        on_finish = function(result)
            if self.active_reader_return_request ~= request_token then
                return
            end
            if not contextMatches(self:getCurrentReaderReturnContext(), context) then
                self.active_reader_return_request = nil
                return
            end
            if not result then
                self.active_reader_return_request = nil
                return
            end
            if not result.ok then
                self.active_reader_return_request = nil
                self:showMessage(_(result.error))
                return
            end
            if not result.chapters or #result.chapters == 0 then
                self.active_reader_return_request = nil
                self:showMessage(_("This manga has no chapters."))
                return
            end

            local manga = {
                id = context.manga_id,
                title = context.manga_title or context.manga_id,
                in_library = context.in_library,
                source = copyTable(context.source),
            }
            self:closeReaderToFileManager(function()
                if self.active_reader_return_request == request_token then
                    self.active_reader_return_request = nil
                end
                self:showChapterResultForManga(manga, result, {
                    return_context = context,
                    reader_return_close_target = self.buildReaderReturnCloseTarget
                        and self:buildReaderReturnCloseTarget(context, manga)
                        or nil,
                })
            end, function()
                if self.active_reader_return_request ~= request_token then
                    return false
                end
                if not contextMatches(self:getCurrentReaderReturnContext(), context) then
                    self.active_reader_return_request = nil
                    return false
                end
                return true
            end)
        end,
    })
    if not active then
        if self.active_reader_return_request == request_token then
            self.active_reader_return_request = nil
        end
        return false
    end
    if self.active_reader_return_request == request_token then
        request_token.active = active
    end
    return true
end

function Methods:closeReaderToFileManager(callback, should_continue)
    UIManager:nextTick(function()
        if should_continue and not should_continue() then
            return
        end

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

    return self:startReaderReturnChapterRequest(context)
end

ReaderReturn.methods = Methods

return ReaderReturn
