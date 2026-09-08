-- Boundary: MangaActionMenu.
--
-- Responsibility: Owns shared manga-level action definitions used by manga rows and chapter-list title menus.
-- Owned state: none; action execution stays on plugin controller methods.
-- Dependencies: suwayomi/i18n.
-- External data: manga and chapter state come from callers and remain untrusted until controller methods validate them.

local I18n = require("suwayomi/i18n")

local MangaActionMenu = {}

local function isContextForManga(context, manga)
    if type(context) ~= "table" or type(manga) ~= "table" then
        return false
    end
    if context.manga == manga then
        return true
    end
    return context.manga and tostring(context.manga.id) == tostring(manga.id)
end

local function getFirstUnreadFromContext(owner, manga)
    local context = owner and owner.current_chapter_context
    if not isContextForManga(context, manga) then
        return nil, false
    end
    local chapters = context.chapters or {}
    if owner.getVisibleChapters then
        chapters = owner:getVisibleChapters(chapters) or {}
    end
    for _index, chapter in ipairs(chapters) do
        if chapter.is_read ~= true then
            return chapter, true
        end
    end
    return nil, true
end

local function canOpenFirstUnread(owner, manga)
    local chapter, has_context = getFirstUnreadFromContext(owner, manga)
    if not chapter and not has_context then
        chapter = manga and manga.first_unread_chapter
    end
    if not chapter or not owner or not owner.isChapterDownloaded then
        return false
    end
    return owner:isChapterDownloaded(manga, chapter) == true
end

MangaActionMenu.canOpenFirstUnread = canOpenFirstUnread

local function hasVisibleChapters(owner)
    local context = owner and owner.current_chapter_context
    if not context or type(context.chapters) ~= "table" then
        return false
    end
    if owner.getVisibleChapters then
        return #(owner:getVisibleChapters(context.chapters) or {}) > 0
    end
    return #context.chapters > 0
end

function MangaActionMenu.buildMainActions(owner, manga, options)
    options = options or {}
    local actions = {}
    local destructive_library_action

    if options.include_open_chapters then
        table.insert(actions, { id = "open_chapters", text = I18n.t("Open chapters") })
    end
    if options.include_select_all and hasVisibleChapters(owner) then
        table.insert(actions, { id = "select_all", text = I18n.t("Select all") })
    end
    table.insert(actions, { id = "manga_information", text = I18n.t("Manga information") })
    if canOpenFirstUnread(owner, manga) then
        table.insert(actions, { id = "open_first_unread", text = I18n.t("Open first unread") })
    end

    table.insert(actions, { id = "refresh_chapters", text = I18n.t("Refresh chapters") })
    if manga and manga.id then
        if manga.in_library == true then
            destructive_library_action = { id = "remove_from_library", text = I18n.t("Remove from library"), destructive = true }
        else
            table.insert(actions, { id = "add_to_library", text = I18n.t("Add to library") })
        end
    end
    table.insert(actions, { id = "bulk_downloads", text = I18n.t("Bulk downloads"), submenu = true })
    table.insert(actions, { id = "keep_downloaded", text = I18n.t("Download ahead"), submenu = true })
    table.insert(actions, { id = "delete_read_downloaded", text = I18n.t("Delete read downloads"), destructive = true })
    if destructive_library_action then
        table.insert(actions, destructive_library_action)
    end

    return actions
end

function MangaActionMenu.buildBulkDownloadActions()
    return {
        { id = "download_first_unread", text = I18n.t("Download first unread") },
        { id = "download_next_5_unread", text = I18n.t("Download next 5") },
        { id = "download_next_10_unread", text = I18n.t("Download next 10") },
        { id = "download_next_50_unread", text = I18n.t("Download next 50") },
        { id = "download_all_unread", text = I18n.t("Download all unread (up to 50 new)") },
        { id = "download_all_chapters", text = I18n.t("Download all chapters (up to 50 new)") },
    }
end

function MangaActionMenu.buildKeepDownloadedActions()
    return {
        { id = "keep_next_5_unread", text = I18n.t("Keep first 5 unread") },
        { id = "keep_next_10_unread", text = I18n.t("Keep first 10 unread") },
        { id = "keep_next_50_unread", text = I18n.t("Keep first 50 unread") },
        { id = "keep_next_0_unread", text = I18n.t("Stop download ahead") },
    }
end

function MangaActionMenu.isSharedAction(action_id)
    if action_id == "manga_information"
        or action_id == "open_first_unread"
        or action_id == "refresh_chapters"
        or action_id == "add_to_library"
        or action_id == "remove_from_library"
        or action_id == "delete_read_downloaded"
        or action_id == "download_first_unread"
        or action_id == "download_all_unread"
        or action_id == "download_all_chapters"
        or action_id == "keep_downloaded"
    then
        return true
    end
    if tostring(action_id or ""):match("^download_next_%d+_unread$") then
        return true
    end
    if tostring(action_id or ""):match("^keep_next_%d+_unread$") then
        return true
    end
    return false
end

return MangaActionMenu
