-- Boundary: Downloads hub menu UI.
--
-- Responsibility: format active, queued, failed, and completed download rows and
-- wire row callbacks to the downloads controller.
-- Owned state: none.
-- Dependencies: shared list menu widget, gettext, and shared menu utilities.
-- External data: queue snapshots are display-only here; controller actions own
-- retries, cancellation, deletion, and navigation.

local _ = require("gettext")
local menu_utils = require("suwayomi/ui/menu_utils")

local DownloadsUI = {}

local function getListMenu()
    return require("suwayomi/ui/list_menu")
end

local function shortenMenuText(text, max_chars)
    text = tostring(text or "")
    max_chars = max_chars or 96
    if #text <= max_chars then
        return text
    end
    return text:sub(1, max_chars - 3) .. "..."
end

local function formatDownloadJobLabel(job)
    local manga_title = job and job.manga and job.manga.title or nil
    local chapter_name = job and job.chapter and job.chapter.name or nil
    local label = manga_title or tostring(job and job.key or "")
    if chapter_name and chapter_name ~= "" then
        label = label .. " / " .. chapter_name
    end
    return label
end

local function formatDownloadProgress(job)
    local progress = job and job.progress or nil
    local current = progress and tonumber(progress.current) or nil
    local total = progress and tonumber(progress.total) or nil
    if current and total and total > 0 then
        return tostring(current) .. "/" .. tostring(total)
    end
    return ""
end

local function formatFailedDownloadText(job)
    local error_message = job and job.progress and job.progress.error or nil
    if error_message and error_message ~= "" then
        return shortenMenuText(error_message)
    end
    return nil
end

local function isDownloadsSnapshotEmpty(snapshot)
    return #(snapshot.active or {}) == 0
        and #(snapshot.queued or {}) == 0
        and #(snapshot.failed or {}) == 0
end

local function appendEmptyStateRows(menu_table, snapshot, options)
    local active_count = #(snapshot.active or {})
    local queued_count = #(snapshot.queued or {})
    local failed_count = #(snapshot.failed or {})
    local folder = options.download_directory_summary
    if not folder or folder == "" then
        folder = _("not set")
    end

    table.insert(menu_table, {
        text = _("Download folder"),
        subtitle = folder,
        select_enabled = false,
    })
    table.insert(menu_table, {
        text = _("Queue"),
        subtitle = tostring(active_count) .. " active, "
            .. tostring(queued_count) .. " queued, "
            .. tostring(failed_count) .. " failed",
        select_enabled = false,
    })
    table.insert(menu_table, {
        text = _("No downloads queued."),
        select_enabled = false,
    })
end

function DownloadsUI.buildDownloadsMenuTable(snapshot, callbacks, options)
    snapshot = snapshot or {}
    callbacks = callbacks or {}
    options = options or {}
    local menu_table = {}

    if isDownloadsSnapshotEmpty(snapshot) then
        appendEmptyStateRows(menu_table, snapshot, options)
        return menu_table
    end

    for _, job in ipairs(snapshot.active or {}) do
        local progress = formatDownloadProgress(job)
        local prefix = progress ~= "" and ("Downloading " .. progress) or "Downloading"
        table.insert(menu_table, {
            text = shortenMenuText(formatDownloadJobLabel(job)),
            mandatory = prefix,
            callback = callbacks.onSelectActive and function(menu)
                callbacks.onSelectActive(job, menu)
            end or nil,
        })
    end

    local queued_label = _("Queued")
    for _, job in ipairs(snapshot.queued or {}) do
        table.insert(menu_table, {
            text = shortenMenuText(formatDownloadJobLabel(job)),
            mandatory = queued_label,
            callback = function(menu)
                if callbacks.onSelectQueued then
                    callbacks.onSelectQueued(job, menu)
                end
            end,
        })
    end

    local failed_label = _("Failed")
    for _, job in ipairs(snapshot.failed or {}) do
        table.insert(menu_table, {
            text = shortenMenuText(formatDownloadJobLabel(job)),
            subtitle = formatFailedDownloadText(job),
            mandatory = failed_label,
            callback = function(menu)
                if callbacks.onRetryFailed then
                    callbacks.onRetryFailed(job, menu)
                end
            end,
        })
    end

    if #(snapshot.failed or {}) > 0 then
        table.insert(menu_table, {
            text = _("Clear failed"),
            callback = function(menu)
                if callbacks.onClearFailed then
                    callbacks.onClearFailed(menu)
                end
            end,
        })
    end

    return menu_table
end

function DownloadsUI.showDownloadsMenu(snapshot, callbacks, options)
    options = options or {}
    local menu_options = {
        title = options.title or _("Suwayomi Downloads"),
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = DownloadsUI.buildDownloadsMenuTable(snapshot, callbacks, options),
        close_callback = options.close_callback,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
    }
    local menu = getListMenu().show(menu_options)
    menu_utils.bindMenuCallbacks(menu.item_table, menu)
    return menu
end

return DownloadsUI
