-- lua/neo/plugins/projects/test.lua
-- Run from anywhere: nvim -l path/to/plugins/projects/test.lua
-- Standalone: neo.* requires resolve relative to this file, so no rtp setup
-- is needed and an installed copy of the config never shadows this checkout.
local here = debug.getinfo(1, "S").source:sub(2):match("(.*)[/\\]")
local root = here .. "/../.."

table.insert(package.loaders or package.searchers, 2, function(name)
    local rel = name:match("^neo%.(.+)$")
    if not rel then return end
    local base = root .. "/" .. rel:gsub("%.", "/")
    for _, cand in ipairs({ base .. ".lua", base .. "/init.lua" }) do
        local f = io.open(cand, "r")
        if f then
            f:close()
            return function() return dofile(cand) end
        end
    end
end)

local projects = require("neo.plugins.projects")
local fuzzy = require("neo.plugins.picker.fuzzy")

local failures = 0
local function eq(desc, got, want)
    if got ~= want then
        failures = failures + 1
        print(("FAIL %s: got=%s want=%s"):format(desc, vim.inspect(got), vim.inspect(want)))
    else
        print("ok   " .. desc)
    end
end

local function find(items, name)
    for _, item in ipairs(items) do
        if item.name == name then return item end
    end
end

local notified
local saved_notify = vim.notify

-- the default tracked set: home-relative Projects plus the platform's own
-- Neovim config dir as a single pinned project
eq("default dir 1", projects.default_dirs[1], "Projects")
eq("default nvim config path", projects.default_dirs[2][1],
    vim.fs.joinpath(vim.fn.stdpath("config"), "lua/neo"))
