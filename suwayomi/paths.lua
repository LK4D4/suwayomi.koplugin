-- Boundary: source-scoped download path layout.
--
-- Responsibility: sanitize path segments and build manga/chapter paths using
-- the supported <download>/<source>/<manga>/<chapter>.cbz layout.
-- Owned state: none.
-- Dependencies: KOReader ffi/util path join helper.
-- External data: source, manga, and chapter labels are sanitized before becoming
-- filesystem path segments.

local FFIUtil = require("ffi/util")

local SuwayomiPaths = {}

local function normalizeDownloadDirectory(download_directory)
    if type(download_directory) ~= "string" or download_directory == "" then
        return nil
    end
    return download_directory
end

local function present(value)
    value = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then
        return nil
    end
    return value
end

local function appendUnique(list, seen, value)
    if value and value ~= "" and not seen[value] then
        seen[value] = true
        table.insert(list, value)
    end
end

function SuwayomiPaths.sanitizePathSegment(name)
    local sanitized = tostring(name or "")
        :gsub("%c+", " ")
        :gsub("[\\/:*?\"<>|]", "_")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
    if sanitized == "" or sanitized == "." or sanitized == ".." then
        return "untitled"
    end
    return sanitized
end

function SuwayomiPaths.getSourceLabel(manga)
    local source = manga and manga.source or {}
    local display_name = present(source.displayName) or present(source.display_name)
    if display_name then
        return display_name
    end

    local name = present(source.name) or present(source.raw_name)
    if name then
        local lang = present(source.lang)
        if lang and lang ~= "localsourcelang" then
            local lang_suffix = "%(" .. string.upper(lang) .. "%)$"
            if name:match(lang_suffix) then
                return name
            end
            return name .. " (" .. string.upper(lang) .. ")"
        end
        return name
    end

    return present(source.id) or "Unknown source"
end

function SuwayomiPaths.getMangaDirectory(download_directory, manga)
    download_directory = normalizeDownloadDirectory(download_directory)
    if not download_directory then
        return nil
    end
    local source_dir = FFIUtil.joinPath(download_directory, SuwayomiPaths.sanitizePathSegment(SuwayomiPaths.getSourceLabel(manga)))
    return FFIUtil.joinPath(source_dir, SuwayomiPaths.sanitizePathSegment(manga and manga.title))
end

function SuwayomiPaths.getChapterFilename(chapter)
    return SuwayomiPaths.getChapterFilenames(chapter)[1]
end

function SuwayomiPaths.getChapterFilenames(chapter)
    local name = SuwayomiPaths.sanitizePathSegment(chapter and chapter.name)
    local filenames = {}
    local seen = {}
    local plain = name .. ".cbz"
    local id = chapter and present(chapter.id)
    local source_order = chapter and present(chapter.source_order)
    local chapter_number = chapter and present(chapter.chapter_number)

    local function addStable(label, value)
        if value then
            appendUnique(filenames, seen, name .. " [" .. label .. "-" .. SuwayomiPaths.sanitizePathSegment(value) .. "].cbz")
        end
    end

    -- Keep current collision-safe target first, then recognize older local names.
    if id then
        addStable("id", id)
    elseif source_order then
        addStable("order", source_order)
    elseif chapter_number then
        addStable("chapter", chapter_number)
    end

    appendUnique(filenames, seen, plain)

    if id then
        addStable("order", source_order)
        addStable("chapter", chapter_number)
    elseif source_order then
        addStable("chapter", chapter_number)
    end

    return filenames
end

function SuwayomiPaths.getChapterPath(download_directory, manga, chapter)
    local manga_dir = SuwayomiPaths.getMangaDirectory(download_directory, manga)
    if not manga_dir then
        return nil
    end
    return FFIUtil.joinPath(
        manga_dir,
        SuwayomiPaths.getChapterFilename(chapter)
    )
end

function SuwayomiPaths.getChapterPathCandidates(download_directory, manga, chapter)
    local manga_dir = SuwayomiPaths.getMangaDirectory(download_directory, manga)
    if not manga_dir then
        return {}
    end

    local candidates = {}
    for _, filename in ipairs(SuwayomiPaths.getChapterFilenames(chapter)) do
        table.insert(candidates, FFIUtil.joinPath(manga_dir, filename))
    end
    return candidates
end

function SuwayomiPaths.getTargetPath(download_directory, manga, chapter)
    local manga_dir = SuwayomiPaths.getMangaDirectory(download_directory, manga)
    if not manga_dir then
        return nil, nil
    end
    local chapter_path = FFIUtil.joinPath(
        manga_dir,
        SuwayomiPaths.getChapterFilename(chapter)
    )
    return manga_dir, chapter_path
end

return SuwayomiPaths
