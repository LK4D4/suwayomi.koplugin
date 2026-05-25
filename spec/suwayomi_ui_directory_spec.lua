package.path = "?.lua;" .. package.path

-- Directory UI specs verify the PathChooser adapter. Directory persistence and
-- retry flow are covered in suwayomi_downloads_directory_spec.lua.
describe("suwayomi/ui/directory", function()
    local shown_dialog
    local created_folder_with
    local Marker

    before_each(function()
        shown_dialog = nil
        created_folder_with = nil

        package.loaded["suwayomi/ui/directory"] = nil
        package.loaded["suwayomi/i18n"] = nil
        package.loaded["ui/widget/pathchooser"] = nil
        package.loaded["ui/uimanager"] = nil
        package.loaded["apps/filemanager/filemanager"] = nil

        Marker = require("spec/support/i18n_marker")
        Marker.install()

        package.preload["ui/widget/pathchooser"] = function()
            local PathChooser = {}

            function PathChooser:extend(definition)
                definition.__index = definition
                return setmetatable(definition, {
                    __index = self,
                    __call = function(class, instance)
                        instance = instance or {}
                        setmetatable(instance, class)
                        if instance.init then
                            instance:init()
                        end
                        return instance
                    end,
                })
            end

            function PathChooser:new(options)
                options = options or {}
                setmetatable(options, self)
                if options.init then
                    options:init()
                end
                return options
            end

            function PathChooser:init()
                if self.select_directory then
                    self.show_current_dir_for_hold = true
                end
            end

            function PathChooser:genItemTable(_, _, path)
                return {
                    {
                        text = "Long-press here to choose current folder",
                        bold = true,
                        path = path .. "/.",
                    },
                    {
                        text = "Sousou no Frieren/",
                        path = path .. "/Sousou no Frieren",
                    },
                }
            end

            function PathChooser:onMenuSelect(item)
                self.selected_path = item.path
                return true
            end

            function PathChooser:onMenuHold(item)
                self.held_path = item.path
                if self.onConfirm then
                    self.onConfirm((item.path:gsub("/%.$", "")))
                end
                return true
            end

            return PathChooser
        end

        package.preload["ui/uimanager"] = function()
            return {
                show = function(_, widget)
                    shown_dialog = widget
                end,
            }
        end

        package.preload["apps/filemanager/filemanager"] = function()
            return {
                createFolder = function(self)
                    created_folder_with = self.file_chooser
                end,
            }
        end
    end)

    after_each(function()
        Marker.uninstall()
        package.preload["ui/widget/pathchooser"] = nil
        package.preload["ui/uimanager"] = nil
        package.preload["apps/filemanager/filemanager"] = nil
    end)

    it("uses KOReader path chooser to choose a directory", function()
        local directory = require("suwayomi/ui/directory")
        local chosen_path

        directory.showDirectoryChooser(function(path)
            chosen_path = path
        end)

        assert.are.equal("tx:Choose download directory", shown_dialog.title)
        assert.is_true(shown_dialog.select_directory)
        assert.is_false(shown_dialog.select_file)
        assert.is_false(shown_dialog.show_files)
        shown_dialog.onConfirm("/storage/emulated/0/Books/Manga")
        assert.are.equal("/storage/emulated/0/Books/Manga", chosen_path)
    end)

    it("starts the directory chooser in the provided directory and keeps the path visible", function()
        local directory = require("suwayomi/ui/directory")

        directory.showDirectoryChooser(function() end, "/storage/emulated/0/Books/Manga")

        assert.are.equal("/storage/emulated/0/Books/Manga", shown_dialog.path)
        assert.is_true(shown_dialog.show_path)
    end)

    it("shows a visible use-this-folder action for the current directory", function()
        local directory = require("suwayomi/ui/directory")
        local chosen_path

        directory.showDirectoryChooser(function(path)
            chosen_path = path
        end, "/storage/emulated/0/Books/Manga")

        local item_table = shown_dialog:genItemTable({}, {}, "/storage/emulated/0/Books/Manga")

        assert.are.equal("tx:Use this folder", item_table[1].text)
        assert.are.equal("/storage/emulated/0/Books/Manga/.", item_table[1].path)

        shown_dialog:onMenuSelect(item_table[1])

        assert.are.equal("/storage/emulated/0/Books/Manga/.", shown_dialog.held_path)
        assert.are.equal("/storage/emulated/0/Books/Manga", chosen_path)
    end)

    it("keeps current folder selection under KOReader path chooser hold handling", function()
        local directory = require("suwayomi/ui/directory")
        local chosen_path
        local instance_hold_called = false

        directory.showDirectoryChooser(function(path)
            chosen_path = path
        end, "/storage/emulated/0/Books/Manga")

        local item_table = shown_dialog:genItemTable({}, {}, "/storage/emulated/0/Books/Manga")
        shown_dialog.onMenuHold = function()
            instance_hold_called = true
            return true
        end

        shown_dialog:onMenuSelect(item_table[1])

        assert.is_false(instance_hold_called)
        assert.are.equal("/storage/emulated/0/Books/Manga/.", shown_dialog.held_path)
        assert.are.equal("/storage/emulated/0/Books/Manga", chosen_path)
    end)

    it("keeps child folder taps under KOReader path chooser navigation handling", function()
        local directory = require("suwayomi/ui/directory")
        local chosen_path

        directory.showDirectoryChooser(function(path)
            chosen_path = path
        end, "/storage/emulated/0/Books/Manga")

        local item_table = shown_dialog:genItemTable({}, {}, "/storage/emulated/0/Books/Manga")

        shown_dialog:onMenuSelect(item_table[3])

        assert.are.equal("/storage/emulated/0/Books/Manga/Sousou no Frieren", shown_dialog.selected_path)
        assert.is_nil(shown_dialog.held_path)
        assert.is_nil(chosen_path)
    end)

    it("shows a visible new-folder action that opens KOReader folder creation", function()
        local directory = require("suwayomi/ui/directory")

        directory.showDirectoryChooser(function() end, "/storage/emulated/0/Books")

        local item_table = shown_dialog:genItemTable({}, {}, "/storage/emulated/0/Books")

        assert.are.equal("tx:Use this folder", item_table[1].text)
        assert.are.equal("tx:New folder", item_table[2].text)

        shown_dialog:onMenuSelect(item_table[2])

        assert.are.equal(shown_dialog, created_folder_with)
    end)
end)
