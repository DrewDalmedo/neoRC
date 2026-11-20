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
-- name, the tag, or both ("emb bl"). <CR> switches into the selected
-- project: every open buffer is killed (modified buffers backed by a real
-- file are saved first; scratch, terminal, and unnamed buffers are
-- discarded), spare tabs and windows are closed, the working directory
-- moves, and the remaining window shows a netrw listing of the project
-- root. File entries skip all of that; <CR> just opens the file.
--
-- The picker also changes what is tracked (its bottom border lists these):
--   <C-n>  new project: choose the tracked directory it goes in (skipped
--          when only one can hold projects; the highlighted project's own
--          is offered first), name it (the prompt starts out with what you
--          had typed), and switch into it as <CR> would
--   <C-t>  track a directory, read like a dirs entry below ("Work" is
--          ~/Work) and created when it doesn't exist; one with no projects
--          yet goes straight on to naming its first
--   <C-x>  untrack an entry of any kind, wherever it was configured (the
--          highlighted project's own is offered first), then say whether
--          to delete it from disk too (No unless you answer Yes)
--   <C-d>  delete the highlighted project from disk (a file entry's file),
--          after saying Yes to a question that defaults to No
-- :Projects new [name], track [path], untrack [path] and delete [path] do
-- the same from the command line. The picker opens even with nothing to
-- list, so these keys are always reachable.
--
-- Deleting never touches the home directory, a filesystem root, anything
-- holding one, or anything overlapping Neovim's config; a symlink is
-- removed itself, never what it points to. A working directory inside
-- what goes moves to its parent, and buffers of files that went with it
-- are wiped (the question warns about unsaved changes among them).
--
-- The tracked set is decided at setup(), first hit wins:
--   1. setup({ dirs = ... })
--   2. the projects section of overrides.lua (a gitignored, per-machine
--      file, same shape graphical/ uses):
--          return { projects = { dirs = { "Uni", "~/Work" } } }
--      the list is appended to M.default_dirs (re-listing a default's
--      path replaces that default instead of duplicating it);
--      overwrite_defaults = true next to dirs replaces the whole set
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
--
-- Tracking and untracking (the keys above) is saved per machine, in
-- stdpath("data")/neo/projects.json (see store.lua), and applies on top of
-- whichever set setup() settled on: tracked directories are appended to
-- it (unless it lists them already), untracked entries are left out of
-- it, and tracking an untracked entry again brings it back with its
-- configured options.
--
-- setup() also names projects for the picker's statusline (see
-- picker/statusline.lua): with a project as the working directory, files
-- in it show as "Config: init.lua", under the name the picker lists the
-- project by.
local picker = require("neo.plugins.picker")
local util = require("neo.plugins.picker.util")
local statusline = require("neo.plugins.picker.statusline")
local store = require("neo.plugins.projects.store")

local M = {}

-- Tracked when neither setup{dirs} nor overrides.lua gives a set. The neo
-- config rides along as a single project from wherever this platform keeps
-- it (~/.config/nvim/lua/neo, ~/AppData/Local/nvim/lua/neo, ...).
M.default_dirs = {
    "Projects",
    { vim.fs.joinpath(vim.fn.stdpath("config"), "lua/neo"), single = true, tag = "Neovim", name = "Config" },
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

-- path as shown to you: under the home directory as ~/...
local function short(path)
    return vim.fn.fnamemodify(path, ":~")
end

-- Whether path is dir or inside it (both absolute and normalized).
local function inside(path, dir)
    path, dir = store.key(path), store.key(dir)
    if path == dir then return true end
    local prefix = dir:sub(-1) == "/" and dir or dir .. "/"
    return path:sub(1, #prefix) == prefix
end

-- path normalized and, when it differs, resolved too: a symlink along
-- the way (macOS's /var -> /private/var) mustn't hide an overlap.
local function forms(path)
    local out = { vim.fs.normalize(path) }
    local real = vim.uv.fs_realpath(path)
    if real and vim.fs.normalize(real) ~= out[1] then
        out[2] = vim.fs.normalize(real)
    end
    return out
end

-- Every tracked entry, whether or not it exists: the configured ones
-- (malformed ones complained about rather than dropped silently) minus
-- those untracked from the picker, then the directories tracked from the
-- picker that the configured set doesn't already list. Saved ones carry
-- saved = true. quiet is for the statusline, which can't be notifying:
-- malformed entries are skipped without a word, and a broken
-- projects.json is left for a louder read to report.
local function all_entries(quiet)
    local saved = store.read(quiet)
    local out, listed = {}, {}
    for _, raw in ipairs(config.dirs) do
        local entry = parse_entry(raw)
        if not entry then
            if not quiet then
                vim.notify("projects: ignoring malformed dirs entry: "
                    .. vim.inspect(raw, { newline = " ", indent = "" }), vim.log.levels.WARN)
            end
        elseif not store.has(saved.untracked, entry.path) then
            out[#out + 1] = entry
            listed[store.key(entry.path)] = true
        end
    end
    for _, path in ipairs(saved.dirs) do
        local entry = parse_entry(path)
        if entry and not listed[store.key(entry.path)]
            and not store.has(saved.untracked, entry.path) then
            entry.saved = true
            out[#out + 1] = entry
            listed[store.key(entry.path)] = true
        end
    end
    return out
end

-- Whether entry's path exists with the type its kind needs.
local function exists(entry)
    local stat = vim.uv.fs_stat(entry.path)
    return stat ~= nil and stat.type == (entry.kind == "file" and "file" or "directory")
end

-- The tracked entries that exist, in order (quiet as for all_entries).
local function tracked_entries(quiet)
    local out = {}
    for _, entry in ipairs(all_entries(quiet)) do
        if exists(entry) then
            out[#out + 1] = entry
        end
    end
    return out
end

-- The first of entries at path; with dirs_only, file entries don't count.
local function find_entry(entries, path, dirs_only)
    local key = store.key(path)
    for _, entry in ipairs(entries) do
        if store.key(entry.path) == key and not (dirs_only and entry.kind == "file") then
            return entry
        end
    end
end

-- Whether setup()'s set (untracked or not) has an entry at path.
local function configured(path)
    local key = store.key(path)
    for _, raw in ipairs(config.dirs) do
        local entry = parse_entry(raw)
        if entry and store.key(entry.path) == key then
            return true
        end
    end
    return false
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
    if overrides.projects.overwrite_defaults then
        return dirs
    end
    -- append to the defaults, dropping any default whose resolved path the
    -- overrides list re-lists so that entry (and its options) wins
    local listed = {}
    for _, raw in ipairs(dirs) do
        local entry = parse_entry(raw)
        if entry then listed[entry.path] = true end
    end
    local merged = {}
    for _, raw in ipairs(M.default_dirs) do
        local entry = parse_entry(raw)
        if not (entry and listed[entry.path]) then
            merged[#merged + 1] = raw
        end
    end
    return vim.list_extend(merged, dirs)
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
            entry = entry,
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

-- Picker items for tracked entries themselves rather than the projects in
-- them: tag, path, and what kind of entry it is unless it's a scanned one.
-- near's entry is moved to the top, so it starts out highlighted.
local function entry_items(entries, near)
    local width = 0
    for _, entry in ipairs(entries) do
        width = math.max(width, #entry.tag)
    end
    local items = {}
    for _, entry in ipairs(entries) do
        local note = entry.kind == "scan" and "" or ("  (" .. entry.kind .. ")")
        if not exists(entry) then
            note = note .. "  (missing)"
        end
        local item = {
            display = ("%-" .. width .. "s  %s%s"):format(entry.tag, short(entry.path), note),
            entry = entry,
        }
        if near and store.key(near.path) == store.key(entry.path) then
            table.insert(items, 1, item)
        else
            items[#items + 1] = item
        end
    end
    return items
end

-- The name the picker lists the project at dir by, or nil when dir isn't
-- a tracked project. Real paths are compared, so a symlink on either side
-- (a config dir linked from dotfiles) still matches.
function M.name(dir)
    local real = vim.uv.fs_realpath(dir)
    if not real then return nil end
    for _, item in ipairs(build_items(tracked_entries(true))) do
        if not item.file and vim.uv.fs_realpath(item.path) == real then
            return item.name
        end
    end
end

-- Make `path` (resolved like a dirs entry) the active project. Every open
-- buffer is killed so nothing from the old project lingers: modified
-- buffers backed by a real file are saved first, while scratch, terminal,
-- and unnamed buffers have nowhere to be saved and are discarded. A buffer
-- whose write fails is kept alive (and complained about) rather than
-- losing its changes. Spare tabs and windows are closed, the working
-- directory moves, and the surviving window ends up on a fresh netrw
-- listing of the project root.
function M.switch(path)
    path = M.resolve(path)
    local stat = vim.uv.fs_stat(path)
    if not stat or stat.type ~= "directory" then
        vim.notify("projects: not a directory: " .. path, vim.log.levels.ERROR)
        return
    end
    pcall(vim.cmd, "silent tabonly!")
    pcall(vim.cmd, "silent only!")
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
            local keep = false
            if vim.bo[buf].modified then
                local file = vim.api.nvim_buf_get_name(buf)
                if vim.bo[buf].buftype == "" and file ~= "" then
                    local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
                        vim.cmd("silent write")
                    end)
                    if not ok then
                        keep = true
                        vim.notify(("projects: keeping %s, save failed:\n%s"):format(file, err),
                            vim.log.levels.ERROR)
                    end
                end
            end
            if not keep then
                pcall(vim.api.nvim_buf_delete, buf, { force = true })
            end
        end
    end
    vim.cmd("cd " .. vim.fn.fnameescape(path))
    vim.cmd("Explore " .. vim.fn.fnameescape(path))
    vim.notify("projects: switched to " .. path)
end

-- Saves doc to the store, as an error message on failure. The statusline
-- remembers project names, which a change to the tracked set can change
-- (an untracked Config shows as neo again), so it forgets them.
local function save(doc)
    local ok, err = store.write(doc)
    if not ok then
        return nil, "couldn't save the tracked set: " .. tostring(err)
    end
    statusline.forget()
    return true
end

--- Track the directory at path (resolved like a dirs entry), creating it
--- when it doesn't exist: from now on its subdirectories are projects, in
--- this session and later ones. An entry untracked earlier comes back as
--- it was configured instead. Returns the resolved path and whether it had
--- to be created, or nil and an error.
function M.track(path)
    path = M.resolve(vim.trim(path))
    local saved = store.read()
    if store.has(saved.untracked, path) then
        saved.untracked = store.without(saved.untracked, path)
        if configured(path) then
            local ok, err = save(saved)
            if not ok then return nil, err end
            return path, false
        end
    end
    local stat = vim.uv.fs_stat(path)
    if stat and stat.type ~= "directory" then
        return nil, "not a directory: " .. short(path)
    end
    local entry = find_entry(all_entries(), path, true)
    if entry and stat then
        return nil, "already tracked: " .. short(path)
    end
    if not stat then
        local ok, err = pcall(vim.fn.mkdir, path, "p")
        if not ok or vim.fn.isdirectory(path) == 0 then
            return nil, ("couldn't create %s%s"):format(short(path), ok and "" or (": " .. tostring(err)))
        end
    end
    -- an entry that was only missing on disk is tracked already
    if not entry and not store.has(saved.dirs, path) then
        saved.dirs[#saved.dirs + 1] = path
    end
    local ok, err = save(saved)
    if not ok then return nil, err end
    return path, not stat
end

--- Stop tracking path (resolved like a dirs entry), whatever kind of
--- entry it is and wherever it came from: one tracked from the picker is
--- forgotten, a configured one is left out from now on. Nothing on disk is
--- touched, and M.track brings it back. Returns true, or nil and an error.
function M.untrack(path)
    path = M.resolve(vim.trim(path))
    if not find_entry(all_entries(), path) then
        return nil, "not tracked: " .. short(path)
    end
    local saved = store.read()
    saved.dirs = store.without(saved.dirs, path)
    if configured(path) and not store.has(saved.untracked, path) then
        saved.untracked[#saved.untracked + 1] = path
    end
    return save(saved)
end

--- Make the directory for a project called name in parent (resolved like
--- a dirs entry). name is a single directory: no / or \, and no leading
--- dot (the picker hides those). Returns the new path, or nil and an
--- error; nothing is created on an error.
function M.create_project(parent, name)
    name = vim.trim(name or "")
    if name == "" then
        return nil, "a project needs a name"
    end
    if name:find("[/\\]") then
        return nil, "a project name can't contain / or \\: " .. name
    end
    if name:sub(1, 1) == "." then
        return nil, "a project name can't start with a dot: " .. name
    end
    parent = M.resolve(parent)
    local stat = vim.uv.fs_stat(parent)
    if not stat or stat.type ~= "directory" then
        return nil, "not a directory: " .. short(parent)
    end
    local path = vim.fs.joinpath(parent, name)
    if vim.uv.fs_lstat(path) then
        return nil, "already exists: " .. short(path)
    end
    local ok, err = vim.uv.fs_mkdir(path, tonumber("755", 8))
    if not ok then
        return nil, ("couldn't create %s: %s"):format(short(path), tostring(err))
    end
    return path
end

--- Why path mustn't be deleted, or nil when it may be. Kept: the home
--- directory, a filesystem root, anything holding either, and anything
--- overlapping Neovim's config (the running config included). Deleting a
--- symlink removes only the link, so only its own path counts.
function M.protected(path)
    path = vim.fs.normalize(path)
    local stat = vim.uv.fs_lstat(path)
    local mine = (stat and stat.type == "link") and { path } or forms(path)
    for _, p in ipairs(mine) do
        local parent = vim.fs.dirname(p)
        if parent == nil or parent == p or p:match("^%a:/?$") then
            return "it's a filesystem root"
        end
        for _, home in ipairs(forms(vim.uv.os_homedir())) do
            if inside(home, p) then
                return "it holds your home directory"
            end
        end
        for _, config in ipairs(forms(vim.fn.stdpath("config"))) do
            if inside(config, p) then
                return "it holds your Neovim config"
            end
            if inside(p, config) then
                return "it's part of your Neovim config"
            end
        end
    end
end

-- The paths buffers going with path are named under: a link's own, or
-- the directory's (in both forms).
local function buffer_roots(path, stat)
    return stat.type == "link" and { vim.fs.normalize(path) } or forms(path)
end

local function under(name, roots)
    name = vim.fs.normalize(name)
    for _, root in ipairs(roots) do
        if inside(name, root) then return true end
    end
    return false
end

-- How many listed buffers with unsaved changes are of files under path.
local function unsaved_under(path)
    local stat = vim.uv.fs_lstat(path)
    if not stat then return 0 end
    local roots, count = buffer_roots(path, stat), 0
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(buf)
        if vim.bo[buf].modified and vim.bo[buf].buftype == "" and name ~= ""
            and under(name, roots) then
            count = count + 1
        end
    end
    return count
end

--- Delete path (resolved like a dirs entry) from disk: a directory with
--- everything in it, a file, or a symlink (the link, never what it points
--- to). Refuses whatever M.protected keeps. A working directory inside it
--- moves to its parent first, and buffers whose files went with it are
--- wiped, unsaved changes and all. Returns true, or nil and an error.
function M.delete(path)
    path = M.resolve(vim.trim(path))
    local stat = vim.uv.fs_lstat(path)
    if not stat then
        return nil, "nothing to delete at " .. short(path)
    end
    local why = M.protected(path)
    if why then
        return nil, ("won't delete %s: %s"):format(short(path), why)
    end
    local roots = buffer_roots(path, stat)
    -- off it first: Windows can't delete a directory that is in use
    if under(vim.fn.getcwd(-1, -1), roots) then
        vim.cmd("cd " .. vim.fn.fnameescape(vim.fs.dirname(path)))
    end
    local failed = vim.fn.delete(path, stat.type == "directory" and "rf" or "") ~= 0
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= "" and under(name, roots) and not vim.uv.fs_lstat(name) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end
    if failed or vim.uv.fs_lstat(path) then
        return nil, "couldn't delete all of " .. short(path)
    end
    return true
end

-- A yes/no question that defaults to No; true only for Yes. The redraw
-- clears the question away, so the message that follows doesn't stack
-- under it into a "Press ENTER" prompt.
local function ask(question)
    local yes = vim.fn.confirm(question, "&Yes\n&No", 2) == 1
    vim.cmd("redraw")
    return yes
end

-- What deleting path takes with it, for a question: projects is how many
-- projects a tracked directory holds.
local function doomed(path, projects)
    local stat = vim.uv.fs_lstat(path)
    local what
    if stat.type == "link" then
        what = ("the link %s (what it points to is kept)"):format(short(path))
    elseif stat.type ~= "directory" then
        what = "the file " .. short(path)
    else
        what = short(path) .. " and everything in it"
        if projects and projects > 0 then
            what = what .. (" (%d project%s)"):format(projects, projects == 1 and "" or "s")
        end
    end
    return what
end

-- A line for the end of a question about deleting path, warning about
-- unsaved changes that would go with it; "" when there are none.
local function unsaved_note(path)
    local unsaved = unsaved_under(path)
    if unsaved == 0 then return "" end
    return ("\n%d open buffer%s with unsaved changes would go too.")
        :format(unsaved, unsaved == 1 and "" or "s")
end

--- Delete a project from disk once you say Yes: opts.item (a picker item)
--- or the one at opts.path (any project the picker lists, a file entry's
--- file included), else one chosen from a picker. opts.back runs after a
--- deletion, when given.
function M.delete_prompt(opts)
    opts = opts or {}
    local function go(item)
        local why = M.protected(item.path)
        if why then
            vim.notify(("projects: won't delete %s: %s"):format(short(item.path), why),
                vim.log.levels.WARN)
            return
        end
        if not vim.uv.fs_lstat(item.path) then
            vim.notify("projects: nothing to delete at " .. short(item.path), vim.log.levels.WARN)
            return
        end
        if not ask("Delete " .. doomed(item.path) .. "?" .. unsaved_note(item.path)) then return end
        local ok, err = M.delete(item.path)
        if not ok then
            vim.notify("projects: " .. err, vim.log.levels.ERROR)
            return
        end
        vim.notify("projects: deleted " .. short(item.path))
        if opts.back then opts.back() end
    end
    if opts.item then
        return go(opts.item)
    end
    local items = M.items()
    if opts.path and vim.trim(opts.path) ~= "" then
        local key = store.key(M.resolve(vim.trim(opts.path)))
        for _, item in ipairs(items) do
            if store.key(vim.fs.normalize(item.path)) == key then
                return go(item)
            end
        end
        vim.notify(("projects: not a project: %s (untracking a tracked directory"
            .. " offers to delete it)"):format(short(M.resolve(vim.trim(opts.path)))),
            vim.log.levels.WARN)
        return
    end
    if #items == 0 then
        vim.notify("projects: no projects to delete", vim.log.levels.WARN)
        return
    end
    return picker.open({
        title = " Delete project ",
        items = items,
        on_select = function(item)
            vim.schedule(function() go(item) end)
        end,
    })
end

-- Directory completion for prompts, as a vim.ui.input completion spec.
local COMPLETE_DIR = "customlist,v:lua.require'neo.plugins.projects'.complete_dir"

--- Completes a directory path read like a dirs entry: a bare name
--- completes from the home directory, which is where it resolves.
function M.complete_dir(lead)
    if lead:match("^[~/\\]") or lead:match("^%a:") then
        return vim.fn.getcompletion(lead, "dir")
    end
    local out = {}
    for _, cand in ipairs(vim.fn.getcompletion("~/" .. lead, "dir")) do
        out[#out + 1] = (cand:gsub("^~[/\\]", ""))
    end
    return out
end

--- Make a new project and switch into it. Asks which tracked directory it
--- goes in, unless opts.parent gives it or only one can hold projects
--- (opts.near is the entry to offer first), then for its name, unless
--- opts.name gives it (opts.default pre-fills the prompt).
function M.new_project(opts)
    opts = opts or {}
    local function create(parent, name)
        local path, err = M.create_project(parent, name)
        if not path then
            vim.notify("projects: " .. err, vim.log.levels.ERROR)
            return
        end
        M.switch(path)
    end
    local function name_it(parent)
        if opts.name and vim.trim(opts.name) ~= "" then
            return create(parent, opts.name)
        end
        vim.ui.input({
            prompt = ("New project in %s/: "):format(short(parent)),
            default = opts.default,
        }, function(name)
            if name and vim.trim(name) ~= "" then
                create(parent, name)
            end
        end)
    end
    if opts.parent then
        return name_it(M.resolve(opts.parent))
    end
    local dirs = {}
    for _, entry in ipairs(tracked_entries()) do
        if entry.kind == "scan" then
            dirs[#dirs + 1] = entry
        end
    end
    if #dirs == 0 then
        vim.notify("projects: no tracked directory to make a project in"
            .. " (<C-t> or :Projects track adds one)", vim.log.levels.WARN)
        return
    end
    if #dirs == 1 then
        return name_it(dirs[1].path)
    end
    return picker.open({
        title = " New project in ",
        items = entry_items(dirs, opts.near),
        on_select = function(item)
            vim.schedule(function() name_it(item.entry.path) end)
        end,
    })
end

--- Track a directory, asking for it unless opts.path gives it. One with no
--- projects in it yet goes straight on to naming its first (Esc there
--- leaves it tracked); otherwise opts.back runs, when given.
function M.track_prompt(opts)
    opts = opts or {}
    local function go(input)
        if not input or vim.trim(input) == "" then return end
        local path, created = M.track(input)
        if not path then
            vim.notify("projects: " .. created, vim.log.levels.WARN)
            return
        end
        vim.notify(("projects: tracking %s%s"):format(short(path), created and " (created it)" or ""))
        local entry = find_entry(tracked_entries(), path, true)
        if entry and entry.kind == "scan" and #project_names(path) == 0 then
            M.new_project({ parent = path })
        elseif opts.back then
            opts.back()
        end
    end
    if opts.path and vim.trim(opts.path) ~= "" then
        return go(opts.path)
    end
    vim.ui.input({ prompt = "Track directory: ", default = "~/", completion = COMPLETE_DIR }, go)
end

--- Untrack an entry, asking which unless opts.path names it (opts.near is
--- the entry to offer first), then whether to delete it from disk too,
--- unless it's gone already or M.protected keeps it. opts.back runs
--- afterwards, when given.
function M.untrack_prompt(opts)
    opts = opts or {}
    local function go(path)
        path = M.resolve(vim.trim(path))
        local entry = find_entry(all_entries(), path)
        local ok, err = M.untrack(path)
        if not ok then
            vim.notify("projects: " .. err, vim.log.levels.WARN)
            return
        end
        local projects = entry and entry.kind == "scan" and #project_names(path) or nil
        if vim.uv.fs_lstat(path) and not M.protected(path)
            and ask(("Untracked %s. Delete %s too?%s")
                :format(short(path), doomed(path, projects), unsaved_note(path))) then
            local deleted, derr = M.delete(path)
            if deleted then
                vim.notify(("projects: untracked and deleted %s"):format(short(path)))
            else
                vim.notify(("projects: untracked %s, but %s"):format(short(path), derr),
                    vim.log.levels.ERROR)
            end
        else
            vim.notify(("projects: untracked %s (left on disk)"):format(short(path)))
        end
        if opts.back then opts.back() end
    end
    if opts.path and vim.trim(opts.path) ~= "" then
        return go(opts.path)
    end
    local entries = all_entries()
    if #entries == 0 then
        vim.notify("projects: nothing is tracked", vim.log.levels.WARN)
        return
    end
    return picker.open({
        title = " Untrack ",
        items = entry_items(entries, opts.near),
        on_select = function(item)
            vim.schedule(function() go(item.entry.path) end)
        end,
    })
end

local KEYS_HINT = " <C-n> new · <C-t> track · <C-x> untrack · <C-d> delete "

function M.open()
    local function reopen() M.open() end
    return picker.open({
        title = " Projects ",
        items = M.items(),
        footer = KEYS_HINT,
        on_select = function(item)
            if item.file then
                util.open_file(item.path)
                return
            end
            M.switch(item.path)
        end,
        -- each closes the picker and carries on once the key is done, so
        -- the prompts and pickers that follow open cleanly
        keys = {
            ["<C-n>"] = function(p)
                local query, sel = p:query(), p:selection()
                p:close()
                vim.schedule(function()
                    M.new_project({ default = query, near = sel and sel.entry })
                end)
            end,
            ["<C-t>"] = function(p)
                p:close()
                vim.schedule(function() M.track_prompt({ back = reopen }) end)
            end,
            ["<C-x>"] = function(p)
                local sel = p:selection()
                p:close()
                vim.schedule(function()
                    M.untrack_prompt({ near = sel and sel.entry, back = reopen })
                end)
            end,
            ["<C-d>"] = function(p)
                local sel = p:selection()
                if not sel then return end
                p:close()
                vim.schedule(function() M.delete_prompt({ item = sel, back = reopen }) end)
            end,
        },
    })
end

local SUBCOMMANDS = { "new", "track", "untrack", "delete" }

--- :Projects completion: the subcommand, then a directory for track, a
--- tracked path for untrack, or a project's path for delete.
function M.complete(lead, line, pos)
    local words = vim.split(line:sub(1, pos):gsub("^%s+", ""), "%s+")
    if #words <= 2 then
        return vim.tbl_filter(function(s) return vim.startswith(s, lead) end, SUBCOMMANDS)
    end
    if words[2] == "track" then
        return M.complete_dir(lead)
    end
    if words[2] == "untrack" then
        local out = {}
        for _, entry in ipairs(all_entries()) do
            local path = short(entry.path)
            if vim.startswith(path, lead) then
                out[#out + 1] = path
            end
        end
        return out
    end
    if words[2] == "delete" then
        local out = {}
        for _, item in ipairs(M.items()) do
            local path = short(item.path)
            if vim.startswith(path, lead) then
                out[#out + 1] = path
            end
        end
        return out
    end
    return {}
end

--- :Projects [new [name] | track [path] | untrack [path] | delete [path]]
function M.command(args)
    local sub, rest = args:match("^%s*(%S*)%s*(.-)%s*$")
    if sub == "" then
        return M.open()
    elseif sub == "new" then
        return M.new_project({ name = rest })
    elseif sub == "track" then
        return M.track_prompt({ path = rest })
    elseif sub == "untrack" then
        return M.untrack_prompt({ path = rest })
    elseif sub == "delete" then
        return M.delete_prompt({ path = rest })
    end
    vim.notify(("projects: unknown subcommand %s (new, track, untrack or delete)"):format(sub),
        vim.log.levels.ERROR)
end

-- opts.dirs replaces the tracked set for this setup call; without it the
-- set comes from overrides.lua, then M.default_dirs.
function M.setup(opts)
    opts = opts or {}
    config.dirs = opts.dirs or override_dirs() or M.default_dirs
    statusline.set_namer(M.name)
    vim.api.nvim_create_user_command("Projects", function(o) M.command(o.args) end, {
        nargs = "*",
        complete = M.complete,
        desc = "Projects: select, create, track, untrack or delete",
    })
end

return M
