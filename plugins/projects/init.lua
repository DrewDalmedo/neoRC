-- lua/neo/plugins/projects/init.lua
-- Project selector built on the generic picker framework (neo.plugins.picker).
-- A "project" is normally an immediate subdirectory of a tracked parent
-- directory, and the parent's basename becomes the category tag shown
-- beside it:
--
--   Embedded   blinky        <- ~/Embedded/blinky
--   Projects   neo           <- ~/Projects/neo
--
-- The fuzzy prompt matches the whole line, so a query can hit the project
-- name, the tag, or both ("emb bl"). <CR> cds into the selected project
-- (or opens it, for file entries).
--
-- The tracked set is decided at setup(), first hit wins:
--   1. setup({ dirs = ... })
--   2. the projects section of overrides.lua (a gitignored, per-machine
--      file, same shape graphical/ uses):
--          return { projects = { dirs = { "Uni", "~/Work" } } }
--      overwrite_defaults = false next to dirs appends the list to
--      M.default_dirs instead of replacing it
--   3. M.default_dirs
--
-- A dirs entry is a path string, scanned for subdirectory projects and
-- tagged with its own basename, or a table carrying options:
--   { "Uni", tag = "School" }             scan Uni, but tag projects "School"
--   { "Work/dotfiles", single = true }    the path itself is one project
--   { "~/.wezterm.lua", file = true }     one project; <CR> opens the file
-- single/file entries default their tag to the parent directory's name and
-- their display name to the path's basename; tag = and name = replace those
-- (e.g. name = "Neo" shows Neo for a project living in .../neo).
--
-- Paths in every form resolve the same: with no prefix they are relative
-- to the home directory ("Documents" -> ~/Documents); "~/...", "/...",
-- "\\server\..." and drive-letter ("C:/...") paths are used as written.
-- Entries that don't exist are skipped silently, so one list can serve
-- every machine the config is deployed to.
local picker = require("neo.plugins.picker")
local util = require("neo.plugins.picker.util")

local M = {}

-- Tracked when neither setup{dirs} nor overrides.lua gives a set. The neo
-- config rides along as a single project from wherever this platform keeps
-- it (~/.config/nvim/lua/neo, ~/AppData/Local/nvim/lua/neo, ...).
M.default_dirs = {
    "Documents",
    "Projects",
    "Personal",
    { vim.fs.joinpath(vim.fn.stdpath("config"), "lua/neo"), single = true, tag = "Config", name = "Neo" },
}

local config = { dirs = M.default_dirs }

-- Resolve one configured path string to an absolute path. Anything without
-- a "~", "/", "\" or drive-letter prefix is taken relative to the home
-- directory; vim.fs.normalize expands the "~" portably.
function M.resolve(dir)
    if dir:match("^[~/\\]") or dir:match("^%a:") then
        return vim.fs.normalize(dir)
    end
    return vim.fs.normalize("~/" .. dir)
end

-- Normalize one dirs entry (string or table) into
-- { path, tag, kind = "scan" | "single" | "file", name? }, nil if malformed.
local function parse_entry(raw)
    local entry = type(raw) == "string" and { raw } or raw
    if type(entry) ~= "table" or type(entry[1]) ~= "string" then return nil end
    local path = M.resolve(entry[1])
    local kind = entry.file and "file" or entry.single and "single" or "scan"
    local tag = entry.tag
    if not tag then
        -- the containing directory names the category, in every kind
        tag = vim.fs.basename(kind == "scan" and path or vim.fs.dirname(path))
    end
    return { path = path, tag = tag, kind = kind, name = entry.name }
end

-- Parse the configured entries and keep those that exist with the right
-- type; complain about malformed ones instead of dropping them silently.
local function tracked_entries()
    local out = {}
    for _, raw in ipairs(config.dirs) do
        local entry = parse_entry(raw)
        if not entry then
            vim.notify("projects: ignoring malformed dirs entry: "
                .. vim.inspect(raw, { newline = " ", indent = "" }), vim.log.levels.WARN)
        else
            local stat = vim.uv.fs_stat(entry.path)
            if stat and stat.type == (entry.kind == "file" and "file" or "directory") then
                out[#out + 1] = entry
            end
        end
    end
    return out
end

-- projects.dirs from overrides.lua (module neo.overrides), or nil when the
-- file, section, or list is absent or empty. A missing file is fine; a
-- broken one is reported rather than silently ignored.
local function override_dirs()
    local ok, overrides = pcall(require, "neo.overrides")
    if not ok then
        if not tostring(overrides):find("not found", 1, true) then
            vim.notify("projects: failed to load overrides.lua:\n" .. tostring(overrides),
                vim.log.levels.ERROR)
        end
        return
    end
    if type(overrides) ~= "table" or type(overrides.projects) ~= "table" then return end
    local dirs = overrides.projects.dirs
    if type(dirs) ~= "table" or #dirs == 0 then return end
    if overrides.projects.overwrite_defaults == false then
        return vim.list_extend(vim.list_extend({}, M.default_dirs), dirs)
    end
    return dirs
end

-- Non-hidden subdirectory names of one scanned dir, sorted; symlinks count
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

-- Picker items for the given entries, in configured order (scanned dirs
-- expand to their projects in place). Tags are padded into a column, which
-- also lets the fuzzy matcher treat tag and name as separate segments.
local function build_items(entries)
    local width = 0
    for _, entry in ipairs(entries) do
        width = math.max(width, #entry.tag)
    end
    local items = {}
    local function add(entry, name, path)
        items[#items + 1] = {
            display = ("%-" .. width .. "s  %s"):format(entry.tag, name),
            tag = entry.tag,
            name = name,
            path = path,
            file = entry.kind == "file" or nil,
        }
    end
    for _, entry in ipairs(entries) do
        if entry.kind == "scan" then
            for _, name in ipairs(project_names(entry.path)) do
                add(entry, name, vim.fs.joinpath(entry.path, name))
            end
        else
            add(entry, entry.name or vim.fs.basename(entry.path), entry.path)
        end
    end
    return items
end

function M.items()
    return build_items(tracked_entries())
end

function M.open()
    local entries = tracked_entries()
    if #entries == 0 then
        vim.notify("projects: no tracked directory exists (setup{ dirs = ... })",
            vim.log.levels.WARN)
        return
    end
    local items = build_items(entries)
    if #items == 0 then
        vim.notify("projects: no projects under the tracked directories",
            vim.log.levels.WARN)
        return
    end
    return picker.open({
        title = " Projects ",
        items = items,
        on_select = function(item)
            if item.file then
                util.open_file(item.path)
                return
            end
            vim.cmd("cd " .. vim.fn.fnameescape(item.path))
            vim.notify("projects: cd " .. item.path)
        end,
    })
end

-- opts.dirs replaces the tracked set for this setup call; without it the
-- set comes from overrides.lua, then M.default_dirs.
function M.setup(opts)
    opts = opts or {}
    config.dirs = opts.dirs or override_dirs() or M.default_dirs
    vim.api.nvim_create_user_command("Projects", M.open, { desc = "Projects: select a project" })
end

return M
