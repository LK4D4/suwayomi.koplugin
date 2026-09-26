-- Boundary: ReaderReturn.
--
-- Responsibility: Persist return context, resolve legacy listing metadata, and hand return to the live FileManager.
-- Owned state: Settings-backed return contexts keyed by local chapter path and a cancellable deferred handoff.
-- Dependencies: KOReader reader/filemanager UI modules, Suwayomi settings, plugin i18n facade, and chapter menu methods.
-- External data: Document paths and persisted contexts are optional; scope and freshness gate reader teardown/publication.

local SuwayomiSettings = require("suwayomi/settings")
local UIManager = require("ui/uimanager")
local I18n = require("suwayomi/i18n")

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

local function buildContext(manga, chapter, chapter_path, endpoint_scope)
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
        source_order = chapter.source_order,
        chapter_number = chapter.chapter_number,
        scanlator = chapter.scanlator,
        thumbnail_url = manga.thumbnail_url,
        source = copyTable(manga.source),
        endpoint_scope = endpoint_scope,
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
        and left.source_order == right.source_order
        and left.chapter_number == right.chapter_number
        and left.scanlator == right.scanlator
        and left.thumbnail_url == right.thumbnail_url
        and left.endpoint_scope == right.endpoint_scope
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
        source_order = entry.source_order,
        chapter_number = entry.chapter_number,
        scanlator = entry.scanlator,
        thumbnail_url = entry.thumbnail_url,
        source = copyTable(entry.source),
        endpoint_scope = entry.endpoint_scope,
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
    local inferred_endpoint_scope
    local inferred_thumbnail_url
    local function consider(candidate)
        if type(candidate) ~= "table" or parentDirectory(candidate.path) ~= current_dir then
            return true
        end
        local manga_id = present(candidate.manga_id)
        if not manga_id then
            return true
        end
        if inferred_manga_id and (inferred_manga_id ~= manga_id
            or inferred_endpoint_scope ~= candidate.endpoint_scope)
        then
            return false
        end
        inferred_manga_id = manga_id
        inferred_endpoint_scope = candidate.endpoint_scope
        inferred_thumbnail_url = inferred_thumbnail_url or candidate.thumbnail_url
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
        endpoint_scope = inferred_endpoint_scope,
        thumbnail_url = inferred_thumbnail_url,
    }
end

local function matchesListingManga(context, manga, scope)
    return type(manga) == "table" and not manga.local_only
        and (not manga.endpoint_scope or manga.endpoint_scope == scope)
        and present(manga.id) == present(context.manga_id)
        and present(manga.title) == present(context.manga_title)
        and type(manga.source) == "table"
        and present(manga.source.id) == present(context.source.id)
end

local function resolveLegacyListing(context)
    if present(context.endpoint_scope) or not present(context.manga_id)
        or not present(context.chapter_id) or not present(context.manga_title)
        or type(context.source) ~= "table" or not present(context.source.id) then return nil end
    local credentials = SuwayomiSettings:load()
    local scope = SuwayomiSettings:normalizeEndpointScope(credentials.server_url)
    if not scope then return nil end
    for _, records in ipairs({ SuwayomiSettings:loadReaderReturnContexts(), SuwayomiSettings:loadChapterLedger() }) do
        for _, record in pairs(type(records) == "table" and records or {}) do
            if type(record) == "table" and record.path == context.path
                and present(record.endpoint_scope) and record.endpoint_scope ~= scope then return nil end
        end
    end
    local listing = SuwayomiSettings.loadChapterCache
        and SuwayomiSettings:loadChapterCache(credentials, { id = context.manga_id })
    local library = SuwayomiSettings.loadLibraryCache and SuwayomiSettings:loadLibraryCache(credentials)
    local manga = listing and listing.manga
    if manga and not matchesListingManga(context, manga, scope) then return nil end
    for _, candidate in ipairs(library and library.manga or {}) do
        if present(candidate.id) == present(context.manga_id) then
            if not matchesListingManga(context, candidate, scope) then return nil end
            manga = candidate
        end
    end
    if not manga then return nil end
    for _, chapter in ipairs(listing and listing.chapters or {}) do
        if present(chapter.id) == present(context.chapter_id) then
            for _, pair in ipairs({ { "name", "chapter_name" }, { "source_order", "source_order" },
                { "chapter_number", "chapter_number" }, { "scanlator", "scanlator" } }) do
                if context[pair[2]] ~= nil and chapter[pair[1]] ~= context[pair[2]] then return nil end
            end
        end
    end
    -- This selects a server listing; it never associates the legacy archive or its reads.
    manga = copyTable(manga)
    manga.endpoint_scope = scope
    return manga
end