eq("default nvim config single", projects.default_dirs[2].single, true)
eq("default nvim config tag", projects.default_dirs[2].tag, "Neovim")
eq("default nvim config name", projects.default_dirs[2].name, "Config")
eq("default dir count", #projects.default_dirs, 2)

-- resolve: no prefix means home-relative; ~, /, \\ and drive paths pass
-- through (backslash and drive forms only flip separators on Windows, so
-- assert prefixes rather than exact strings for those)
local home = vim.fs.normalize(vim.uv.os_homedir())
eq("resolve bare name", projects.resolve("Documents"), home .. "/Documents")
eq("resolve nested relative", projects.resolve("Uni/CS"), home .. "/Uni/CS")
eq("resolve tilde", projects.resolve("~/Projects"), home .. "/Projects")
eq("resolve unix absolute", projects.resolve("/opt/src"), "/opt/src")
eq("resolve drive", projects.resolve("C:/repos"), "C:/repos")
eq("resolve drive backslash", projects.resolve([[C:\repos]]):match("^C:") ~= nil, true)
eq("resolve unc", projects.resolve([[\\server\share]]):match("^[/\\]") ~= nil, true)

-- fixture tree: two tracked dirs (one via trailing slash), one missing
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/Alpha/zeta", "p")
vim.fn.mkdir(tmp .. "/Alpha/beta", "p")
vim.fn.mkdir(tmp .. "/Alpha/.hidden", "p")
io.open(tmp .. "/Alpha/notes.txt", "w"):close()
vim.fn.mkdir(tmp .. "/Embedded/blinky", "p")
vim.fn.mkdir(tmp .. "/linktarget", "p")
io.open(tmp .. "/notes.md", "w"):close()
local link_ok = vim.uv.fs_symlink(tmp .. "/linktarget", tmp .. "/Alpha/ulink", { dir = true })

projects.setup({ dirs = { tmp .. "/Alpha", tmp .. "/Embedded/", tmp .. "/Missing" } })
local items = projects.items()

eq("item count", #items, link_ok and 4 or 3)
eq("plain files excluded", find(items, "notes.txt"), nil)
eq("hidden dirs excluded", find(items, ".hidden"), nil)
if link_ok then
    eq("dir symlink included", find(items, "ulink") ~= nil, true)
else
    print("skip dir symlink included (fs_symlink unavailable)")
end
for _, item in ipairs(items) do
    if item.tag == "Missing" then
        failures = failures + 1
        print("FAIL missing tracked dir must be skipped")
    end
end

-- grouped in configured order, sorted within a group, tagged by basename
eq("first item", items[1].name, "beta")
eq("last item", items[#items].name, "blinky")
eq("tag shortened", items[1].tag, "Alpha")
eq("trailing slash tag", find(items, "blinky").tag, "Embedded")

-- tag padded to the widest tag, two spaces before the name
eq("display column", items[1].display, "Alpha     beta")
eq("display widest tag", find(items, "blinky").display, "Embedded  blinky")
eq("path", vim.fs.normalize(items[1].path), vim.fs.normalize(tmp .. "/Alpha/beta"))

-- the picker matches against .display: name, tag, and combined queries hit
eq("fuzzy by name", fuzzy.filter(items, "blinky")[1].name, "blinky")
eq("fuzzy by name 2", fuzzy.filter(items, "beta")[1].name, "beta")
eq("fuzzy by tag", fuzzy.filter(items, "embedded")[1].name, "blinky")
eq("fuzzy tag+name", fuzzy.filter(items, "alp zet")[1].name, "zeta")
local by_tag = fuzzy.filter(items, "alpha")
eq("fuzzy tag group count", #by_tag, link_ok and 3 or 2)
for _, item in ipairs(by_tag) do
    eq("fuzzy tag group is Alpha (" .. item.name .. ")", item.tag, "Alpha")
end

-- table entries: tagged scans, single-directory and single-file projects;
-- wrong-type and missing paths are skipped, malformed entries are reported
local tmp_tag = vim.fs.basename(vim.fs.normalize(tmp))
notified = nil
vim.notify = function(msg) notified = msg end
projects.setup({ dirs = {
    { tmp .. "/Alpha", tag = "Work" },
    { tmp .. "/linktarget", single = true },
    { tmp .. "/Embedded/blinky", single = true, tag = "Pinned" },
    { tmp .. "/Alpha/.hidden", single = true },
    { tmp .. "/notes.md", file = true },
    { tmp .. "/Missing", single = true },
    { tmp .. "/missing.md", file = true },
    { tmp .. "/Alpha", file = true },
    { tmp .. "/notes.md", single = true },
    { single = true },
} })
items = projects.items()
vim.notify = saved_notify
eq("mixed count", #items, (link_ok and 3 or 2) + 4)
eq("tagged scan", find(items, "beta").tag, "Work")
eq("fuzzy by scan tag", find(fuzzy.filter(items, "work"), "beta") ~= nil, true)
eq("single default tag", find(items, "linktarget").tag, tmp_tag)
eq("single explicit tag", find(items, "blinky").tag, "Pinned")
eq("single display", find(items, "blinky").display:match("^Pinned%s+blinky$") ~= nil, true)
eq("single path", vim.fs.normalize(find(items, "blinky").path),
    vim.fs.normalize(tmp .. "/Embedded/blinky"))
eq("single dir is not a file item", find(items, "blinky").file, nil)
eq("explicit hidden single included", find(items, ".hidden") ~= nil, true)
eq("file item flagged", find(items, "notes.md").file, true)
eq("file default tag", find(items, "notes.md").tag, tmp_tag)
eq("missing single skipped", find(items, "Missing"), nil)
eq("malformed entry reported", notified ~= nil and notified:find("malformed") ~= nil, true)

-- name renames a single/file project's display; scans ignore it (their
-- projects name themselves after their directories)
projects.setup({ dirs = {
    { tmp .. "/Embedded/blinky", single = true, tag = "Pinned", name = "Blinky!" },
    { tmp .. "/notes.md", file = true, name = "Notes" },
    { tmp .. "/Alpha", name = "Ignored" },
} })
items = projects.items()
eq("rename block count", #items, (link_ok and 3 or 2) + 2)
eq("renamed single", find(items, "Blinky!") ~= nil, true)
eq("renamed single path", vim.fs.normalize(find(items, "Blinky!").path),
    vim.fs.normalize(tmp .. "/Embedded/blinky"))
eq("renamed single display", find(items, "Blinky!").display:match("^Pinned%s+Blinky!$") ~= nil, true)
eq("renamed file", find(items, "Notes").file, true)
eq("scan keeps own names", find(items, "beta") ~= nil, true)
eq("scan name ignored", find(items, "Ignored"), nil)
eq("fuzzy matches renamed", fuzzy.filter(items, "blinky!")[1].name, "Blinky!")

-- setup{dirs} replaces the tracked set outright
projects.setup({ dirs = { tmp .. "/Embedded" } })
items = projects.items()
eq("override count", #items, 1)
eq("override display", items[1].display, "Embedded  blinky")

-- the projects section of overrides.lua supplies extra dirs when setup()
-- gets none: by default they append to M.default_dirs, and an explicit
-- setup{dirs} still wins over both (default_dirs is patched to the
-- fixture so the merge is observable)
local saved_defaults = projects.default_dirs
projects.default_dirs = { tmp .. "/Alpha" }
package.loaded["neo.overrides"] = { projects = { dirs = {
    { tmp .. "/Embedded/blinky", single = true, tag = "Pinned" },
} } }
projects.setup({})
items = projects.items()
eq("overrides.lua merge count", #items, (link_ok and 3 or 2) + 1)
eq("overrides.lua defaults first", items[1].name, "beta")
eq("overrides.lua dirs appended last", items[#items].tag, "Pinned")
eq("merge leaves default_dirs alone", #projects.default_dirs, 1)
projects.setup({ dirs = { tmp .. "/Embedded" } })
items = projects.items()
eq("setup dirs beat overrides.lua and defaults", #items, 1)
eq("setup dirs item", items[1].name, "blinky")

-- re-listing a default's path in overrides.lua doesn't duplicate its
-- projects: the default is dropped and the overrides entry's options win
projects.default_dirs = { tmp .. "/Alpha", tmp .. "/Embedded" }
package.loaded["neo.overrides"] = { projects = { dirs = {
    { tmp .. "/Embedded", tag = "Firmware" },
} } }
projects.setup({})
items = projects.items()
eq("shadowed default not duplicated", #items, (link_ok and 3 or 2) + 1)
eq("shadowing entry options win", find(items, "blinky").tag, "Firmware")
eq("unshadowed defaults kept", find(items, "beta") ~= nil, true)
eq("shadowing entry takes the overrides slot", items[#items].name, "blinky")

-- an empty or missing dirs list in overrides.lua means "use the defaults"
projects.default_dirs = { tmp .. "/Embedded" }
package.loaded["neo.overrides"] = { projects = { dirs = {} } }
projects.setup({})
eq("empty overrides dirs fall back", projects.items()[1].name, "blinky")
package.loaded["neo.overrides"] = { graphical = { font_size = 18 } }
projects.setup({})
eq("no projects section falls back", projects.items()[1].name, "blinky")

-- overwrite_defaults = false matches the unset default (append, above);
-- only overwrite_defaults = true replaces the defaults
projects.default_dirs = { tmp .. "/Alpha" }
package.loaded["neo.overrides"] = { projects = {
    dirs = { { tmp .. "/Embedded/blinky", single = true, tag = "Pinned" } },
    overwrite_defaults = false,
} }
projects.setup({})
items = projects.items()
eq("explicit append count", #items, (link_ok and 3 or 2) + 1)
eq("explicit append defaults first", items[1].name, "beta")
eq("explicit append appended last", items[#items].tag, "Pinned")
package.loaded["neo.overrides"] = { projects = {
    dirs = { tmp .. "/Embedded" },
    overwrite_defaults = true,
} }
projects.setup({})
eq("explicit overwrite replaces", #projects.items(), 1)
projects.default_dirs = saved_defaults

-- open() refuses politely instead of showing an empty picker
vim.notify = function(msg) notified = msg end
notified = nil
projects.setup({ dirs = { tmp .. "/Missing" } })
eq("open with no tracked dirs", projects.open(), nil)
eq("no tracked dirs warns", notified ~= nil and notified:find("no tracked") ~= nil, true)
notified = nil
projects.setup({ dirs = { tmp .. "/linktarget" } })
eq("open with no projects", projects.open(), nil)
eq("no projects warns", notified ~= nil and notified:find("no projects") ~= nil, true)
vim.notify = saved_notify

-- a broken overrides.lua is reported, not silently swallowed
package.loaded["neo.overrides"] = nil
local searchers = package.loaders or package.searchers
table.insert(searchers, 1, function(name)
    if name == "neo.overrides" then
        return function() error("boom") end
    end
end)
notified = nil
vim.notify = function(msg) notified = msg end
projects.setup({})
vim.notify = saved_notify
table.remove(searchers, 1)
package.loaded["neo.overrides"] = nil
eq("broken overrides.lua reported", notified ~= nil and notified:find("boom") ~= nil, true)

-- switch() kills every open buffer (saving the file-backed modified ones),
-- collapses tabs and windows, cds, and lands in netrw on the project root.
-- nvim -l skips plugin files, so pull netrw in by hand first.
vim.cmd("runtime! plugin/netrwPlugin.vim")
local orig_cwd = vim.fn.getcwd()
local function norm_dir(path)
    -- realpath: macOS tempdirs live behind a /var -> /private/var symlink,
    -- and :cd reports the resolved form
    path = vim.uv.fs_realpath(path) or path
    return (vim.fs.normalize(path):gsub("/+$", ""))
end

local dirty_file = tmp .. "/Alpha/dirty.txt"
vim.cmd("edit " .. vim.fn.fnameescape(dirty_file))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "saved on switch" })
local dirty_buf = vim.api.nvim_get_current_buf()
vim.cmd("vsplit " .. vim.fn.fnameescape(tmp .. "/Alpha/notes.txt"))
local clean_buf = vim.api.nvim_get_current_buf()
vim.cmd("tabnew")
local scratch_buf = vim.api.nvim_create_buf(true, true)
vim.api.nvim_buf_set_lines(scratch_buf, 0, -1, false, { "scratch junk" })
vim.api.nvim_set_current_buf(scratch_buf)
vim.cmd("terminal")
local term_buf = vim.api.nvim_get_current_buf()
vim.cmd("enew")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unnamed junk" })
local unnamed_buf = vim.api.nvim_get_current_buf()

vim.notify = function() end
projects.switch(tmp .. "/Embedded/blinky")
vim.notify = saved_notify

eq("switch cwd", norm_dir(vim.fn.getcwd()), norm_dir(tmp .. "/Embedded/blinky"))
eq("switch one tab", vim.fn.tabpagenr("$"), 1)
eq("switch one window", #vim.api.nvim_list_wins(), 1)
eq("switch killed saved buffer", vim.api.nvim_buf_is_valid(dirty_buf), false)
eq("switch killed clean buffer", vim.api.nvim_buf_is_valid(clean_buf), false)
eq("switch killed scratch buffer", vim.api.nvim_buf_is_valid(scratch_buf), false)
eq("switch killed terminal buffer", vim.api.nvim_buf_is_valid(term_buf), false)
eq("switch killed unnamed buffer", vim.api.nvim_buf_is_valid(unnamed_buf), false)
local written = io.open(dirty_file, "r")
eq("switch saved modified file", written and written:read("*l"), "saved on switch")
if written then written:close() end
eq("switch lands in netrw", vim.bo.filetype, "netrw")
eq("switch netrw shows project root",
    norm_dir(vim.api.nvim_buf_get_name(0)), norm_dir(tmp .. "/Embedded/blinky"))

-- a modified buffer whose write fails survives the sweep with its changes
-- (and a complaint) while the rest of the switch still happens
vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/gone/nested/file.txt"))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unwritable" })
local kept_buf = vim.api.nvim_get_current_buf()
notified = ""
vim.notify = function(msg) notified = notified .. "\n" .. msg end
projects.switch(tmp .. "/Alpha")
vim.notify = saved_notify
eq("failed save keeps buffer", vim.api.nvim_buf_is_valid(kept_buf), true)
eq("failed save keeps changes", vim.bo[kept_buf].modified, true)
eq("failed save reported", notified:find("save failed", 1, true) ~= nil, true)
eq("failed save still cds", norm_dir(vim.fn.getcwd()), norm_dir(tmp .. "/Alpha"))
eq("failed save still lands in netrw", vim.bo.filetype, "netrw")

-- switching to a missing directory refuses before killing anything
vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/Alpha/notes.txt"))
local survivor_buf = vim.api.nvim_get_current_buf()
notified = ""
vim.notify = function(msg) notified = notified .. "\n" .. msg end
projects.switch(tmp .. "/Missing")
vim.notify = saved_notify
eq("missing dir warns", notified:find("not a directory", 1, true) ~= nil, true)
eq("missing dir keeps buffers", vim.api.nvim_buf_is_valid(survivor_buf), true)
eq("missing dir keeps cwd", norm_dir(vim.fn.getcwd()), norm_dir(tmp .. "/Alpha"))

vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
vim.fn.delete(tmp, "rf")

if failures > 0 then
    print("FAILURES: " .. failures)
    os.exit(1)
end
print("ALL PROJECTS TESTS PASSED")
