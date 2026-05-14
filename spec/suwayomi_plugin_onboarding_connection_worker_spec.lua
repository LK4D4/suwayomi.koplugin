package.path = "?.lua;" .. package.path

describe("suwayomi/plugin/onboarding_connection_worker", function()
    local function clearModules()
        for _, name in ipairs({
            "suwayomi/plugin/onboarding_connection_worker",
            "suwayomi/api",
            "suwayomi/subprocess/job",
        }) do
            package.loaded[name] = nil
            package.preload[name] = nil
        end
    end

    after_each(clearModules)

    it("tests connection by fetching sources with supplied credentials", function()
        clearModules()
        package.preload["suwayomi/api"] = function()
            return {
                fetchSources = function(credentials)
                    assert.are.equal("https://suwayomi.example", credentials.server_url)
                    return {
                        ok = true,
                        sources = {
                            { id = "mangadex" },
                            { id = "local" },
                        },
                    }
                end,
            }
        end
        package.preload["suwayomi/subprocess/job"] = function()
            return {
                writeResult = function(_, result)
                    return result
                end,
                readResult = function(_, normalize)
                    return normalize({
                        ok = true,
                        source_count = 2,
                    })
                end,
            }
        end

        local worker = require("suwayomi/plugin/onboarding_connection_worker")
        local result = worker:run({ server_url = "https://suwayomi.example" }, "/tmp/result.json")

        assert.is_true(result.ok)
        assert.are.equal(2, result.source_count)
        assert.are.equal("Connection test passed. Found 2 sources.", result.message)
    end)

    it("returns readable failure for missing server url", function()
        clearModules()
        package.preload["suwayomi/api"] = function()
            return {
                fetchSources = function()
                    error("unexpected network call")
                end,
            }
        end
        package.preload["suwayomi/subprocess/job"] = function()
            return {
                writeResult = function(_, result)
                    return result
                end,
            }
        end

        local worker = require("suwayomi/plugin/onboarding_connection_worker")
        local result = worker:run({ server_url = "" }, "/tmp/result.json")

        assert.is_false(result.ok)
        assert.are.equal("Enter a Suwayomi server URL first.", result.error)
    end)
end)
