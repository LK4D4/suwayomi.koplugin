-- Boundary: Downloads hub and download-ahead setup UI.
--
-- Responsibility: format download and refill rows, display their details, and
-- offer optional automatic finish marking after explicit download-ahead setup.
-- Owned state: returned widgets own their dialog and checkbox state.
-- Dependencies: KOReader widgets/UIManager, plugin i18n, shared list menus,
-- status formatting, and menu utilities.
-- External data: queue snapshots are display-only here; controller actions own
-- retries, cancellation, deletion, and navigation.

local I18n = require("suwayomi/i18n")
local StatusFormatter = require("suwayomi/downloads/status_formatter")
local menu_utils = require("suwayomi/ui/menu_utils")

local DownloadsUI = {}

function DownloadsUI.showAutoMarkPrompt(options)
    local ConfirmBox = require("ui/widget/confirmbox")
    local CheckButton = require("ui/widget/checkbutton")
    local UIManager = require("ui/uimanager")
    local checkbox
    local dialog = ConfirmBox:new{
        text = I18n.t("Automatically mark all KOReader documents finished at their end-of-document action?")
            .. "\n\n" .. I18n.t("Helps Auto-download refill after chapters close. Manual marking still works.")
            .. "\n\n" .. I18n.t("Your end action stays unchanged. Finished chapters follow your automatic removal settings."),
        ok_text = I18n.t("Enable"),
        cancel_text = I18n.t("Keep disabled"),
        ok_callback = options.onEnable,
        cancel_callback = function() options.onKeepDisabled(checkbox.checked) end,
        -- Native ConfirmBox treats dismissal as Cancel; only the button may retire this prompt.
        onClose = function(self)
            UIManager:close(self)
            return true
        end,
    }
    checkbox = CheckButton:new{
        text = I18n.t("Don't ask again"),
        checked = false,
        parent = dialog,
    }
    dialog:addWidget(checkbox)
    UIManager:show(dialog)
    return dialog
end

local function getErrorText(job)
    local error_message = job and job.progress and job.progress.error
    if error_message ~= nil and tostring(error_message):find("%S") then
        return tostring(error_message)
    end
    return I18n.t("No error details were recorded.")
end

function DownloadsUI.showDownloadErrorDetails(job, options)
    options = options or {}
    local TextViewer = require("ui/widget/textviewer")
    local UIManager = require("ui/uimanager")
    local text = options.context or ""
    if job and job.state == "queued" and job.retry_at then
        text = text .. "\n\n" .. I18n.t("Retry scheduled") .. "\n" .. StatusFormatter.formatRetryTime(job.retry_at)
    end
    local archive_status = StatusFormatter.formatArchiveStatus(job and job.progress)
    if archive_status then text = text .. "\n\n" .. archive_status end
    if text ~= "" then
        text = text .. "\n\n"
    end
    local viewer
    local buttons = {}
    local function addAction(id, label, callback, include_disabled)
        if not callback and not include_disabled then return end
        buttons[#buttons + 1] = {
            id = id,
            text = label,
            enabled = callback ~= nil,
            callback = function()
                if callback then
                    viewer:onClose()
                    callback()
                end
            end,
        }
    end
    addAction("retry", I18n.t("Retry"), options.onRetry, not archive_status)
    addAction("verify_download", I18n.t("Verify download"), options.onVerify)
    addAction("redownload", I18n.t("Redownload"), options.onRedownload)
    buttons[#buttons + 1] = {
        id = "close",
        text = I18n.t("Close"),
        callback = function() viewer:onClose() end,
    }
    viewer = TextViewer:new{
        title = I18n.t("Error details"),
        text = text .. getErrorText(job),
        buttons_table = { buttons },
    }
    UIManager:show(viewer)
    return viewer
end

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
    local summary = getErrorText(job):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return StatusFormatter.shortenChapterTitle(summary, 0, 100)
end

local function formatRefillReason(reason)
    if reason == "endpoint_changed" then
        return I18n.t("Server changed. Open this manga on the current server and choose Auto-download again.")
    elseif reason == "origin_unknown" then
        return I18n.t("Server association unknown. Open this manga on the current server and choose Auto-download again.")
    elseif reason == "configuration_missing" then
        return I18n.t("Check the connection and download folder in Settings.")
    elseif reason == "metadata_missing" then
        return I18n.t("Manga or source details are unavailable. Refresh the chapter list.")
    elseif reason == "unsupported_state" then
        return I18n.t("Saved auto-download data is unsupported. Existing data is preserved.")
    elseif reason == "scanlator_missing" then
        return I18n.t("No chapters match the saved scanlator filter. Other scanlators are not selected.")
    elseif reason == "terminal_failure" then
        return I18n.t("An unread chapter could not be downloaded. Use its Retry or Redownload action.")
    elseif reason == "manual_delete_pending" then
        return I18n.t("An unread chapter is waiting for manual deletion. Auto-download will not replace it.")
    elseif reason == "ownership_unproved" then
        return I18n.t("Archive or download ownership is not verified. Existing files and work are preserved.")
    elseif reason == "fetch_failed" then
        return I18n.t("Could not load chapters. Auto-download will try again automatically.")
    elseif reason == "fetch_rejected" then
        return I18n.t("The server rejected the chapter request. Check connection settings, then choose Check again.")
    elseif reason == "persistence_failed" then
        return I18n.t("Could not confirm that the auto-download request was saved. No new downloads are confirmed.")
    elseif reason == "choices_changed" then
        return I18n.t("Reading or download choices changed. Auto-download will use the current choices.")
    end
    return I18n.t("Waiting to check which unread chapters need downloading.")
