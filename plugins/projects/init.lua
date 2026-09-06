-- lua/neo/plugins/projects/init.lua
-- Project selector built on the generic picker framework (neo.plugins.picker).
-- A "project" is an immediate subdirectory of a tracked parent directory, and
-- the parent's basename becomes the category label shown beside it:
--
--   Embedded   blinky        <- ~/Embedded/blinky
--   Projects   neo           <- ~/Projects/neo
--
-- The fuzzy prompt matches the whole line, so a query can hit the project
-- name, the label, or both ("emb bl"). <CR> cds into the selected project.
--
--   require("neo.plugins.projects").setup()   -- track default_dirs
--   require("neo.plugins.projects").setup({
--       dirs = { "~/Work", "D:/repos" },      -- replace the tracked set
--   })
--
-- Tracked directories that don't exist are skipped silently, so one config
-- can list the project roots of every machine it is deployed to.
local picker = require("neo.plugins.picker")

local M = {}

-- Tracked when setup() gets no dirs; each is used only where it exists.
M.default_dirs = { "~/Documents", "~/Projects", "~/Personal" }

local config = { dirs = M.default_dirs }

-- Expand the configured dirs and keep those that exist as directories,
-- labelled by their basename.
local function tracked_dirs()
    local out = {}
    for _, dir in ipairs(config.dirs) do
        local path = vim.fs.normalize(dir)
        local stat = vim.uv.fs_stat(path)
        if stat and stat.type == "directory" then
            out[#out + 1] = { path = path, label = vim.fs.basename(path) }
        end
    end
    return out
end

-- Non-hidden subdirectory names of one tracked dir, sorted; symlinks count
-- when they resolve to directories.
local function project_names(path)
    local names = {}
    pcall(function()
        for name, type in vim.fs.dir(path) do
            if not name:match("^%.") then
                if type == "link" then
                    local stat = vim.uv.fs_stat(vim.fs.joinpath(path, name))
                    type = stat and stat.type
                end
                if type == "directory" then
                    names[#names + 1] = name
                end
            end
        end
    end)
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

-- Picker items for every project under the tracked dirs, grouped in
-- configured order. Labels are padded into a column, which also lets the
-- fuzzy matcher treat label and name as separate segments.
function M.items()
    local dirs = tracked_dirs()
    local width = 0
    for _, dir in ipairs(dirs) do
        width = math.max(width, #dir.label)
    end
    local items = {}
    for _, dir in ipairs(dirs) do
        for _, name in ipairs(project_names(dir.path)) do
            items[#items + 1] = {
                display = ("%-" .. width .. "s  %s"):format(dir.label, name),
                label = dir.label,
                name = name,
                path = vim.fs.joinpath(dir.path, name),
            }
        end
    end
    return items
end

function M.open()
    if #tracked_dirs() == 0 then
        vim.notify("projects: no tracked directory exists (setup{ dirs = ... })",
            vim.log.levels.WARN)
        return
    end
    local items = M.items()
    if #items == 0 then
        vim.notify("projects: no projects under the tracked directories",
            vim.log.levels.WARN)
        return
    end
    return picker.open({
        title = " Projects ",
        items = items,
        on_select = function(item)
            vim.cmd("cd " .. vim.fn.fnameescape(item.path))
            vim.notify("projects: cd " .. item.path)
        end,
    })
end

-- opts.dirs replaces the tracked set; to extend the defaults instead:
--   dirs = vim.list_extend({ "~/Work" }, require("neo.plugins.projects").default_dirs)
function M.setup(opts)
    opts = opts or {}
    if opts.dirs then config.dirs = opts.dirs end
    vim.api.nvim_create_user_command("Projects", M.open, { desc = "Projects: select a project" })
end

return M
