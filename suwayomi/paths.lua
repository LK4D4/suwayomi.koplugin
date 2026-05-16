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

local function present(value)
    value = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then
        return nil
    end
    return value
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
    local source_dir = FFIUtil.joinPath(download_directory, SuwayomiPaths.sanitizePathSegment(SuwayomiPaths.getSourceLabel(manga)))
    return FFIUtil.joinPath(source_dir, SuwayomiPaths.sanitizePathSegment(manga and manga.title))
end

function SuwayomiPaths.getChapterFilename(chapter)
    local name = SuwayomiPaths.sanitizePathSegment(chapter and chapter.name)
    if chapter and chapter.id ~= nil and tostring(chapter.id) ~= "" then
        return name .. " [id-" .. SuwayomiPaths.sanitizePathSegment(chapter.id) .. "].cbz"
    end
    if chapter and chapter.source_order ~= nil and tostring(chapter.source_order) ~= "" then
        return name .. " [order-" .. SuwayomiPaths.sanitizePathSegment(chapter.source_order) .. "].cbz"
    end
    if chapter and chapter.chapter_number ~= nil and tostring(chapter.chapter_number) ~= "" then
        return name .. " [chapter-" .. SuwayomiPaths.sanitizePathSegment(chapter.chapter_number) .. "].cbz"
    end
    return name .. ".cbz"
end

function SuwayomiPaths.getChapterPath(download_directory, manga, chapter)
    return FFIUtil.joinPath(
        SuwayomiPaths.getMangaDirectory(download_directory, manga),
        SuwayomiPaths.getChapterFilename(chapter)
    )
end

function SuwayomiPaths.getTargetPath(download_directory, manga, chapter)
    local manga_dir = SuwayomiPaths.getMangaDirectory(download_directory, manga)
    local chapter_path = FFIUtil.joinPath(
        manga_dir,
        SuwayomiPaths.getChapterFilename(chapter)
    )
    return manga_dir, chapter_path
end

return SuwayomiPaths
