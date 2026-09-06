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

-- the default tracked set is the documented one
eq("default dir 1", projects.default_dirs[1], "~/Documents")
eq("default dir 2", projects.default_dirs[2], "~/Projects")
eq("default dir 3", projects.default_dirs[3], "~/Personal")
eq("default dir count", #projects.default_dirs, 3)

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

vim.fn.delete(tmp, "rf")

if failures > 0 then
    print("FAILURES: " .. failures)
    os.exit(1)
end
print("ALL PROJECTS TESTS PASSED")
