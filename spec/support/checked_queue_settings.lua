local SettingsStore = require("suwayomi/settings/store")

return function(jobs)
    local files, saves = {}, 0
    local store = SettingsStore:new{
        path = "/queue-spec/settings.lua",
        io = {
            read = function(path) return files[path] end,
            dir_exists = function() return true end,
            open = function(path) return { path = path, chunks = {} } end,
            write = function(handle, content)
                handle.chunks[#handle.chunks + 1] = content
                return true
            end,
            flush = function() return true end,
            sync_file = function() return true end,
            close = function(handle)
                files[handle.path] = table.concat(handle.chunks)
                return true
            end,
            rename = function(from, to)
                files[to], files[from] = files[from], nil
                saves = saves + 1
                return true
            end,
            remove = function(path) files[path] = nil; return true end,
            sync_dir = function() return true end,
        },
    }
    store:load({ download_queue = jobs or {}, store_transaction = { id = "initial", version = 1 } })
    files[store.path] = assert(store:serializeDocument(store:load()))
    local settings = {
        getStore = function() return store end,
        isBlocked = function() return store:isBlocked() end,
        reconcile = function() return store:reconcile() end,
        load = function() return { server_url = "https://suwayomi.example" } end,
        loadDownloadQueue = function() return store:readKey("download_queue", {}) end,
        saveDownloadQueue = function(_, value)
            local ok, err = store:saveKey("download_queue", value)
            if not ok then return false, err end
            return store:readKey("download_queue", {})
        end,
    }
    return settings, function() return saves end
end
