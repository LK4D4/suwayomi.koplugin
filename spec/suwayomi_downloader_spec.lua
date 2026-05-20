package.path = "?.lua;" .. package.path

describe("suwayomi/downloads/downloader", function()
    local empty_zip = "PK\005\006\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000"

    local function u16le(value)
        return string.char(value % 256, math.floor(value / 256) % 256)
    end

    local function u32le(value)
        return string.char(
            value % 256,
            math.floor(value / 256) % 256,
            math.floor(value / 65536) % 256,
            math.floor(value / 16777216) % 256
        )
    end

    local function buildStoredZip(name, content)
        local local_header = "PK\003\004"
            .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(#content) .. u32le(#content)
            .. u16le(#name) .. u16le(0)
            .. name .. content
        local central_dir_offset = #local_header
        local central_dir = "PK\001\002"
            .. u16le(20) .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(#content) .. u32le(#content)
            .. u16le(#name) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(0)
            .. name
        local eocd = "PK\005\006"
            .. u16le(0) .. u16le(0) .. u16le(1) .. u16le(1)
            .. u32le(#central_dir) .. u32le(central_dir_offset) .. u16le(0)
        return local_header .. central_dir .. eocd
    end

    local function buildForgedCentralDirZip()
        local local_header = "PK\003\004" .. string.rep("\000", 26)
        local central_dir = "PK\001\002" .. string.rep("\000", 42)
        return local_header
            .. central_dir
            .. "PK\005\006"
            .. u16le(0) .. u16le(0) .. u16le(1) .. u16le(1)
            .. u32le(#central_dir) .. u32le(#local_header) .. u16le(0)
    end

    local function buildForgedMissingPayloadZip()
        local name = "0001.jpg"
        local local_header = "PK\003\004"
            .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(8) .. u32le(8)
            .. u16le(#name) .. u16le(0)
            .. name
        local central_dir_offset = #local_header
        local central_dir = "PK\001\002"
            .. u16le(20) .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(8) .. u32le(8)
            .. u16le(#name) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(0)
            .. name
        local eocd = "PK\005\006"
            .. u16le(0) .. u16le(0) .. u16le(1) .. u16le(1)
            .. u32le(#central_dir) .. u32le(central_dir_offset) .. u16le(0)
        return local_header .. central_dir .. eocd
    end

    local function buildForgedLocalSizeMismatchZip()
        local name = "0001.jpg"
        local local_header = "PK\003\004"
            .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(1) .. u32le(1)
            .. u16le(#name) .. u16le(0)
            .. name .. "x"
        local central_dir_offset = #local_header
        local central_dir = "PK\001\002"
            .. u16le(20) .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(8) .. u32le(8)
            .. u16le(#name) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(0)
            .. name
        local eocd = "PK\005\006"
            .. u16le(0) .. u16le(0) .. u16le(1) .. u16le(1)
            .. u32le(#central_dir) .. u32le(central_dir_offset) .. u16le(0)
        return local_header .. central_dir .. eocd
    end

    local function buildForgedMultiEntryMissingPayloadZip()
        local first_name = "0001.jpg"
        local second_name = "0002.jpg"
        local first_payload = "x"
        local first_header = "PK\003\004"
            .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(#first_payload) .. u32le(#first_payload)
            .. u16le(#first_name) .. u16le(0)
            .. first_name .. first_payload
        local second_offset = #first_header
        local second_header = "PK\003\004"
            .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(8) .. u32le(8)
            .. u16le(#second_name) .. u16le(0)
            .. second_name
        local central_dir_offset = #first_header + #second_header
        local first_central = "PK\001\002"
            .. u16le(20) .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(#first_payload) .. u32le(#first_payload)
            .. u16le(#first_name) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(0)
            .. first_name
        local second_central = "PK\001\002"
            .. u16le(20) .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(8) .. u32le(8)
            .. u16le(#second_name) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(second_offset)
            .. second_name
        local central_dir = first_central .. second_central
        local eocd = "PK\005\006"
            .. u16le(0) .. u16le(0) .. u16le(2) .. u16le(2)
            .. u32le(#central_dir) .. u32le(central_dir_offset) .. u16le(0)
        return first_header .. second_header .. central_dir .. eocd
    end

    local function buildForgedMultiEntryExtraFieldPayloadZip()
        local first_name = "0001.jpg"
        local second_name = "0002.jpg"
        local first_payload = "x"
        local first_header = "PK\003\004"
            .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(#first_payload) .. u32le(#first_payload)
            .. u16le(#first_name) .. u16le(0)
            .. first_name .. first_payload
        local second_offset = #first_header
        local second_extra = string.rep("\000", 8)
        local second_header = "PK\003\004"
            .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(8) .. u32le(8)
            .. u16le(#second_name) .. u16le(#second_extra)
            .. second_name .. second_extra
        local central_dir_offset = #first_header + #second_header
        local first_central = "PK\001\002"
            .. u16le(20) .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(#first_payload) .. u32le(#first_payload)
            .. u16le(#first_name) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(0)
            .. first_name
        local second_central = "PK\001\002"
            .. u16le(20) .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(8) .. u32le(8)
            .. u16le(#second_name) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(second_offset)
            .. second_name
        local central_dir = first_central .. second_central
        local eocd = "PK\005\006"
            .. u16le(0) .. u16le(0) .. u16le(2) .. u16le(2)
            .. u32le(#central_dir) .. u32le(central_dir_offset) .. u16le(0)
        return first_header .. second_header .. central_dir .. eocd
    end

    local function buildDataDescriptorGapZip()
        local name = "0001.jpg"
        local payload = "x"
        local local_header = "PK\003\004"
            .. u16le(20) .. u16le(8) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(#payload) .. u32le(#payload)
            .. u16le(#name) .. u16le(0)
            .. name .. payload .. "JUNK"
        local central_dir_offset = #local_header
        local central_dir = "PK\001\002"
            .. u16le(20) .. u16le(20) .. u16le(8) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(#payload) .. u32le(#payload)
            .. u16le(#name) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(0)
            .. name
        local eocd = "PK\005\006"
            .. u16le(0) .. u16le(0) .. u16le(1) .. u16le(1)
            .. u32le(#central_dir) .. u32le(central_dir_offset) .. u16le(0)
        return local_header .. central_dir .. eocd
    end

    local function buildDataDescriptorZip()
        local name = "0001.jpg"
        local payload = "x"
        local data_descriptor = "PK\007\008" .. u32le(0) .. u32le(#payload) .. u32le(#payload)
        local local_header = "PK\003\004"
            .. u16le(20) .. u16le(8) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(0) .. u32le(0)
            .. u16le(#name) .. u16le(0)
            .. name .. payload .. data_descriptor
        local central_dir_offset = #local_header
        local central_dir = "PK\001\002"
            .. u16le(20) .. u16le(20) .. u16le(8) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(#payload) .. u32le(#payload)
            .. u16le(#name) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(0)
            .. name
        local eocd = "PK\005\006"
            .. u16le(0) .. u16le(0) .. u16le(1) .. u16le(1)
            .. u32le(#central_dir) .. u32le(central_dir_offset) .. u16le(0)
        return local_header .. central_dir .. eocd
    end

    local function buildOutOfOrderCentralDirectoryZip()
        local first_name = "0001.jpg"
        local second_name = "0002.jpg"
        local first_payload = "x"
        local second_payload = "y"
        local first_header = "PK\003\004"
            .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(#first_payload) .. u32le(#first_payload)
            .. u16le(#first_name) .. u16le(0)
            .. first_name .. first_payload
        local second_offset = #first_header
        local second_header = "PK\003\004"
            .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(#second_payload) .. u32le(#second_payload)
            .. u16le(#second_name) .. u16le(0)
            .. second_name .. second_payload
        local central_dir_offset = #first_header + #second_header
        local first_central = "PK\001\002"
            .. u16le(20) .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(#first_payload) .. u32le(#first_payload)
            .. u16le(#first_name) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(0)
            .. first_name
        local second_central = "PK\001\002"
            .. u16le(20) .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(#second_payload) .. u32le(#second_payload)
            .. u16le(#second_name) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
            .. u32le(0) .. u32le(second_offset)
            .. second_name
        local central_dir = second_central .. first_central
        local eocd = "PK\005\006"
            .. u16le(0) .. u16le(0) .. u16le(2) .. u16le(2)
            .. u32le(#central_dir) .. u32le(central_dir_offset) .. u16le(0)
        return first_header .. second_header .. central_dir .. eocd
    end

    local function buildMultiEntryStoredZip(count)
        local local_parts = {}
        local central_parts = {}
        local offset = 0
        for index = 1, count do
            local name = string.format("%04d.jpg", index)
            local payload = "x"
            local local_header = "PK\003\004"
                .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
                .. u32le(0) .. u32le(#payload) .. u32le(#payload)
                .. u16le(#name) .. u16le(0)
                .. name .. payload
            table.insert(local_parts, local_header)
            table.insert(central_parts, "PK\001\002"
                .. u16le(20) .. u16le(20) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
                .. u32le(0) .. u32le(#payload) .. u32le(#payload)
                .. u16le(#name) .. u16le(0) .. u16le(0) .. u16le(0) .. u16le(0)
                .. u32le(0) .. u32le(offset)
                .. name)
            offset = offset + #local_header
        end
        local local_bytes = table.concat(local_parts)
        local central_dir = table.concat(central_parts)
        local eocd = "PK\005\006"
            .. u16le(0) .. u16le(0) .. u16le(count) .. u16le(count)
            .. u32le(#central_dir) .. u32le(#local_bytes) .. u16le(0)
        return local_bytes .. central_dir .. eocd
    end

    local function loadDownloaderForZipValidation()
        package.preload["suwayomi/paths"] = function()
            return {
                sanitizePathSegment = function(value)
                    return value
                end,
                getTargetPath = function()
                    return "", ""
                end,
            }
        end
        package.preload["suwayomi/api"] = function()
            return {}
        end
        package.preload.lfs = function()
            return {}
        end
        package.preload["ffi/archiver"] = function()
            return {}
        end
        return require("suwayomi/downloads/downloader")
    end

    after_each(function()
        package.loaded["suwayomi/downloads/downloader"] = nil
        package.loaded["suwayomi/paths"] = nil
        package.loaded["suwayomi/api"] = nil
        package.loaded["suwayomi/fs"] = nil
        package.loaded.lfs = nil
        package.loaded["ffi/archiver"] = nil
        package.loaded["ffi/util"] = nil
        package.loaded.socket = nil

        package.preload["suwayomi/paths"] = nil
        package.preload["suwayomi/api"] = nil
        package.preload["suwayomi/fs"] = nil
        package.preload.lfs = nil
        package.preload["ffi/archiver"] = nil
        package.preload["ffi/util"] = nil
        package.preload.socket = nil
    end)

    it("rejects direct archives when local and central sizes disagree", function()
        local forged_zip = buildForgedLocalSizeMismatchZip()
        local downloader = loadDownloaderForZipValidation()

        assert.is_false(downloader:isZipArchiveResult({
            content_type = "application/zip",
            bytes = #forged_zip,
            header_bytes = forged_zip:sub(1, 4),
            head_bytes = forged_zip,
            tail_bytes = forged_zip,
        }))
    end)

    it("rejects multi-entry direct archives with missing payload bytes", function()
        local forged_zip = buildForgedMultiEntryMissingPayloadZip()
        local downloader = loadDownloaderForZipValidation()

        assert.is_false(downloader:isZipArchiveResult({
            content_type = "application/zip",
            bytes = #forged_zip,
            header_bytes = forged_zip:sub(1, 4),
            head_bytes = forged_zip,
            tail_bytes = forged_zip,
        }))
    end)

    it("rejects multi-entry direct archives that hide payload inside local extra bytes", function()
        local forged_zip = buildForgedMultiEntryExtraFieldPayloadZip()
        local downloader = loadDownloaderForZipValidation()

        assert.is_false(downloader:isZipArchiveResult({
            content_type = "application/zip",
            bytes = #forged_zip,
            header_bytes = forged_zip:sub(1, 4),
            head_bytes = forged_zip,
            tail_bytes = forged_zip,
        }))
    end)

    it("accepts direct archives using data descriptors", function()
        local archive = buildDataDescriptorZip()
        local downloader = loadDownloaderForZipValidation()

        assert.is_true(downloader:isZipArchiveResult({
            content_type = "application/zip",
            bytes = #archive,
            header_bytes = archive:sub(1, 4),
            head_bytes = archive,
            tail_bytes = archive,
        }))
    end)

    it("rejects direct archives using incomplete data descriptors", function()
        local forged_zip = buildDataDescriptorGapZip()
        local downloader = loadDownloaderForZipValidation()

        assert.is_false(downloader:isZipArchiveResult({
            content_type = "application/zip",
            bytes = #forged_zip,
            header_bytes = forged_zip:sub(1, 4),
            head_bytes = forged_zip,
            tail_bytes = forged_zip,
        }))
    end)

    it("accepts direct archives whose central directory is not sorted by local offset", function()
        local archive = buildOutOfOrderCentralDirectoryZip()
        local downloader = loadDownloaderForZipValidation()

        assert.is_true(downloader:isZipArchiveResult({
            content_type = "application/zip",
            bytes = #archive,
            header_bytes = archive:sub(1, 4),
            head_bytes = archive,
            tail_bytes = archive,
        }))
    end)

    it("validates direct archives whose central directory is only available from the partial file", function()
        local archive = buildMultiEntryStoredZip(1400)
        local original_io_open = io.open
        io.open = function(path, mode)
            if path == "/tmp/large.cbz.part" and mode == "rb" then
                return {
                    offset = 1,
                    seek = function(self, whence, offset)
                        assert.are.equal("set", whence)
                        self.offset = offset + 1
                        return offset
                    end,
                    read = function(self, length)
                        local chunk = archive:sub(self.offset, self.offset + length - 1)
                        self.offset = self.offset + #chunk
                        return chunk
                    end,
                    close = function() end,
                }
            end
            return original_io_open(path, mode)
        end

        local downloader = loadDownloaderForZipValidation()
        local ok = downloader:isZipArchiveResult({
            content_type = "application/zip",
            bytes = #archive,
            header_bytes = archive:sub(1, 4),
            head_bytes = archive:sub(1, 4096),
            tail_bytes = archive:sub(-65536),
        }, "/tmp/large.cbz.part")

        io.open = original_io_open

        assert.is_true(ok)
    end)

    it("skips downloading when the target cbz already exists", function()
        package.loaded["suwayomi/downloads/downloader"] = nil
        package.loaded["suwayomi/api"] = nil
        package.loaded["suwayomi/fs"] = nil
        package.loaded.lfs = nil
        package.loaded["ffi/archiver"] = nil
        package.loaded["ffi/util"] = nil
        package.preload["suwayomi/api"] = function()
            return {
                fetchChapterPages = function()
                    error("should not fetch pages for an existing file")
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function(path, attribute)
                    if path == "/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz" and attribute == "mode" then
                        return "file"
                    end
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {}
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({}, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        assert.is_true(result.ok)
        assert.is_true(result.skipped)
        assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz", result.path)
    end)

    it("builds a cbz from fetched page bytes", function()
        local added_files = {}
        local renamed_from
        local renamed_to
        local created_paths = {}

        package.loaded["suwayomi/downloads/downloader"] = nil
        package.loaded["suwayomi/api"] = nil
        package.loaded["suwayomi/fs"] = nil
        package.loaded.lfs = nil
        package.loaded["ffi/archiver"] = nil
        package.loaded["ffi/util"] = nil
        package.preload["suwayomi/api"] = function()
            return {
                fetchChapterPages = function()
                    return {
                        ok = true,
                        chapter = { id = "398", name = "Official_Vol. 1 Ch. 1", manga_title = "Sousou no Frieren" },
                        pages = {
                            "/api/v1/manga/85/chapter/1/page/0",
                            "/api/v1/manga/85/chapter/1/page/1",
                        },
                    }
                end,
                downloadBinary = function(_, page_url)
                    return {
                        ok = true,
                        body = page_url:match("/0$") and "page-one" or "page-two",
                        content_type = "image/jpeg",
                    }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function(path, attribute)
                    if path == "/books" and attribute == "mode" then
                        return "directory"
                    end
                    return nil
                end,
                mkdir = function(path)
                    table.insert(created_paths, path)
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function(_, path, format)
                                assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part", path)
                                assert.are.equal("zip", format)
                                return true
                            end,
                            addFileFromMemory = function(_, entry_path, content)
                                table.insert(added_files, { path = entry_path, content = content })
                                return true
                            end,
                            close = function() end,
                        }
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_rename = os.rename
        os.rename = function(from, to)
            renamed_from = from
            renamed_to = to
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({ server_url = "https://suwayomi.example" }, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.rename = original_rename

        assert.is_true(result.ok)
        assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz", result.path)
        assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part", renamed_from)
        assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz", renamed_to)
        assert.are.same({
            "/books/Unknown source",
            "/books/Unknown source/Sousou no Frieren",
        }, created_paths)
        assert.are.same({
            { path = "0001.jpg", content = "page-one" },
            { path = "0002.jpg", content = "page-two" },
        }, added_files)
    end)

    it("prefers the direct chapter archive endpoint when it returns a CBZ", function()
        local renamed_from
        local renamed_to
        local archive = buildStoredZip("0001.jpg", "page-one")

        package.preload["suwayomi/api"] = function()
            return {
                downloadChapterArchive = function(_, chapter_id, target_path)
                    assert.are.equal("398", chapter_id)
                    assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.direct.part", target_path)
                    return {
                        ok = true,
                        content_type = "application/vnd.comicbook+zip",
                        bytes = #archive,
                        header_bytes = archive:sub(1, 4),
                        head_bytes = archive:sub(1, 4096),
                        tail_bytes = archive,
                    }
                end,
                fetchChapterPages = function()
                    error("page fallback should not run after a direct CBZ download")
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function(path, attribute)
                    if path == "/books" and attribute == "mode" then
                        return "directory"
                    end
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        error("direct CBZ download should not open an archive writer")
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_rename = os.rename
        os.rename = function(from, to)
            renamed_from = from
            renamed_to = to
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({ server_url = "https://suwayomi.example" }, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.rename = original_rename

        assert.is_true(result.ok)
        assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz", result.path)
        assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.direct.part", renamed_from)
        assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz", renamed_to)
    end)

    it("falls back to page downloads when a direct archive has non-zip bytes", function()
        local direct_partial_path = "/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.direct.part"
        local page_partial_path = "/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part"
        local direct_attempted = false
        local direct_partial_removed = false
        local fetched_pages = false
        local added_files = {}
        local renamed_from
        local renamed_to

        package.preload["suwayomi/api"] = function()
            return {
                downloadChapterArchive = function(_, _, target_path)
                    direct_attempted = true
                    assert.are.equal(direct_partial_path, target_path)
                    return {
                        ok = true,
                        content_type = "application/zip",
                        bytes = 21,
                        header_bytes = "HTML",
                    }
                end,
                fetchChapterPages = function()
                    fetched_pages = true
                    return {
                        ok = true,
                        pages = { "/page/0" },
                    }
                end,
                downloadBinary = function()
                    return {
                        ok = true,
                        body = "page-one",
                        content_type = "image/jpeg",
                    }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function(_, path)
                                assert.are.equal(page_partial_path, path)
                                return true
                            end,
                            addFileFromMemory = function(_, entry_path, content)
                                table.insert(added_files, { path = entry_path, content = content })
                                return true
                            end,
                            close = function() end,
                        }
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_remove = os.remove
        os.remove = function(path)
            if path == direct_partial_path then
                direct_partial_removed = true
            end
            return true
        end
        local original_rename = os.rename
        os.rename = function(from, to)
            renamed_from = from
            renamed_to = to
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({ server_url = "https://suwayomi.example" }, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.remove = original_remove
        os.rename = original_rename

        assert.is_true(result.ok)
        assert.is_true(direct_attempted)
        assert.is_true(direct_partial_removed)
        assert.is_true(fetched_pages)
        assert.are.same({ { path = "0001.jpg", content = "page-one" } }, added_files)
        assert.are.equal(page_partial_path, renamed_from)
        assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz", renamed_to)
    end)

    it("falls back to page downloads when a direct archive has a truncated zip header", function()
        local direct_partial_path = "/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.direct.part"
        local page_partial_path = "/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part"
        local fetched_pages = false
        local added_files = {}
        local renamed_from

        package.preload["suwayomi/api"] = function()
            return {
                downloadChapterArchive = function(_, _, target_path)
                    assert.are.equal(direct_partial_path, target_path)
                    return {
                        ok = true,
                        content_type = "application/zip",
                        bytes = 9,
                        header_bytes = "PK\003\004",
                        tail_bytes = "PK\003\004bad",
                    }
                end,
                fetchChapterPages = function()
                    fetched_pages = true
                    return {
                        ok = true,
                        pages = { "/page/0" },
                    }
                end,
                downloadBinary = function()
                    return {
                        ok = true,
                        body = "page-one",
                        content_type = "image/jpeg",
                    }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function(_, path)
                                assert.are.equal(page_partial_path, path)
                                return true
                            end,
                            addFileFromMemory = function(_, entry_path, content)
                                table.insert(added_files, { path = entry_path, content = content })
                                return true
                            end,
                            close = function() end,
                        }
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_rename = os.rename
        os.rename = function(from)
            renamed_from = from
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({ server_url = "https://suwayomi.example" }, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.rename = original_rename

        assert.is_true(result.ok)
        assert.is_true(fetched_pages)
        assert.are.equal(page_partial_path, renamed_from)
        assert.are.same({
            { path = "0001.jpg", content = "page-one" },
        }, added_files)
    end)

    it("falls back to page downloads when a direct archive has only a local header before empty zip footer", function()
        local direct_partial_path = "/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.direct.part"
        local page_partial_path = "/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part"
        local bogus_zip = "PK\003\004" .. empty_zip
        local fetched_pages = false
        local renamed_from

        package.preload["suwayomi/api"] = function()
            return {
                downloadChapterArchive = function(_, _, target_path)
                    assert.are.equal(direct_partial_path, target_path)
                    return {
                        ok = true,
                        content_type = "application/zip",
                        bytes = #bogus_zip,
                        header_bytes = bogus_zip:sub(1, 4),
                        tail_bytes = bogus_zip,
                    }
                end,
                fetchChapterPages = function()
                    fetched_pages = true
                    return {
                        ok = true,
                        pages = { "/page/0" },
                    }
                end,
                downloadBinary = function()
                    return {
                        ok = true,
                        body = "page-one",
                        content_type = "image/jpeg",
                    }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function(_, path)
                                assert.are.equal(page_partial_path, path)
                                return true
                            end,
                            addFileFromMemory = function()
                                return true
                            end,
                            close = function() end,
                        }
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_rename = os.rename
        os.rename = function(from)
            renamed_from = from
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({ server_url = "https://suwayomi.example" }, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.rename = original_rename

        assert.is_true(result.ok)
        assert.is_true(fetched_pages)
        assert.are.equal(page_partial_path, renamed_from)
    end)

    it("falls back to page downloads when a direct archive has forged central directory markers", function()
        local direct_partial_path = "/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.direct.part"
        local page_partial_path = "/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part"
        local forged_zip = buildForgedCentralDirZip()
        local fetched_pages = false
        local renamed_from

        package.preload["suwayomi/api"] = function()
            return {
                downloadChapterArchive = function(_, _, target_path)
                    assert.are.equal(direct_partial_path, target_path)
                    return {
                        ok = true,
                        content_type = "application/zip",
                        bytes = #forged_zip,
                        header_bytes = forged_zip:sub(1, 4),
                        head_bytes = forged_zip,
                        tail_bytes = forged_zip,
                    }
                end,
                fetchChapterPages = function()
                    fetched_pages = true
                    return {
                        ok = true,
                        pages = { "/page/0" },
                    }
                end,
                downloadBinary = function()
                    return {
                        ok = true,
                        body = "page-one",
                        content_type = "image/jpeg",
                    }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function(_, path)
                                assert.are.equal(page_partial_path, path)
                                return true
                            end,
                            addFileFromMemory = function()
                                return true
                            end,
                            close = function() end,
                        }
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_rename = os.rename
        os.rename = function(from)
            renamed_from = from
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({ server_url = "https://suwayomi.example" }, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.rename = original_rename

        assert.is_true(result.ok)
        assert.is_true(fetched_pages)
        assert.are.equal(page_partial_path, renamed_from)
    end)

    it("falls back to page downloads when a direct archive is empty zip", function()
        local page_partial_path = "/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part"
        local fetched_pages = false
        local renamed_from

        package.preload["suwayomi/api"] = function()
            return {
                downloadChapterArchive = function()
                    return {
                        ok = true,
                        content_type = "application/zip",
                        bytes = #empty_zip,
                        header_bytes = empty_zip:sub(1, 4),
                        head_bytes = empty_zip,
                        tail_bytes = empty_zip,
                    }
                end,
                fetchChapterPages = function()
                    fetched_pages = true
                    return { ok = true, pages = { "/page/0" } }
                end,
                downloadBinary = function()
                    return { ok = true, body = "page-one", content_type = "image/jpeg" }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function() return nil end,
                mkdir = function() return true end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function(_, path)
                                assert.are.equal(page_partial_path, path)
                                return true
                            end,
                            addFileFromMemory = function() return true end,
                            close = function() end,
                        }
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_rename = os.rename
        os.rename = function(from)
            renamed_from = from
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({}, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.rename = original_rename

        assert.is_true(result.ok)
        assert.is_true(fetched_pages)
        assert.are.equal(page_partial_path, renamed_from)
    end)

    it("rejects direct archive bytes with junk between the central directory and footer", function()
        local archive = buildStoredZip("0001.jpg", "page-one")
        local forged = archive:sub(1, #archive - 22) .. "JUNK" .. archive:sub(#archive - 21)

        package.preload["suwayomi/api"] = function()
            return {}
        end
        package.preload.lfs = function()
            return {}
        end
        package.preload["ffi/archiver"] = function()
            return {}
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    return tostring(base or "") .. "/" .. tostring(segment or "")
                end,
            }
        end

        local downloader = require("suwayomi/downloads/downloader")

        assert.is_false(downloader:isZipArchiveResult({
            bytes = #forged,
            header_bytes = forged:sub(1, 4),
            head_bytes = forged,
            tail_bytes = forged,
        }))
    end)

    it("rejects direct archive bytes when declared payload is missing before the central directory", function()
        local forged = buildForgedMissingPayloadZip()

        package.preload["suwayomi/api"] = function()
            return {}
        end
        package.preload.lfs = function()
            return {}
        end
        package.preload["ffi/archiver"] = function()
            return {}
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    return tostring(base or "") .. "/" .. tostring(segment or "")
                end,
            }
        end

        local downloader = require("suwayomi/downloads/downloader")

        assert.is_false(downloader:isZipArchiveResult({
            bytes = #forged,
            header_bytes = forged:sub(1, 4),
            head_bytes = forged,
            tail_bytes = forged,
        }))
    end)

    it("falls back to page downloads when the direct archive endpoint is unavailable", function()
        local direct_attempted = false
        local fetched_pages = false
        local added_files = {}
        local renamed_to

        package.preload["suwayomi/api"] = function()
            return {
                downloadChapterArchive = function(_, _, target_path)
                    direct_attempted = true
                    assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.direct.part", target_path)
                    return { ok = false, error = "Chapter archive not found." }
                end,
                fetchChapterPages = function()
                    fetched_pages = true
                    return {
                        ok = true,
                        pages = { "/page/0" },
                    }
                end,
                downloadBinary = function()
                    return {
                        ok = true,
                        body = "page-one",
                        content_type = "image/jpeg",
                    }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function() return true end,
                            addFileFromMemory = function(_, entry_path, content)
                                table.insert(added_files, { path = entry_path, content = content })
                                return true
                            end,
                            close = function() end,
                        }
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_rename = os.rename
        os.rename = function(_from, to)
            renamed_to = to
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({ server_url = "https://suwayomi.example" }, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.rename = original_rename

        assert.is_true(result.ok)
        assert.is_true(direct_attempted)
        assert.is_true(fetched_pages)
        assert.are.same({ { path = "0001.jpg", content = "page-one" } }, added_files)
        assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz", renamed_to)
    end)

    it("retries transient direct archive download failures before page fallback", function()
        local archive = buildStoredZip("0001.jpg", "page-one")
        local direct_attempts = 0
        local fetched_pages = false
        local renamed_to

        package.preload.socket = function()
            return {
                sleep = function() end,
            }
        end
        package.preload["suwayomi/api"] = function()
            return {
                downloadChapterArchive = function()
                    direct_attempts = direct_attempts + 1
                    if direct_attempts < 3 then
                        return { ok = false, error = "Could not reach the Suwayomi server: closed" }
                    end
                    return {
                        ok = true,
                        content_type = "application/zip",
                        bytes = #archive,
                        header_bytes = archive:sub(1, 4),
                        head_bytes = archive,
                        tail_bytes = archive,
                    }
                end,
                fetchChapterPages = function()
                    fetched_pages = true
                    return { ok = false, error = "page fallback should not run" }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {}
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_rename = os.rename
        os.rename = function(_, to)
            renamed_to = to
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({ server_url = "https://suwayomi.example" }, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.rename = original_rename

        assert.is_true(result.ok)
        assert.are.equal(3, direct_attempts)
        assert.is_false(fetched_pages)
        assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz", renamed_to)
    end)

    it("keeps direct archive scratch cleanup failures from blocking page fallback", function()
        local direct_partial_path = "/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.direct.part"
        local page_partial_path = "/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part"
        local opened_path

        package.preload["suwayomi/api"] = function()
            return {
                downloadChapterArchive = function(_, _, target_path)
                    assert.are.equal(direct_partial_path, target_path)
                    return { ok = false, error = "Chapter archive not found." }
                end,
                fetchChapterPages = function()
                    return { ok = true, pages = { "/page/0" } }
                end,
                downloadBinary = function()
                    return { ok = true, body = "page-one", content_type = "image/jpeg" }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function(path, attribute)
                    if path == direct_partial_path and attribute == "mode" then
                        return "file"
                    end
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function(_, path)
                                opened_path = path
                                return true
                            end,
                            addFileFromMemory = function()
                                return true
                            end,
                            close = function() end,
                        }
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_remove = os.remove
        os.remove = function(path)
            if path == direct_partial_path then
                return nil, "permission denied"
            end
            return true
        end
        local original_rename = os.rename
        os.rename = function()
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({ server_url = "https://suwayomi.example" }, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.remove = original_remove
        os.rename = original_rename

        assert.is_true(result.ok)
        assert.are.equal(page_partial_path, opened_path)
    end)

    it("builds target paths with source metadata", function()
        package.preload["suwayomi/api"] = function()
            return {}
        end
        package.preload.lfs = function()
            return {}
        end
        package.preload["ffi/archiver"] = function()
            return {}
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local downloader = require("suwayomi/downloads/downloader")
        local manga_dir, chapter_path = downloader:getTargetPath("/books", {
            title = "Frieren: Beyond Journey's End",
            source = {
                displayName = "MangaDex (EN)",
                name = "MangaDex",
                lang = "en",
            },
        }, {
            name = "Vol. 1 / Ch. 1",
        })

        assert.are.equal("/books/MangaDex (EN)/Frieren_ Beyond Journey's End", manga_dir)
        assert.are.equal("/books/MangaDex (EN)/Frieren_ Beyond Journey's End/Vol. 1 _ Ch. 1.cbz", chapter_path)
    end)

    it("supports stepping through a chapter download with progress", function()
        local added_files = {}
        local original_rename = os.rename
        os.rename = function()
            return true
        end

        package.preload["suwayomi/api"] = function()
            return {
                fetchChapterPages = function()
                    return {
                        ok = true,
                        pages = {
                            "/page/0",
                            "/page/1",
                        },
                    }
                end,
                downloadBinary = function(_, page_url)
                    return {
                        ok = true,
                        body = page_url == "/page/0" and "page-one" or "page-two",
                        content_type = "image/png",
                    }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function() return true end,
                            addFileFromMemory = function(_, entry_path, content)
                                table.insert(added_files, { path = entry_path, content = content })
                                return true
                            end,
                            close = function() end,
                        }
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local downloader = require("suwayomi/downloads/downloader")
        local start_result = downloader:startChapterDownload({}, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        assert.is_true(start_result.ok)
        assert.are.equal(2, start_result.total)

        local first = downloader:downloadNextPage(start_result.job)
        local second = downloader:downloadNextPage(start_result.job)

        assert.is_true(first.ok)
        assert.is_false(first.done)
        assert.are.equal(1, first.current)
        assert.are.equal(2, first.total)
        assert.is_true(second.ok)
        assert.is_true(second.done)
        assert.are.equal(2, second.current)
        assert.are.same({
            { path = "0001.png", content = "page-one" },
            { path = "0002.png", content = "page-two" },
        }, added_files)

        os.rename = original_rename
    end)

    it("retries transient chapter page download failures before failing the chapter", function()
        local added_files = {}
        local attempts_by_page = {}
        local removed_paths = {}
        local renamed_to

        package.preload.socket = function()
            return {
                sleep = function() end,
            }
        end
        package.preload["suwayomi/api"] = function()
            return {
                fetchChapterPages = function()
                    return {
                        ok = true,
                        pages = {
                            "/page/0",
                            "/page/1",
                        },
                    }
                end,
                downloadBinary = function(_, page_url)
                    attempts_by_page[page_url] = (attempts_by_page[page_url] or 0) + 1
                    if page_url == "/page/1" and attempts_by_page[page_url] < 3 then
                        return { ok = false, error = "Could not download chapter page." }
                    end
                    return {
                        ok = true,
                        body = page_url == "/page/0" and "page-one" or "page-two",
                        content_type = "image/jpeg",
                    }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function() return true end,
                            addFileFromMemory = function(_, entry_path, content)
                                table.insert(added_files, { path = entry_path, content = content })
                                return true
                            end,
                            close = function() end,
                        }
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_remove = os.remove
        os.remove = function(path)
            table.insert(removed_paths, path)
            return true
        end
        local original_rename = os.rename
        os.rename = function(_, to)
            renamed_to = to
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({ server_url = "https://suwayomi.example" }, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.remove = original_remove
        os.rename = original_rename

        assert.is_true(result.ok)
        assert.are.equal(1, attempts_by_page["/page/0"])
        assert.are.equal(3, attempts_by_page["/page/1"])
        assert.are.same({
            { path = "0001.jpg", content = "page-one" },
            { path = "0002.jpg", content = "page-two" },
        }, added_files)
        assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz", renamed_to)
        assert.are.same({
            "/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part",
        }, removed_paths)
    end)

    it("retries transient chapter page-list failures before opening a partial archive", function()
        local fetch_attempts = 0
        local opened_writer = false

        package.preload.socket = function()
            return {
                sleep = function() end,
            }
        end
        package.preload["suwayomi/api"] = function()
            return {
                fetchChapterPages = function()
                    fetch_attempts = fetch_attempts + 1
                    if fetch_attempts < 3 then
                        return { ok = false, error = "Connection timed out while waiting for Suwayomi." }
                    end
                    return {
                        ok = true,
                        pages = { "/page/0" },
                    }
                end,
                downloadBinary = function()
                    return {
                        ok = true,
                        body = "page-one",
                        content_type = "image/png",
                    }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function()
                                opened_writer = true
                                return true
                            end,
                            addFileFromMemory = function()
                                return true
                            end,
                            close = function() end,
                        }
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_rename = os.rename
        os.rename = function()
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({}, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.rename = original_rename

        assert.is_true(result.ok)
        assert.are.equal(3, fetch_attempts)
        assert.is_true(opened_writer)
    end)

    it("does not retry non-transient chapter page download failures", function()
        local page_attempts = 0
        local removed_path

        package.preload.socket = function()
            return {
                sleep = function()
                    error("non-transient page failures should not sleep")
                end,
            }
        end
        package.preload["suwayomi/api"] = function()
            return {
                fetchChapterPages = function()
                    return {
                        ok = true,
                        pages = { "/page/0" },
                    }
                end,
                downloadBinary = function()
                    page_attempts = page_attempts + 1
                    return {
                        ok = false,
                        error = "Could not download chapter page.",
                        retryable = false,
                        status_code = 400,
                    }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function() return true end,
                            addFileFromMemory = function()
                                return true
                            end,
                            close = function() end,
                        }
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_remove = os.remove
        os.remove = function(path)
            removed_path = path
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({}, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.remove = original_remove

        assert.is_false(result.ok)
        assert.are.equal("Could not download chapter page.", result.error)
        assert.are.equal(1, page_attempts)
        assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part", removed_path)
    end)

    it("writes progress updates while downloading a chapter", function()
        local progress_path = os.tmpname()
        local original_rename = os.rename
        os.rename = function(from, to)
            if from == progress_path .. ".tmp" then
                local source = assert(io.open(from, "r"))
                local content = source:read("*a")
                source:close()
                local target = assert(io.open(to, "w"))
                target:write(content)
                target:close()
                os.remove(from)
            end
            return true
        end

        package.preload["suwayomi/api"] = function()
            return {
                fetchChapterPages = function()
                    return {
                        ok = true,
                        pages = {
                            "/page/0",
                            "/page/1",
                        },
                    }
                end,
                downloadBinary = function(_, page_url)
                    return {
                        ok = true,
                        body = page_url == "/page/0" and "page-one" or "page-two",
                        content_type = "image/jpeg",
                    }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function() return true end,
                            addFileFromMemory = function() return true end,
                            close = function() end,
                        }
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapterWithProgress({}, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" }, progress_path)

        local progress_file = assert(io.open(progress_path, "r"))
        local progress_content = progress_file:read("*a")
        progress_file:close()
        os.remove(progress_path)
        os.rename = original_rename

        assert.is_true(result.ok)
        assert.are.equal("state=downloaded\ncurrent=2\ntotal=2\npath=/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz\n", progress_content)
    end)

    it("removes a partial cbz when a page download fails", function()
        local removed_path

        package.preload["suwayomi/api"] = function()
            return {
                fetchChapterPages = function()
                    return {
                        ok = true,
                        chapter = { id = "398", name = "Official_Vol. 1 Ch. 1", manga_title = "Sousou no Frieren" },
                        pages = { "/page/0", "/page/1" },
                    }
                end,
                downloadBinary = function(_, page_url)
                    if page_url == "/page/0" then
                        return { ok = true, body = "page-one", content_type = "image/jpeg" }
                    end
                    return { ok = false, error = "Could not download chapter page." }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function() return true end,
                            addFileFromMemory = function() return true end,
                            close = function() end,
                        }
                    end,
                }
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_remove = os.remove
        os.remove = function(path)
            removed_path = path
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({ server_url = "https://suwayomi.example" }, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.remove = original_remove

        assert.is_false(result.ok)
        assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part", removed_path)
    end)

    it("tries to overwrite stale partial files when cleanup fails", function()
        local partial_path = "/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part"
        local removed_path
        local opened_path

        package.preload["suwayomi/api"] = function()
            return {
                fetchChapterPages = function()
                    return { ok = true, pages = { "/page/0" } }
                end,
                downloadBinary = function()
                    return { ok = true, body = "page-one", content_type = "image/jpeg" }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function(path, attribute)
                    if path == partial_path and attribute == "mode" then
                        return "file"
                    end
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function(_, path)
                                opened_path = path
                                return true
                            end,
                            addFileFromMemory = function() return true end,
                            close = function() end,
                        }
                    end,
                }
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_remove = os.remove
        os.remove = function(path)
            removed_path = path
            return nil, "permission denied"
        end
        local original_rename = os.rename
        os.rename = function()
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:startChapterDownload({}, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.remove = original_remove
        os.rename = original_rename

        assert.is_true(result.ok)
        assert.are.equal(partial_path, removed_path)
        assert.are.equal(partial_path, opened_path)
    end)

    it("reports cleanup errors when a failed download leaves the partial archive behind", function()
        local partial_path = "/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part"

        package.preload["suwayomi/api"] = function()
            return {
                fetchChapterPages = function()
                    return { ok = true, pages = { "/page/0" } }
                end,
                downloadBinary = function()
                    return { ok = false, error = "Could not download chapter page." }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function(path, attribute)
                    if path == partial_path and attribute == "mode" then
                        return "file"
                    end
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function() return true end,
                            close = function() end,
                        }
                    end,
                }
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_remove = os.remove
        local remove_calls = 0
        os.remove = function()
            remove_calls = remove_calls + 1
            if remove_calls == 1 then
                return true
            end
            return nil, "permission denied"
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({}, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.remove = original_remove

        assert.is_false(result.ok)
        assert.are.equal("Could not download chapter page.", result.error)
        assert.are.equal("Could not remove partial chapter archive.", result.cleanup_error)
    end)

    it("removes a partial cbz when archive writing fails", function()
        local removed_path

        package.preload["suwayomi/api"] = function()
            return {
                fetchChapterPages = function()
                    return {
                        ok = true,
                        chapter = { id = "398", name = "Official_Vol. 1 Ch. 1", manga_title = "Sousou no Frieren" },
                        pages = { "/page/0" },
                    }
                end,
                downloadBinary = function()
                    return { ok = true, body = "page-one", content_type = "image/jpeg" }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            err = "Could not write chapter archive.",
                            open = function() return true end,
                            addFileFromMemory = function() return false end,
                            close = function() end,
                        }
                    end,
                }
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_remove = os.remove
        os.remove = function(path)
            removed_path = path
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({ server_url = "https://suwayomi.example" }, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.remove = original_remove

        assert.is_false(result.ok)
        assert.are.equal("Could not write chapter archive.", result.error)
        assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part", removed_path)
    end)

    it("reports a failure when finalizing the completed cbz fails", function()
        local removed_path

        package.preload["suwayomi/api"] = function()
            return {
                fetchChapterPages = function()
                    return {
                        ok = true,
                        chapter = { id = "398", name = "Official_Vol. 1 Ch. 1", manga_title = "Sousou no Frieren" },
                        pages = { "/page/0" },
                    }
                end,
                downloadBinary = function()
                    return { ok = true, body = "page-one", content_type = "image/jpeg" }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function() return true end,
                            addFileFromMemory = function() return true end,
                            close = function() end,
                        }
                    end,
                }
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_rename = os.rename
        os.rename = function()
            return nil
        end
        local original_remove = os.remove
        os.remove = function(path)
            removed_path = path
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({}, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.rename = original_rename
        os.remove = original_remove

        assert.is_false(result.ok)
        assert.are.equal("Could not finalize chapter archive.", result.error)
        assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part", removed_path)
    end)

    it("does not finalize when archive writer close reports a disk error", function()
        local removed_path
        local renamed = false

        package.preload["suwayomi/api"] = function()
            return {
                fetchChapterPages = function()
                    return {
                        ok = true,
                        pages = { "/page/0" },
                    }
                end,
                downloadBinary = function()
                    return { ok = true, body = "page-one", content_type = "image/jpeg" }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function() return true end,
                            addFileFromMemory = function() return true end,
                            close = function() return false, "disk full" end,
                        }
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_rename = os.rename
        os.rename = function()
            renamed = true
            return true
        end
        local original_remove = os.remove
        os.remove = function(path)
            removed_path = path
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({}, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.rename = original_rename
        os.remove = original_remove

        assert.is_false(result.ok)
        assert.is_false(renamed)
        assert.are.equal("Could not close chapter archive. disk full", result.error)
        assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part", removed_path)
    end)

    it("does not finalize when archive writer close throws", function()
        local removed_path
        local renamed = false

        package.preload["suwayomi/api"] = function()
            return {
                fetchChapterPages = function()
                    return {
                        ok = true,
                        pages = { "/page/0" },
                    }
                end,
                downloadBinary = function()
                    return { ok = true, body = "page-one", content_type = "image/jpeg" }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function() return true end,
                            addFileFromMemory = function() return true end,
                            close = function() error("zip footer failed") end,
                        }
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_rename = os.rename
        os.rename = function()
            renamed = true
            return true
        end
        local original_remove = os.remove
        os.remove = function(path)
            removed_path = path
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({}, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.rename = original_rename
        os.remove = original_remove

        assert.is_false(result.ok)
        assert.is_false(renamed)
        assert.truthy(result.error:match("zip footer failed"))
        assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part", removed_path)
    end)

    it("treats finalize rename failure as skipped when the target cbz already exists", function()
        local partial_path = "/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part"
        local chapter_path = "/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz"
        local removed_path
        local rename_attempted = false

        package.preload["suwayomi/api"] = function()
            return {
                fetchChapterPages = function()
                    return {
                        ok = true,
                        chapter = { id = "398", name = "Official_Vol. 1 Ch. 1", manga_title = "Sousou no Frieren" },
                        pages = { "/page/0" },
                    }
                end,
                downloadBinary = function()
                    return { ok = true, body = "page-one", content_type = "image/jpeg" }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function(path, attribute)
                    if path == chapter_path and attribute == "mode" and rename_attempted then
                        return "file"
                    end
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function() return true end,
                            addFileFromMemory = function() return true end,
                            close = function() end,
                        }
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_rename = os.rename
        os.rename = function()
            rename_attempted = true
            return nil, "File exists"
        end
        local original_remove = os.remove
        os.remove = function(path)
            removed_path = path
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({}, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.rename = original_rename
        os.remove = original_remove

        assert.is_true(result.ok)
        assert.is_true(result.skipped)
        assert.are.equal(chapter_path, result.path)
        assert.are.equal(partial_path, removed_path)
    end)

    it("rejects empty downloaded page bodies", function()
        local removed_path

        package.preload["suwayomi/api"] = function()
            return {
                fetchChapterPages = function()
                    return {
                        ok = true,
                        pages = { "/page/0" },
                    }
                end,
                downloadBinary = function()
                    return { ok = true, body = "", content_type = "image/jpeg" }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function() return true end,
                            addFileFromMemory = function()
                                error("empty page should not be written")
                            end,
                            close = function() end,
                        }
                    end,
                }
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_remove = os.remove
        os.remove = function(path)
            removed_path = path
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({}, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.remove = original_remove

        assert.is_false(result.ok)
        assert.are.equal("Downloaded chapter page was empty.", result.error)
        assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part", removed_path)
    end)

    it("rejects non-image downloaded page content", function()
        package.preload["suwayomi/api"] = function()
            return {
                fetchChapterPages = function()
                    return {
                        ok = true,
                        pages = { "/page/0" },
                    }
                end,
                downloadBinary = function()
                    return { ok = true, body = "<html>nope</html>", content_type = "text/html" }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function() return true end,
                            addFileFromMemory = function()
                                error("non-image page should not be written")
                            end,
                            close = function() end,
                        }
                    end,
                }
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({}, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        assert.is_false(result.ok)
        assert.are.equal("Downloaded chapter page was not an image.", result.error)
    end)

    it("surfaces archive close errors while cleaning up failed downloads", function()
        local removed_path
        package.preload["suwayomi/api"] = function()
            return {
                fetchChapterPages = function()
                    return {
                        ok = true,
                        pages = { "/page/0" },
                    }
                end,
                downloadBinary = function()
                    return { ok = false, error = "network timeout" }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function() return true end,
                            close = function() return false, "disk full" end,
                        }
                    end,
                }
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_remove = os.remove
        os.remove = function(path)
            removed_path = path
            return true
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({}, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.remove = original_remove

        assert.is_false(result.ok)
        assert.are.equal("network timeout Could not close chapter archive. disk full", result.error)
        assert.are.equal("/books/Unknown source/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part", removed_path)
    end)

    it("does not finalize when fewer pages were written than expected", function()
        local renamed = false
        local writer = {
            open = function() return true end,
            addFileFromMemory = function() return true end,
            close = function() end,
        }

        package.preload["suwayomi/api"] = function()
            return {}
        end
        package.preload.lfs = function()
            return {}
        end
        package.preload["ffi/archiver"] = function()
            return {}
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local downloader = require("suwayomi/downloads/downloader")
        local original_rename = os.rename
        os.rename = function()
            renamed = true
            return true
        end
        local result = downloader:downloadNextPage({
            credentials = {},
            pages = { "/page/0", "/page/1" },
            writer = writer,
            chapter_path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz",
            partial_path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1 [id-398].cbz.part",
            current = 2,
            written = 1,
        })
        os.rename = original_rename

        assert.is_false(result.ok)
        assert.is_false(renamed)
        assert.are.equal("Chapter archive page count did not match Suwayomi page count.", result.error)
    end)

    it("reports a manga directory creation failure before opening the archive", function()
        package.preload["suwayomi/api"] = function()
            return {
                fetchChapterPages = function()
                    return {
                        ok = true,
                        chapter = { id = "398", name = "Official_Vol. 1 Ch. 1", manga_title = "Sousou no Frieren" },
                        pages = { "/page/0" },
                    }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return nil
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function()
                                error("archive should not open when mkdir fails")
                            end,
                        }
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local downloader = require("suwayomi/downloads/downloader")
        local result = downloader:downloadChapter({}, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        assert.is_false(result.ok)
        assert.are.equal("Could not create manga folder.", result.error)
    end)

    it("neutralizes traversal-only manga and chapter names", function()
        package.loaded["suwayomi/downloads/downloader"] = nil
        package.loaded["suwayomi/paths"] = nil
        package.loaded["suwayomi/api"] = nil
        package.loaded["suwayomi/fs"] = nil
        package.loaded.lfs = nil
        package.loaded["ffi/archiver"] = nil
        package.loaded["ffi/util"] = nil
        package.preload.lfs = function()
            return {}
        end
        package.preload["ffi/archiver"] = function()
            return {}
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end
        package.preload["suwayomi/api"] = function()
            return {}
        end

        local downloader = require("suwayomi/downloads/downloader")
        local manga_dir, chapter_path = downloader:getTargetPath("/books", { title = ".." }, { name = ".." })

        assert.are.equal("/books/Unknown source/untitled", manga_dir)
        assert.are.equal("/books/Unknown source/untitled/untitled.cbz", chapter_path)
    end)
end)
