package.path = "?.lua;" .. package.path

describe("suwayomi/browse/extension_worker", function()
    local original_io_open
    local original_os_rename
    local original_os_remove
    local files

    local function install_file_mock()
        original_io_open = io.open
        original_os_rename = os.rename
        original_os_remove = os.remove
        files = {}

        io.open = function(path, mode)
            if tostring(path):match("extension") then
                if mode == "w" then
                    local chunks = {}
                    return {
                        write = function(_, ...)
                            for _, chunk in ipairs({...}) do
                                table.insert(chunks, chunk)
                            end
                        end,
                        close = function()
                            files[path] = table.concat(chunks)
                        end,
                    }
                end

                local content = files[path]
                if not content then
                    return nil
                end
                return {
                    read = function(_, what)
                        if what == "*a" then
                            return content
                        end
                    end,
                    close = function() end,
                }
            end
            return original_io_open(path, mode)
        end

        os.rename = function(from, to)
            if tostring(from):match("extension") or tostring(to):match("extension") then
                files[to] = files[from]
                files[from] = nil
                return true
            end
            return original_os_rename(from, to)
        end

        os.remove = function(path)
            if tostring(path):match("extension") then
                files[path] = nil
                return true
            end
            return original_os_remove(path)
        end
    end

    before_each(function()
        install_file_mock()
        package.loaded["suwayomi/browse/extension_worker"] = nil
        package.loaded["suwayomi/api"] = nil
        package.loaded.socket = nil
    end)

    after_each(function()
        io.open = original_io_open
        os.rename = original_os_rename
        os.remove = original_os_remove
        package.loaded["suwayomi/browse/extension_worker"] = nil
        package.loaded["suwayomi/api"] = nil
        package.loaded.socket = nil
        package.preload["suwayomi/api"] = nil
        package.preload.socket = nil
    end)

    it("fetches extensions and writes a normalized result", function()
        package.preload["suwayomi/api"] = function()
            return {
                fetchExtensions = function(credentials)
                    return {
                        ok = true,
                        extensions = {
                            { pkg_name = "pkg.mangadex", name = "MangaDex" },
                        },
                        server_url = credentials.server_url,
                    }
                end,
            }
        end

        local worker = require("suwayomi/browse/extension_worker")
        local result = worker:run({ server_url = "https://suwayomi.example" }, {
            action = "fetch",
        }, "/settings/extensions.json")

        assert.is_true(result.ok)
        assert.are.equal("pkg.mangadex", result.extensions[1].pkg_name)
        assert.are.same(result, worker:readResult("/settings/extensions.json"))
    end)

    it("writes normalized error results when fetch throws", function()
        package.preload["suwayomi/api"] = function()
            return {
                fetchExtensions = function()
                    error("extension fetch exploded")
                end,
            }
        end

        local worker = require("suwayomi/browse/extension_worker")
        local result = worker:run({ server_url = "https://suwayomi.example" }, {
            action = "fetch",
        }, "/settings/extensions_fetch_error.json")

        assert.is_false(result.ok)
        assert.are.equal("fetch", result.action)
        assert.truthy(result.error:match("extension fetch exploded"))
        assert.are.same({}, result.extensions)
        assert.are.same({}, result.sources)
        assert.are.same(result, worker:readResult("/settings/extensions_fetch_error.json"))
    end)

    it("writes normalized error results when update throws", function()
        package.preload["suwayomi/api"] = function()
            return {
                updateExtension = function()
                    error("install exploded")
                end,
                fetchSources = function()
                    return { ok = true, sources = {} }
                end,
            }
        end

        local worker = require("suwayomi/browse/extension_worker")
        local result = worker:run({ server_url = "https://suwayomi.example" }, {
            action = "install",
            pkg_name = "pkg.mangadex",
        }, "/settings/extensions_install_error.json")

        assert.is_false(result.ok)
        assert.are.equal("install", result.action)
        assert.truthy(result.error:match("install exploded"))
        assert.are.same({}, result.extensions)
        assert.are.same({}, result.sources)
        assert.are.same(result, worker:readResult("/settings/extensions_install_error.json"))
    end)

    it("installs an extension, refreshes extensions, and returns refreshed sources for cache update", function()
        local calls = {}
        local fetch_source_count = 0
        package.preload["suwayomi/api"] = function()
            return {
                updateExtension = function(_, pkg_name, action)
                    table.insert(calls, action .. ":" .. pkg_name)
                    return {
                        ok = true,
                        extension = { pkg_name = pkg_name, name = "MangaDex", is_installed = true },
                    }
                end,
                fetchExtensions = function()
                    table.insert(calls, "fetchExtensions")
                    return {
                        ok = true,
                        extensions = {
                            { pkg_name = "pkg.mangadex", name = "MangaDex", is_installed = true },
                        },
                    }
                end,
                fetchSources = function()
                    fetch_source_count = fetch_source_count + 1
                    table.insert(calls, "fetchSources")
                    if fetch_source_count == 1 then
                        return {
                            ok = true,
                            sources = {},
                        }
                    end
                    return {
                        ok = true,
                        sources = {
                            { id = "source-mangadex", name = "MangaDex", lang = "en" },
                        },
                    }
                end,
            }
        end

        local worker = require("suwayomi/browse/extension_worker")
        local result = worker:run({ server_url = "https://suwayomi.example" }, {
            action = "install",
            pkg_name = "pkg.mangadex",
        }, "/settings/extensions_install.json")

        assert.is_true(result.ok)
        assert.are.same({ "fetchSources", "install:pkg.mangadex", "fetchExtensions", "fetchSources" }, calls)
        assert.is_true(result.updated_extension.is_installed)
        assert.are.equal("source-mangadex", result.sources[1].id)
    end)

    it("keeps install successful when extension list refresh fails but sources refresh", function()
        local calls = {}
        local fetch_source_count = 0
        package.preload["suwayomi/api"] = function()
            return {
                updateExtension = function(_, pkg_name, action)
                    table.insert(calls, action .. ":" .. pkg_name)
                    return {
                        ok = true,
                        extension = { pkg_name = pkg_name, name = "MangaDex", is_installed = true },
                    }
                end,
                fetchExtensions = function()
                    table.insert(calls, "fetchExtensions")
                    return {
                        ok = false,
                        error = "Extension catalog timed out.",
                    }
                end,
                fetchSources = function()
                    fetch_source_count = fetch_source_count + 1
                    table.insert(calls, "fetchSources")
                    if fetch_source_count == 1 then
                        return {
                            ok = true,
                            sources = {},
                        }
                    end
                    return {
                        ok = true,
                        sources = {
                            { id = "source-mangadex", name = "MangaDex", lang = "en" },
                        },
                    }
                end,
            }
        end

        local worker = require("suwayomi/browse/extension_worker")
        local result = worker:run({ server_url = "https://suwayomi.example" }, {
            action = "install",
            pkg_name = "pkg.mangadex",
        }, "/settings/extensions_partial_success.json")

        assert.is_true(result.ok)
        assert.is_false(result.extension_refresh_ok)
        assert.are.equal("Extension catalog timed out.", result.extension_refresh_error)
        assert.are.equal("source-mangadex", result.sources[1].id)
        assert.are.equal("pkg.mangadex", result.extensions[1].pkg_name)
        assert.are.same({ "fetchSources", "install:pkg.mangadex", "fetchExtensions", "fetchSources" }, calls)
    end)

    it("retries source refresh after install until the catalog changes", function()
        local calls = {}
        local fetch_source_count = 0
        package.preload.socket = function()
            return {
                sleep = function(seconds)
                    table.insert(calls, "sleep:" .. tostring(seconds))
                end,
            }
        end
        package.preload["suwayomi/api"] = function()
            return {
                updateExtension = function(_, pkg_name, action)
                    table.insert(calls, action .. ":" .. pkg_name)
                    return {
                        ok = true,
                        extension = { pkg_name = pkg_name, name = "MangaDex", is_installed = true },
                    }
                end,
                fetchExtensions = function()
                    table.insert(calls, "fetchExtensions")
                    return {
                        ok = true,
                        extensions = {
                            { pkg_name = "pkg.mangadex", name = "MangaDex", is_installed = true },
                        },
                    }
                end,
                fetchSources = function()
                    fetch_source_count = fetch_source_count + 1
                    table.insert(calls, "fetchSources:" .. tostring(fetch_source_count))
                    if fetch_source_count < 3 then
                        return {
                            ok = true,
                            sources = {
                                { id = "source-existing", name = "Existing", lang = "en" },
                            },
                        }
                    end
                    return {
                        ok = true,
                        sources = {
                            { id = "source-existing", name = "Existing", lang = "en" },
                            { id = "source-new", name = "New Source", lang = "en" },
                        },
                    }
                end,
            }
        end

        local worker = require("suwayomi/browse/extension_worker")
        local result = worker:run({ server_url = "https://suwayomi.example" }, {
            action = "install",
            pkg_name = "pkg.mangadex",
        }, "/settings/extensions_install_retry.json")

        assert.is_true(result.ok)
        assert.are.same({
            "fetchSources:1",
            "install:pkg.mangadex",
            "fetchExtensions",
            "fetchSources:2",
            "sleep:0.5",
            "fetchSources:3",
        }, calls)
        assert.are.equal("source-new", result.sources[2].id)
    end)

    it("uninstalls an extension and refreshes extension/source state", function()
        local calls = {}
        local fetch_source_count = 0
        package.preload["suwayomi/api"] = function()
            return {
                updateExtension = function(_, pkg_name, action)
                    table.insert(calls, action .. ":" .. pkg_name)
                    return {
                        ok = true,
                        extension = { pkg_name = pkg_name, name = "MangaDex", is_installed = false },
                    }
                end,
                fetchExtensions = function()
                    table.insert(calls, "fetchExtensions")
                    return {
                        ok = true,
                        extensions = {
                            { pkg_name = "pkg.mangadex", name = "MangaDex", is_installed = false },
                        },
                    }
                end,
                fetchSources = function()
                    fetch_source_count = fetch_source_count + 1
                    table.insert(calls, "fetchSources")
                    if fetch_source_count == 1 then
                        return {
                            ok = true,
                            sources = {
                                { id = "source-mangadex", name = "MangaDex", lang = "en" },
                            },
                        }
                    end
                    return {
                        ok = true,
                        sources = {},
                    }
                end,
            }
        end

        local worker = require("suwayomi/browse/extension_worker")
        local result = worker:run({ server_url = "https://suwayomi.example" }, {
            action = "uninstall",
            pkg_name = "pkg.mangadex",
        }, "/settings/extensions_uninstall.json")

        assert.is_true(result.ok)
        assert.are.same({ "fetchSources", "uninstall:pkg.mangadex", "fetchExtensions", "fetchSources" }, calls)
        assert.is_false(result.updated_extension.is_installed)
        assert.are.equal(0, #result.sources)
    end)
end)
