-- Boundary: stateless chapter-download text formatting.
--
-- Responsibility: build compact read/download labels used in chapter menus
-- and produce user-facing failure labels.
-- Owned state: none.
-- Injected dependencies: shared i18n facade only.
-- External data: manga/chapter/status tables from Suwayomi and persisted queue
-- state; values are converted defensively before formatting.

local I18n = require("suwayomi/i18n")

local StatusFormatter = {}

StatusFormatter.CHAPTER_TITLE_WITH_STATUS_MAX_CHARS = 58

function StatusFormatter.splitUtf8Chars(text)
    local chars = {}
    text = tostring(text or "")
    local index = 1
    while index <= #text do
        local byte = text:byte(index)
        local length = 1
        if byte and byte >= 0xF0 then
            length = 4
        elseif byte and byte >= 0xE0 then
            length = 3
        elseif byte and byte >= 0xC0 then
            length = 2
        end
        table.insert(chars, text:sub(index, index + length - 1))
        index = index + length
    end
    return chars
end

function StatusFormatter.shortenChapterTitle(title, reserved_chars, max_title_chars)
    local max_chars = (max_title_chars or StatusFormatter.CHAPTER_TITLE_WITH_STATUS_MAX_CHARS) - (reserved_chars or 0)
    if max_chars < 12 then
        max_chars = 12
    end

    local chars = StatusFormatter.splitUtf8Chars(title)
    if #chars <= max_chars then
        return title
    end

    local shortened = {}
    for index = 1, max_chars - 1 do
        table.insert(shortened, chars[index])
    end
    table.insert(shortened, "…")
    return table.concat(shortened)
end

function StatusFormatter.joinChapterStatusSymbols(symbols)
    if not symbols or #symbols == 0 then
        return nil
    end
    return I18n.join(symbols, " · ")
end

function StatusFormatter.formatChapterStatusSymbols(chapter, symbols, max_title_chars)
    if not symbols or #symbols == 0 then
        return chapter.name
    end
    local suffix = table.concat(symbols, " ")
    local title = StatusFormatter.shortenChapterTitle(
        chapter.name,
        #StatusFormatter.splitUtf8Chars(suffix) + 2,
        max_title_chars
    )
    return title .. "  " .. suffix
end

function StatusFormatter.buildChapterStatusSymbols(chapter, status)
    local symbols = {}
    if chapter and chapter.is_read == true then
        table.insert(symbols, I18n.t("Read"))
    end

    if not status then
        return symbols
    end
    if status.state == "queued" then
        table.insert(symbols, I18n.t("Queued"))
        return symbols
    end
    if status.state == "downloading" then
        if status.total and status.total > 0 and status.current then
            table.insert(symbols, I18n.f("Downloading %1/%2", status.current, status.total))
            return symbols
        end
        table.insert(symbols, I18n.t("Downloading"))
        return symbols
    end
    if status.state == "downloaded" or status.state == "skipped" then
        table.insert(symbols, I18n.t("Downloaded"))
        return symbols
    end
    if status.state == "read" then
        if #symbols == 0 then
            table.insert(symbols, I18n.t("Read"))
        end
        return symbols
    end
    if status.state == "failed" then
        table.insert(symbols, I18n.t("Failed"))
        return symbols
    end
    return symbols
end

function StatusFormatter.formatChapterMenuStatus(chapter, status)
    return StatusFormatter.joinChapterStatusSymbols(StatusFormatter.buildChapterStatusSymbols(chapter, status))
end

function StatusFormatter.formatChapterMenuText(chapter, status, max_title_chars)
    local symbols = StatusFormatter.buildChapterStatusSymbols(chapter, status)
    return StatusFormatter.formatChapterStatusSymbols(chapter, symbols, max_title_chars)
end

function StatusFormatter.formatChapterNumber(value)
    local number = tonumber(value)
    if not number then
        return tostring(value)
    end
    if number == math.floor(number) then
        return tostring(math.floor(number))
    end
    return tostring(number)
end

function StatusFormatter.formatFailureMessage(manga, chapter, detail, fallback_key)
    local label_parts = {}
    if manga and manga.title and manga.title ~= "" then
        table.insert(label_parts, manga.title)
    end
    if chapter and chapter.name and chapter.name ~= "" then
        table.insert(label_parts, chapter.name)
    end

    local label = table.concat(label_parts, " / ")
    if label == "" then
        label = fallback_key or ""
    end

    local chapter_suffix = ""
    if chapter and chapter.chapter_number ~= nil and tostring(chapter.chapter_number) ~= "" then
        chapter_suffix = I18n.f(" (Ch. %1)", StatusFormatter.formatChapterNumber(chapter.chapter_number))
    elseif chapter and chapter.id and chapter.id ~= "" then
        chapter_suffix = I18n.f(" (Suwayomi id %1)", chapter.id)
    end

    local failure_detail = tostring(detail or "")
    if failure_detail == "" then
        failure_detail = I18n.t("Chapter download failed.")
    end

    return I18n.f("Could not download \"%1\"%2: %3", label, chapter_suffix, failure_detail)
end

return StatusFormatter
