-- Boundary: Downloads hub menu UI.
--
-- Responsibility: format active, queued, and failed download rows and
-- wire row callbacks to the downloads controller.
-- Owned state: none.
-- Dependencies: shared list menu widget, plugin i18n facade, and shared menu
-- utilities.
-- External data: queue snapshots are display-only here; controller actions own
-- retries, cancellation, deletion, and navigation.

local I18n = require("suwayomi/i18n")
local menu_utils = require("suwayomi/ui/menu_utils")

local DownloadsUI = {}

local function getListMenu()
    return require("suwayomi/ui/list_menu")
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
        return tostring(error_message)
    end
    return nil
end

local function isDownloadsSnapshotEmpty(snapshot)
    return #(snapshot.active or {}) == 0
        and #(snapshot.queued or {}) == 0
        and #(snapshot.failed or {}) == 0
end

local function buildMenuOptions(snapshot, callbacks, options)
    options = options or {}
    return {
        title = options.title or I18n.t("Suwayomi Downloads"),
        title_bar_left_icon = options.title_bar_left_icon,
        item_table = DownloadsUI.buildDownloadsMenuTable(snapshot, callbacks, options),
        close_callback = options.close_callback,
        on_title_bar_left_tap = options.on_title_bar_left_tap,
        on_title_bar_left_hold = options.on_title_bar_left_hold,
    }
end

local function appendEmptyStateRows(menu_table, snapshot, options)
    local active_count = #(snapshot.active or {})
    local queued_count = #(snapshot.queued or {})
    local failed_count = #(snapshot.failed or {})
    local folder = options.download_directory_summary
    local has_folder = folder and folder ~= ""
    if not has_folder then
        folder = I18n.t("not set")
    end

    table.insert(menu_table, {
        text = I18n.t("Download folder"),
        subtitle = folder,
        select_enabled = false,
    })
    table.insert(menu_table, {
        text = I18n.t("Queue"),
        -- Translators: %1 active downloads, %2 queued downloads, %3 failed downloads.
        subtitle = I18n.f("%1 active, %2 queued, %3 failed", active_count, queued_count, failed_count),
        select_enabled = false,
    })
    table.insert(menu_table, {
        text = I18n.t("No downloads queued."),
        select_enabled = false,
    })
    table.insert(menu_table, {
        text = has_folder
            and I18n.f("Downloaded chapters are in %1.", folder)
            or I18n.t("Set a download folder in Settings > Downloads."),
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
        local prefix = progress ~= ""
            and I18n.f("Downloading %1", progress)
            or I18n.t("Downloading")
        table.insert(menu_table, {
            text = formatDownloadJobLabel(job),
            mandatory = prefix,
            callback = callbacks.onSelectActive and function(menu)
                callbacks.onSelectActive(job, menu)
            end or nil,
        })
    end

    local queued_label = I18n.t("Queued")
    for _, job in ipairs(snapshot.queued or {}) do
        table.insert(menu_table, {
            text = formatDownloadJobLabel(job),
            mandatory = queued_label,
            callback = function(menu)
                if callbacks.onSelectQueued then
                    callbacks.onSelectQueued(job, menu)
                end
            end,
        })
    end

    local failed_label = I18n.t("Failed")
    for _, job in ipairs(snapshot.failed or {}) do
        table.insert(menu_table, {
            text = formatDownloadJobLabel(job),
            subtitle = formatFailedDownloadText(job),
            mandatory = failed_label,
            callback = function(menu)
                if callbacks.onSelectFailed then
                    callbacks.onSelectFailed(job, menu)
                elseif callbacks.onRetryFailed then
                    callbacks.onRetryFailed(job, menu)
                end
            end,
        })
    end

    if #(snapshot.failed or {}) > 0 then
        table.insert(menu_table, {
            text = I18n.t("Clear failed"),
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
    local menu_options = buildMenuOptions(snapshot, callbacks, options)
    local menu = getListMenu().show(menu_options)
    menu_utils.bindMenuCallbacks(menu.item_table, menu)
    return menu
end

function DownloadsUI.updateDownloadsMenu(menu, snapshot, callbacks, options)
    if not menu then
        return
    end
    local menu_options = buildMenuOptions(snapshot, callbacks, options)
    menu_utils.bindMenuCallbacks(menu_options.item_table, menu)
    return getListMenu().update(menu, menu_options)
end

return DownloadsUI
