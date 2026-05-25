-- Boundary: directory chooser UI construction.
--
-- Responsibility: adapt KOReader's PathChooser into the plugin's
-- "choose download directory" callback contract.
-- Owned state: none.
-- Dependencies: PathChooser and UIManager are required when the chooser opens so
-- specs can stub them per example.
-- External data: selected paths are returned to controller code for persistence
-- and filesystem validation; this module only constructs the widget.

local I18n = require("suwayomi/i18n")

local DirectoryUI = {}
local NEW_FOLDER_ACTION = "new_folder"

local function isKOReaderCurrentFolderItem(item)
    return item and type(item.path) == "string" and item.path:sub(-2, -1) == "/."
end

local function isNewFolderItem(item)
    return item and item.suwayomi_action == NEW_FOLDER_ACTION
end

function DirectoryUI.showDirectoryChooser(callback, start_dir)
    local PathChooser = require("ui/widget/pathchooser")
    local UIManager = require("ui/uimanager")

    local DirectoryChooser = PathChooser:extend{
        title = I18n.t("Choose download directory"),
        select_directory = true,
        select_file = false,
        show_files = false,
        show_path = true,
    }

    function DirectoryChooser:genItemTable(dirs, files, path)
        local item_table = PathChooser.genItemTable(self, dirs, files, path)
        local new_folder_index = 1
        if path then
            local current_folder_path = path .. "/."
            for index = 1, #item_table do
                local item = item_table[index]
                if item.path == current_folder_path then
                    item.text = I18n.t("Use this folder")
                    item.bold = true
                    new_folder_index = index + 1
                    break
                end
            end
            table.insert(item_table, new_folder_index, {
                text = I18n.t("New folder"),
                suwayomi_action = NEW_FOLDER_ACTION,
            })
        end
        return item_table
    end

    function DirectoryChooser:showNewFolderDialog()
        local FileManager = require("apps/filemanager/filemanager")
        FileManager.file_chooser = self
        FileManager:createFolder()
        return true
    end

    function DirectoryChooser:onMenuSelect(item)
        if isNewFolderItem(item) then
            return self:showNewFolderDialog()
        end
        if isKOReaderCurrentFolderItem(item) then
            return PathChooser.onMenuHold(self, item)
        end
        return PathChooser.onMenuSelect(self, item)
    end

    function DirectoryChooser:onMenuHold(item)
        if isNewFolderItem(item) then
            return self:showNewFolderDialog()
        end
        return PathChooser.onMenuHold(self, item)
    end

    local path_chooser = DirectoryChooser:new{
        path = start_dir,
        onConfirm = function(path)
            if callback then
                callback(path)
            end
        end,
    }
    UIManager:show(path_chooser)
end

return DirectoryUI
