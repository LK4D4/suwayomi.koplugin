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

    it("returns message id for successful connection test", function()
        clearModules()
        package.preload["suwayomi/api"] = function()
            return {
                testConnection = function(credentials, options)
                    assert.are.equal("https://suwayomi.example", credentials.server_url)
                    assert.are.equal(5, options.timeout_seconds)
                    return {
                        ok = true,
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
                        message_id = "connection_test_passed",
                    })
                end,
            }
        end

        local worker = require("suwayomi/plugin/onboarding_connection_worker")
        local result = worker:run({ server_url = "https://suwayomi.example" }, "/tmp/result.json")

        assert.is_true(result.ok)
        assert.are.equal("connection_test_passed", result.message_id)
        assert.is_nil(result.message)
    end)

    it("retries transient connection test timeouts", function()
        clearModules()
        local attempts = 0
        package.preload["suwayomi/api"] = function()
            return {
                testConnection = function()
                    attempts = attempts + 1
                    if attempts < 3 then
                        return {
                            ok = false,
                            error = "Connection timed out while waiting for Suwayomi.",
                        }
                    end
                    return { ok = true }
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
        local result = worker:run({ server_url = "https://suwayomi.example" }, "/tmp/result.json")

        assert.is_true(result.ok)
        assert.are.equal(3, attempts)
        assert.are.equal("connection_test_passed_after_retry", result.message_id)
        assert.is_nil(result.message)
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
        assert.are.equal("missing_server_url", result.error_id)
        assert.is_nil(result.error)
    end)

    it("keeps raw API errors as external data", function()
        clearModules()
        package.preload["suwayomi/api"] = function()
            return {
                testConnection = function()
                    return {
                        ok = false,
                        error = "HTTP 401 Unauthorized from Suwayomi",
                    }
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
        local result = worker:run({ server_url = "https://suwayomi.example" }, "/tmp/result.json")

        assert.is_false(result.ok)
        assert.are.equal("HTTP 401 Unauthorized from Suwayomi", result.error)
        assert.is_nil(result.error_id)
    end)

    it("drops legacy and unexpected keys when reading persisted results", function()
        clearModules()
        package.preload["suwayomi/api"] = function()
            return {}
        end
        package.preload["suwayomi/subprocess/job"] = function()
            return {
                readResult = function(_, normalize)
                    return normalize({
                        ok = false,
                        source_count = 7,
                        error_id = "missing_server_url",
                        message_id = "connection_test_passed",
                        message = "legacy message",
                        extra = "unexpected",
                    })
                end,
            }
        end

        local worker = require("suwayomi/plugin/onboarding_connection_worker")
        local result = worker:readResult("/tmp/result.json")

        assert.are.same({
            ok = false,
            source_count = 7,
            error = nil,
            error_id = "missing_server_url",
            message_id = "connection_test_passed",
        }, result)
        assert.is_nil(result.message)
        assert.is_nil(result.extra)
    end)

    it("maps missing external connection errors to could_not_connect", function()
        clearModules()
        package.preload["suwayomi/api"] = function()
            return {
                testConnection = function()
                    return {
                        ok = false,
                        error = false,
                    }
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
        local result = worker:run({ server_url = "https://suwayomi.example" }, "/tmp/result.json")

        assert.is_false(result.ok)
        assert.are.equal("could_not_connect", result.error_id)
        assert.is_nil(result.error)
    end)

    it("maps blank external connection errors to could_not_connect", function()
        clearModules()
        package.preload["suwayomi/api"] = function()
            return {
                testConnection = function()
                    return {
                        ok = false,
                        error = "",
                    }
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
        local result = worker:run({ server_url = "https://suwayomi.example" }, "/tmp/result.json")

        assert.is_false(result.ok)
        assert.are.equal("could_not_connect", result.error_id)
        assert.is_nil(result.error)
    end)
end)
