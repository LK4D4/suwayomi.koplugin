-- Boundary: process-owned adapter for the existing finished-chapter cleanup policy.
-- Keeps cleanup timers alive without views and resolves the current reader at use time.

local Adapter = {}
local methods = {}
for _, name in ipairs({
    "suwayomi/chapters/finished_cleanup", "suwayomi/chapters/local_downloads",
    "suwayomi/chapters/delete_actions", "suwayomi/readsync/ledger",
    "suwayomi/readsync/koreader_metadata", "suwayomi/reader_return",
}) do
    for key, method in pairs(require(name).methods) do methods[key] = method end
end

function Adapter.new(service)
    local adapter = setmetatable({ finished_cleanup_batch_size = 25 }, { __index = methods })
    function adapter:getDownloadQueue() return service:getQueue() end
    function adapter:getChapterDownloadKey(manga, chapter) return self:getDownloadQueue():getKey(manga, chapter) end
    function adapter:showMessage(message) service:notify(message) end
    function adapter:refreshDownloadsMenu(changed_mangas) service:notify(nil, nil, changed_mangas) end
    function adapter:refreshChapterMenu() service:notify(nil, true) end
    function adapter:processFinishedChapterCleanup()
        if not self:getDownloadQueue():checkStoreFence() then return { blocked = true } end
        return methods.processFinishedChapterCleanup(self)
    end
    return adapter
end

return Adapter