end

local function formatRefillState(state)
    if state == "blocked" then
        return I18n.t("Auto-download blocked")
    elseif state == "waiting" then
        return I18n.t("Auto-download waiting")
    end
    return I18n.t("Auto-download pending")
end

function DownloadsUI.formatRefillStatus(request)
    local text = formatRefillState(request.state) .. "\n" .. formatRefillReason(request.reason)
    if request.next_retry_at then
        text = text .. "\n\n" .. I18n.t("Retry scheduled") .. "\n"
            .. StatusFormatter.formatRetryTime(request.next_retry_at)
    end
    return text
end

local function showRefillDetails(request, callbacks)
    local TextViewer = require("ui/widget/textviewer")
    local UIManager = require("ui/uimanager")
    local text = DownloadsUI.formatRefillStatus(request)
    text = text .. "\n\n" .. I18n.t("Check again checks which unread chapters need downloading. It does not retry failed chapters or cancel pending manual deletion.")
        .. "\n\n" .. I18n.t("Turn off auto-download stops future automatic additions for this manga. Queued and running downloads continue.")
    local viewer
    viewer = TextViewer:new{
        title = I18n.f("Auto-download: %1", request.manga_title or tostring(request.manga_id or "")),
        text = text,
        buttons_table = {
            {
                {
                    id = "retry_refill",
                    text = I18n.t("Check again"),
                    enabled = callbacks.retry_refill ~= nil,
                    callback = function()
                        if callbacks.refill_is_current and not callbacks.refill_is_current(request) then return end
                        if callbacks.retry_refill then
                            viewer:onClose()
                            callbacks.retry_refill(request)
                        end
                    end,
                },
                {
                    id = "stop_refill",
                    text = I18n.t("Turn off auto-download"),
                    enabled = callbacks.stop_refill ~= nil,
                    callback = function()
                        if callbacks.refill_is_current and not callbacks.refill_is_current(request) then return end
                        if callbacks.stop_refill then
                            viewer:onClose()
                            callbacks.stop_refill(request)
                        end
                    end,
                },
            },
            {
                {
                    id = "close",
                    text = I18n.t("Close"),
                    callback = function() viewer:onClose() end,
                },
            },
        },
    }
    UIManager:show(viewer)
end

local function isDownloadsSnapshotEmpty(snapshot)
    return #(snapshot.active or {}) == 0
        and #(snapshot.queued or {}) == 0
        and #(snapshot.failed or {}) == 0
        and #(snapshot.refills or {}) == 0
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
            -- Job actions open overlays; native selection must not run the
            -- hub's close callback and detach its live status updates.
            keep_menu_open = true,
            subtitle = StatusFormatter.formatArchiveStatus(job.progress),
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
            keep_menu_open = true,
            mandatory = job.retry_at and I18n.t("Retry scheduled") or queued_label,
            subtitle = StatusFormatter.formatArchiveStatus(job.progress)
                or (job.retry_at and StatusFormatter.formatRetryTime(job.retry_at) or nil),
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
            keep_menu_open = true,
            subtitle = formatFailedDownloadText(job),
            mandatory = StatusFormatter.formatArchiveStatus(job.progress) or failed_label,
            callback = function(menu)
                if callbacks.onSelectFailed then
                    callbacks.onSelectFailed(job, menu)
                elseif callbacks.onRetryFailed then
                    callbacks.onRetryFailed(job, menu)
                end
            end,
        })
    end

    for _, request in ipairs(snapshot.refills or {}) do
        local subtitle = formatRefillReason(request.reason)
        if request.next_retry_at then
            subtitle = subtitle .. "\n" .. StatusFormatter.formatRetryTime(request.next_retry_at)
        end
        table.insert(menu_table, {
            text = request.manga_title or tostring(request.manga_id or ""),
            keep_menu_open = true,
            mandatory = formatRefillState(request.state),
            subtitle = subtitle,
            callback = function()
                if callbacks.refill_is_current and not callbacks.refill_is_current(request) then return end
                showRefillDetails(request, callbacks)
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
