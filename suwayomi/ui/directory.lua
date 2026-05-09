-- Boundary: directory chooser UI construction.
--
-- Responsibility: adapt KOReader's PathChooser into the plugin's
-- "choose download directory" callback contract.
-- Owned state: none.
-- Dependencies: PathChooser and UIManager are required when the chooser opens so
-- specs can stub them per example.
-- External data: selected paths are returned to controller code for persistence
-- and filesystem validation; this module only constructs the widget.

local _ = require("gettext")

local DirectoryUI = {}

local function isKOReaderCurrentFolderItem(item)
    return item and type(item.path) == "string" and item.path:sub(-2, -1) == "/."
end

function DirectoryUI.showDirectoryChooser(callback, start_dir)
    local PathChooser = require("ui/widget/pathchooser")
    local UIManager = require("ui/uimanager")

    local DirectoryChooser = PathChooser:extend{
        title = _("Choose download directory"),
        select_directory = true,
        select_file = false,
        show_files = false,
        show_path = true,
    }

    function DirectoryChooser:genItemTable(dirs, files, path)
        local item_table = PathChooser.genItemTable(self, dirs, files, path)
        if path then
            local current_folder_path = path .. "/."
            for index = 1, #item_table do
                local item = item_table[index]
                if item.path == current_folder_path then
                    item.text = _("Use this folder")
                    item.bold = true
                    break
                end
            end
        end
        return item_table
    end

    function DirectoryChooser:onMenuSelect(item)
        if isKOReaderCurrentFolderItem(item) then
            return PathChooser.onMenuHold(self, item)
        end
        return PathChooser.onMenuSelect(self, item)
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
