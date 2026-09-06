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

-- the default tracked set is the documented one, named relative to home
eq("default dir 1", projects.default_dirs[1], "Documents")
eq("default dir 2", projects.default_dirs[2], "Projects")
eq("default dir 3", projects.default_dirs[3], "Personal")
eq("default dir count", #projects.default_dirs, 3)

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
    if item.label == "Missing" then
        failures = failures + 1
        print("FAIL missing tracked dir must be skipped")
    end
end

-- grouped in configured order, sorted within a group, labelled by basename
eq("first item", items[1].name, "beta")
eq("last item", items[#items].name, "blinky")
eq("label shortened", items[1].label, "Alpha")
eq("trailing slash label", find(items, "blinky").label, "Embedded")

-- label padded to the widest label, two spaces before the name
eq("display column", items[1].display, "Alpha     beta")
eq("display widest label", find(items, "blinky").display, "Embedded  blinky")
eq("path", vim.fs.normalize(items[1].path), vim.fs.normalize(tmp .. "/Alpha/beta"))

-- the picker matches against .display: name, label, and combined queries hit
eq("fuzzy by name", fuzzy.filter(items, "blinky")[1].name, "blinky")
eq("fuzzy by name 2", fuzzy.filter(items, "beta")[1].name, "beta")
eq("fuzzy by label", fuzzy.filter(items, "embedded")[1].name, "blinky")
eq("fuzzy label+name", fuzzy.filter(items, "alp zet")[1].name, "zeta")
local by_label = fuzzy.filter(items, "alpha")
eq("fuzzy label group count", #by_label, link_ok and 3 or 2)
for _, item in ipairs(by_label) do
    eq("fuzzy label group is Alpha (" .. item.name .. ")", item.label, "Alpha")
end

-- setup{dirs} replaces the tracked set outright
projects.setup({ dirs = { tmp .. "/Embedded" } })
items = projects.items()
eq("override count", #items, 1)
eq("override display", items[1].display, "Embedded  blinky")

-- the projects section of overrides.lua supplies the set when setup() gets
-- no dirs, and an explicit setup{dirs} still wins over it
package.loaded["neo.overrides"] = { projects = { dirs = { tmp .. "/Embedded" } } }
projects.setup({})
items = projects.items()
eq("overrides.lua count", #items, 1)
eq("overrides.lua item", items[1].name, "blinky")
projects.setup({ dirs = { tmp .. "/Alpha" } })
eq("setup dirs beat overrides.lua", projects.items()[1].label, "Alpha")

-- an empty or missing dirs list in overrides.lua means "use the defaults"
-- (default_dirs is patched to the fixture so the fallback is observable)
local saved_defaults = projects.default_dirs
projects.default_dirs = { tmp .. "/Embedded" }
package.loaded["neo.overrides"] = { projects = { dirs = {} } }
projects.setup({})
eq("empty overrides dirs fall back", projects.items()[1].name, "blinky")
package.loaded["neo.overrides"] = { graphical = { font_size = 18 } }
projects.setup({})
eq("no projects section falls back", projects.items()[1].name, "blinky")
projects.default_dirs = saved_defaults

-- open() refuses politely instead of showing an empty picker
local notified
local saved_notify = vim.notify
vim.notify = function(msg) notified = msg end
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

vim.fn.delete(tmp, "rf")

if failures > 0 then
    print("FAILURES: " .. failures)
    os.exit(1)
end
print("ALL PROJECTS TESTS PASSED")
