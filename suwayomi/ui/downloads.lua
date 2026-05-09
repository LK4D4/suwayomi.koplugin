-- Boundary: Downloads hub menu UI.
--
-- Responsibility: format active, queued, failed, and completed download rows and
-- wire row callbacks to the downloads controller.
-- Owned state: none.
-- Dependencies: KOReader Menu widget, gettext, and shared menu utilities.
-- External data: queue snapshots are display-only here; controller actions own
-- retries, cancellation, deletion, and navigation.

local Menu = require("ui/widget/menu")
local _ = require("gettext")
local menu_utils = require("suwayomi/ui/menu_utils")

local DownloadsUI = {}

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
    local text = "Failed  " .. formatDownloadJobLabel(job)
    local error_message = job and job.progress and job.progress.error or nil
    if error_message and error_message ~= "" then
        text = text .. " - " .. tostring(error_message)
    end
    return shortenMenuText(text)
end

function DownloadsUI.buildDownloadsMenuTable(snapshot, callbacks)
    snapshot = snapshot or {}
    callbacks = callbacks or {}
    local menu_table = {}

    for _, job in ipairs(snapshot.active or {}) do
        local progress = formatDownloadProgress(job)
        local prefix = progress ~= "" and ("Downloading " .. progress) or "Downloading"
        table.insert(menu_table, {
            text = shortenMenuText(prefix .. "  " .. formatDownloadJobLabel(job)),
            callback = callbacks.onSelectActive and function(menu)
                callbacks.onSelectActive(job, menu)
            end or nil,
        })
    end

    for _, job in ipairs(snapshot.queued or {}) do
        table.insert(menu_table, {
            text = shortenMenuText("Queued  " .. formatDownloadJobLabel(job)),
            callback = function(menu)
                if callbacks.onSelectQueued then
                    callbacks.onSelectQueued(job, menu)
                end
            end,
        })
    end

    for _, job in ipairs(snapshot.failed or {}) do
        table.insert(menu_table, {
            text = formatFailedDownloadText(job),
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
    local menu = Menu:new{
        title = _("Suwayomi Downloads"),
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = DownloadsUI.buildDownloadsMenuTable(snapshot, callbacks),
    }
    menu_utils.applyTitleBarOptions(menu, options)
    menu_utils.bindMenuCallbacks(menu.item_table, menu)
    local UIManager = require("ui/uimanager")
    UIManager:show(menu)
    return menu
end

return DownloadsUI