local function buildReturnedManga(context)
    local listing_manga = resolveLegacyListing(context)
    if listing_manga then return listing_manga end
    return {
        id = context.manga_id,
        title = context.manga_title or context.manga_id,
        in_library = context.in_library,
        source = copyTable(context.source),
        thumbnail_url = context.thumbnail_url,
        endpoint_scope = context.endpoint_scope,
        local_only = not present(context.endpoint_scope) or not present(context.manga_id) or nil,
        local_manga_path = not present(context.manga_id) and parentDirectory(context.path) or nil,
    }
end

local function normalizeContextStore(contexts)
    if type(contexts) ~= "table" then
        return {}
    end
    local cloned = {}
    for k, v in pairs(contexts) do
        cloned[k] = v
    end
    return cloned
end

function Methods:saveReaderReturnContext(manga, chapter, chapter_path)
    local context = buildContext(manga, chapter, chapter_path, manga and manga.endpoint_scope)
    if not context then
        return nil
    end

    local contexts = normalizeContextStore(SuwayomiSettings:loadReaderReturnContexts())
    contexts[chapter_path] = context
    local ok, err = SuwayomiSettings:saveReaderReturnContexts(contexts)
    if not ok then
        return nil, err
    end
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
        local previous = entry and contexts[entry.path]
        local context = entry and buildContext(manga, entry.chapter, entry.path,
            previous and previous.endpoint_scope)
        if context then
            saved[#saved + 1] = context
            if not contextMatches(contexts[context.path], context) then
                contexts[context.path] = context
                changed = true
            end
        end
    end

    if changed then
        local ok, err = SuwayomiSettings:saveReaderReturnContexts(contexts)
        if not ok then
            return {}, err
        end
    end
    return saved
end

local function readerDocumentPath(owner)
    if type(owner) ~= "table" then
        return nil
    end
    local document = owner.document
    return owner.document_path
        or owner.document_pathname
        or (document and (document.file or document.filename or document.path))
end

function Methods:getCurrentReaderDocumentPath()
    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    local active_path = ok_reader and ReaderUI and readerDocumentPath(ReaderUI.instance)
    return active_path or readerDocumentPath(self.ui)
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

function Methods:cancelReaderReturnRequest()
    local request = self.active_reader_return_request
    if not request then
        return false
    end

    self.active_reader_return_request = nil
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

        local destination = ok_filemanager and FileManager.instance and FileManager.instance.suwayomi
        if callback and destination and destination.ui == FileManager.instance
            and not destination.suwayomi_host_retired and destination.showChaptersForManga
        then
            callback(destination)
        end
    end)
end

function Methods:returnToSuwayomiChapters(context)
    if self.suwayomi_host_retired then return false end
    context = copyTable(context or self:getCurrentReaderReturnContext())
    if not context or not context.path then
        self:showMessage(I18n.t("This book is not linked to Suwayomi chapters."))
        return false
    end

    local endpoint_scope = SuwayomiSettings:normalizeEndpointScope(SuwayomiSettings:load().server_url)
    if present(context.endpoint_scope) and context.endpoint_scope ~= endpoint_scope then
        return false
    end
    if not contextMatches(self:getCurrentReaderReturnContext(), context) then return false end
    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    local reader = ok_reader and ReaderUI.instance
    if not reader or reader ~= self.ui or not reader.onClose then return false end

    if self.cancelMangaNetworkRequests then self:cancelMangaNetworkRequests() end
    local request_token = {}
    self.active_reader_return_request = request_token
    if self.scheduleFinishedChapterCleanup then
        self:scheduleFinishedChapterCleanup(0)
    end
    self:closeReaderToFileManager(function(destination)
        if endpoint_scope ~= SuwayomiSettings:normalizeEndpointScope(SuwayomiSettings:load().server_url) then return end
        if ReaderUI.instance or not contextMatches(self:getReaderReturnContextForPath(context.path), context) then
            return
        end
        local manga = buildReturnedManga(context)
        destination:showChaptersForManga(manga, {
            return_context = context,
            reader_return_close_target = self.buildReaderReturnCloseTarget
                and self:buildReaderReturnCloseTarget(context, manga)
                or nil,
        })
    end, function()
        if self.suwayomi_host_retired or self.active_reader_return_request ~= request_token then
            return false
        end
        if endpoint_scope ~= SuwayomiSettings:normalizeEndpointScope(SuwayomiSettings:load().server_url)
            or ReaderUI.instance ~= reader
            or not contextMatches(self:getCurrentReaderReturnContext(), context)
        then
            self.active_reader_return_request = nil
            return false
        end
        -- Intentional native close saves progress and retires the reader host.
        self.active_reader_return_request = nil
        return true
    end)
    return true
end

ReaderReturn.methods = Methods

return ReaderReturn
