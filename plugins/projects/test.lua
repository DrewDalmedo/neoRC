-- lua/neo/plugins/projects/test.lua
-- Run from anywhere: nvim -l path/to/plugins/projects/test.lua
-- Standalone: neo.* requires resolve relative to this file, so no rtp setup
-- is needed and an installed copy of the config never shadows this checkout.
-- What tracking saves goes to a temporary file, never to your own.
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
local store = require("neo.plugins.projects.store")
local picker = require("neo.plugins.picker")
local fuzzy = require("neo.plugins.picker.fuzzy")

store.file = vim.fs.joinpath(vim.fn.tempname(), "projects.json")

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

-- name(): the name the picker lists the project at a directory by, which
-- setup() hands to the picker's statusline ("Blinky!: main.c")
eq("name of a renamed single", projects.name(tmp .. "/Embedded/blinky"), "Blinky!")
eq("name of a scanned project", projects.name(tmp .. "/Alpha/beta"), "beta")
eq("name with a trailing slash", projects.name(tmp .. "/Alpha/beta/"), "beta")
eq("untracked dir has no name", projects.name(tmp .. "/Embedded"), nil)
eq("file entry is no project dir", projects.name(tmp .. "/notes.md"), nil)
eq("missing dir has no name", projects.name(tmp .. "/Missing"), nil)
if link_ok then
    -- linked into a scanned dir: the link's name, whichever path is asked
    eq("name through a symlink", projects.name(tmp .. "/linktarget"), "ulink")
else
    print("skip name through a symlink (fs_symlink unavailable)")
end
local statusline = require("neo.plugins.picker.statusline")
eq("statusline names tracked projects", statusline.project(tmp .. "/Embedded/blinky"), "Blinky!")
eq("statusline names the rest by basename", statusline.project(tmp .. "/Embedded"), "Embedded")
local cwd_before = vim.fn.getcwd()
vim.cmd("cd " .. vim.fn.fnameescape(tmp .. "/Embedded/blinky"))
vim.cmd("edit main.c")
eq("statusline label in a named project", statusline.label(), "Blinky!: main.c")
vim.cmd("bwipeout")
vim.cmd("cd " .. vim.fn.fnameescape(cwd_before))

-- the statusline asks name() as it draws: malformed entries are skipped
-- without a word there (open() and items() still complain)
notified = nil
vim.notify = function(msg) notified = msg end
projects.setup({ dirs = { { single = true }, tmp .. "/Alpha" } })
eq("name past a malformed entry", projects.name(tmp .. "/Alpha/beta"), "beta")
eq("name doesn't notify", notified, nil)
vim.notify = saved_notify

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

-- open() shows the picker even with nothing to list, so its keys for
-- tracking directories and making projects are always within reach
projects.setup({ dirs = { tmp .. "/Missing" } })
local p = projects.open()
eq("open with no tracked dirs", p ~= nil and p:count(), 0)
p:close()
projects.setup({ dirs = { tmp .. "/linktarget" } })
p = projects.open()
eq("open with no projects", p ~= nil and p:count(), 0)
p:close()

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

-- Tracking, untracking and making projects. The prompts (vim.ui.input) and
-- switch() are stubbed so nothing waits for input or kills this test's
-- buffers; pickers are driven through their controllers.
local function n(path) return vim.fs.normalize(path) end
local function reset_store() os.remove(store.file) end
local function drain()
    local done = false
    vim.schedule(function() done = true end)
    vim.wait(1000, function() return done end, 5)
end
local notes = {}
local function capture()
    notes = {}
    vim.notify = function(msg) notes[#notes + 1] = msg end
end
local function noted(text)
    for _, msg in ipairs(notes) do
        if msg:find(text, 1, true) then return true end
    end
    return false
end
local function count(list, name)
    local c = 0
    for _, item in ipairs(list) do
        if item.name == name then c = c + 1 end
    end
    return c
end

-- the store: a missing file reads as empty; a broken one is moved aside
reset_store()
eq("store starts empty", #store.read().dirs + #store.read().untracked, 0)
vim.fn.mkdir(vim.fs.dirname(store.file), "p")
local f = io.open(store.file, "w")
f:write("{not json")
f:close()
-- the statusline reads quietly: no notice, and the file is left in place
capture()
eq("broken store reads empty quietly", #store.read(true).dirs, 0)
vim.notify = saved_notify
eq("quiet read says nothing", #notes, 0)
eq("quiet read leaves the file", vim.uv.fs_stat(store.file) ~= nil, true)
projects.setup({ dirs = { tmp .. "/Alpha" } })
eq("name() reads quietly", projects.name(tmp .. "/Alpha/beta"), "beta")
eq("name() leaves the broken file", vim.uv.fs_stat(store.file .. ".bad"), nil)
capture()
eq("broken store reads empty", #store.read().dirs, 0)
vim.notify = saved_notify
eq("broken store reported", noted("isn't valid"), true)
eq("broken store moved aside", vim.uv.fs_stat(store.file .. ".bad") ~= nil, true)
os.remove(store.file .. ".bad")
eq("store round trip", store.write({ dirs = { "/a" }, untracked = { "/b" } }), true)
eq("store round trip dirs", store.read().dirs[1], "/a")
eq("store round trip untracked", store.read().untracked[1], "/b")
reset_store()

local configured_set = {
    { tmp .. "/Alpha", tag = "Work" },
    { tmp .. "/Embedded/blinky", single = true, tag = "Pinned" },
    { tmp .. "/notes.md", file = true },
}
projects.setup({ dirs = configured_set })

-- track: a missing directory is created and saved, and its projects are
-- listed after the configured ones
local path, created = projects.track(tmp .. "/Fresh")
eq("track returns the path", path, n(tmp .. "/Fresh"))
eq("track says it created it", created, true)
eq("track made the dir", vim.fn.isdirectory(tmp .. "/Fresh"), 1)
eq("track saved it", store.read().dirs[1], n(tmp .. "/Fresh"))
vim.fn.mkdir(tmp .. "/Fresh/one", "p")
items = projects.items()
eq("tracked dir's projects listed", find(items, "one") and find(items, "one").tag, "Fresh")
eq("tracked dir comes after the configured ones", items[#items].name, "one")
eq("configured ones stay first", items[1].tag, "Work")

-- it outlives setup() (a new session): it's read back from disk
projects.setup({ dirs = configured_set })
eq("tracked dir survives setup", find(projects.items(), "one") ~= nil, true)

-- an existing directory is tracked as it is
vim.fn.mkdir(tmp .. "/Firmware/led", "p")
path, created = projects.track(tmp .. "/Firmware/")
eq("track existing", path, n(tmp .. "/Firmware"))
eq("track existing not created", created, false)
eq("track existing lists projects", find(projects.items(), "led").tag, "Firmware")

-- refusals: tracked already (configured or saved), or not a directory
local _, err = projects.track(tmp .. "/Alpha")
eq("track configured refused", err and err:find("already tracked") ~= nil, true)
_, err = projects.track(tmp .. "/Firmware")
eq("track saved refused", err and err:find("already tracked") ~= nil, true)
_, err = projects.track(tmp .. "/notes.md")
eq("track file refused", err and err:find("not a directory") ~= nil, true)
eq("refusals save nothing", #store.read().dirs, 2)

-- untrack: a saved dir is forgotten, a configured entry of any kind is
-- left out from now on; nothing on disk is touched
eq("untrack saved", projects.untrack(tmp .. "/Firmware"), true)
eq("untrack saved forgets it", store.has(store.read().dirs, n(tmp .. "/Firmware")), false)
eq("untracked saved dir unlisted", find(projects.items(), "led"), nil)
eq("untrack leaves the dir", vim.fn.isdirectory(tmp .. "/Firmware/led"), 1)
eq("untrack configured scan", projects.untrack(tmp .. "/Alpha"), true)
eq("untrack configured remembered", store.read().untracked[1], n(tmp .. "/Alpha"))
eq("untracked configured scan unlisted", find(projects.items(), "beta"), nil)
eq("untrack single", projects.untrack(tmp .. "/Embedded/blinky"), true)
eq("untracked single unlisted", find(projects.items(), "blinky"), nil)
eq("untrack file", projects.untrack(tmp .. "/notes.md"), true)
eq("untracked file unlisted", find(projects.items(), "notes.md"), nil)
eq("untrack leaves the file", vim.fn.filereadable(tmp .. "/notes.md"), 1)
_, err = projects.untrack(tmp .. "/Alpha")
eq("untrack twice refused", err and err:find("not tracked") ~= nil, true)
_, err = projects.untrack(tmp .. "/Nowhere")
eq("untrack unknown refused", err and err:find("not tracked") ~= nil, true)
eq("untrack twice not doubled", #store.read().untracked, 3)
projects.setup({ dirs = configured_set })
eq("untracking survives setup", find(projects.items(), "beta"), nil)

-- tracking an untracked configured entry brings it back as configured
path, created = projects.track(tmp .. "/Alpha")
eq("retrack configured", path, n(tmp .. "/Alpha"))
eq("retrack configured not created", created, false)
eq("retrack keeps configured options", find(projects.items(), "beta").tag, "Work")
eq("retrack isn't saved as a dir", store.has(store.read().dirs, path), false)
eq("retrack forgets the untracking", store.has(store.read().untracked, path), false)
eq("retrack single", projects.track(tmp .. "/Embedded/blinky"), n(tmp .. "/Embedded/blinky"))
eq("retracked single keeps its tag", find(projects.items(), "blinky").tag, "Pinned")
eq("retrack file", projects.track(tmp .. "/notes.md"), n(tmp .. "/notes.md"))
eq("retracked file is a file again", find(projects.items(), "notes.md").file, true)

-- the statusline's remembered project names follow tracking: an
-- untracked renamed project goes back to its basename, and back again
local statusline_mod = require("neo.plugins.picker.statusline")
projects.setup({ dirs = configured_set })
eq("statusline name before untrack", statusline_mod.project(tmp .. "/Embedded/blinky"), "blinky")
projects.setup({ dirs = { { tmp .. "/Embedded/blinky", single = true, name = "Blinky!" } } })
eq("statusline uses the configured name", statusline_mod.project(tmp .. "/Embedded/blinky"), "Blinky!")
projects.untrack(tmp .. "/Embedded/blinky")
eq("statusline forgets an untracked name", statusline_mod.project(tmp .. "/Embedded/blinky"), "blinky")
projects.track(tmp .. "/Embedded/blinky")
eq("statusline picks a retracked name up", statusline_mod.project(tmp .. "/Embedded/blinky"), "Blinky!")

-- a saved dir the configured set lists too shows once, and untracking it
-- covers both
projects.setup({ dirs = { tmp .. "/Alpha", tmp .. "/Fresh" } })
eq("saved and configured listed once", count(projects.items(), "one"), 1)
projects.untrack(tmp .. "/Fresh")
eq("untrack both forgets the saved one", store.has(store.read().dirs, n(tmp .. "/Fresh")), false)
eq("untrack both leaves out the configured one", store.has(store.read().untracked, n(tmp .. "/Fresh")), true)
eq("untrack both unlisted", find(projects.items(), "one"), nil)

-- create_project: one directory, named sensibly, that doesn't exist yet
reset_store()
projects.setup({ dirs = { tmp .. "/Alpha" } })
local made
made, err = projects.create_project(tmp .. "/Alpha", "  gamma  ")
eq("create trims the name", made and n(made), n(tmp .. "/Alpha/gamma"))
eq("create made the dir", vim.fn.isdirectory(tmp .. "/Alpha/gamma"), 1)
eq("created project listed", find(projects.items(), "gamma") ~= nil, true)
for _, case in ipairs({
    { "", "needs a name" }, { "   ", "needs a name" },
    { "a/b", "can't contain" }, { [[a\b]], "can't contain" },
    { ".dotted", "dot" }, { "..", "dot" },
    { "beta", "already exists" }, { "notes.txt", "already exists" },
}) do
    made, err = projects.create_project(tmp .. "/Alpha", case[1])
    eq("create refuses " .. vim.inspect(case[1]),
        made == nil and err ~= nil and err:find(case[2], 1, true) ~= nil, true)
end
eq("refused names made nothing", vim.fn.isdirectory(tmp .. "/Alpha/a"), 0)
made, err = projects.create_project(tmp .. "/Nowhere", "x")
eq("create in a missing parent refused", err and err:find("not a directory") ~= nil, true)
eq("missing parent not created", vim.fn.isdirectory(tmp .. "/Nowhere"), 0)

-- stubs for the interactive flows
local saved_switch, saved_input = projects.switch, vim.ui.input
local switched, prompts, answers
projects.switch = function(dir) switched = n(dir) end
vim.ui.input = function(opts, on_confirm)
    prompts[#prompts + 1] = opts
    on_confirm(table.remove(answers, 1))
end
local function interact(list)
    switched, prompts, answers = nil, {}, list
end
-- yes/no questions: recorded, answered with confirm_answer (2 is No)
local questions, confirm_answer = {}, 2
vim.fn.confirm = function(msg, _, default)
    questions[#questions + 1] = { msg = msg, default = default }
    return confirm_answer
end
local function last_question() return questions[#questions] and questions[#questions].msg or "" end

-- new_project with one directory that can hold projects: no chooser,
-- straight to the name, then into the new project
projects.setup({ dirs = { tmp .. "/Alpha", { tmp .. "/Embedded/blinky", single = true } } })
interact({ "delta" })
projects.new_project({ default = "del" })
eq("new asks once", #prompts, 1)
eq("new prompt names the dir", prompts[1].prompt:find(vim.fn.fnamemodify(tmp .. "/Alpha", ":~"), 1, true) ~= nil, true)
eq("new prompt pre-filled", prompts[1].default, "del")
eq("new made it", vim.fn.isdirectory(tmp .. "/Alpha/delta"), 1)
eq("new switched into it", switched, n(tmp .. "/Alpha/delta"))

-- cancelling makes nothing; a bad name is reported and goes nowhere
interact({})
projects.new_project({})
eq("cancelled name switches nowhere", switched, nil)
interact({ "   " })
projects.new_project({})
eq("blank name switches nowhere", switched, nil)
interact({ "beta" })
capture()
projects.new_project({})
vim.notify = saved_notify
eq("bad name reported", noted("already exists"), true)
eq("bad name switches nowhere", switched, nil)

-- a name given up front skips the prompt
interact({})
projects.new_project({ name = "epsilon" })
eq("given name not asked for", #prompts, 0)
eq("given name made", switched, n(tmp .. "/Alpha/epsilon"))

-- several directories that can hold projects: a chooser (of those that
-- exist), with the one asked for first
projects.setup({ dirs = { tmp .. "/Alpha", tmp .. "/Embedded", tmp .. "/Missing" } })
interact({ "zap" })
p = projects.new_project({ near = { path = n(tmp .. "/Embedded") } })
eq("chooser opens", p ~= nil and picker.current() == p, true)
eq("chooser lists existing scanned dirs", p:count(), 2)
eq("chooser offers near first", p:selection().entry.path, n(tmp .. "/Embedded"))
p:choose()
drain()
eq("chooser then name", vim.fn.isdirectory(tmp .. "/Embedded/zap"), 1)
eq("chooser then switch", switched, n(tmp .. "/Embedded/zap"))

-- nowhere to make one: a warning
projects.setup({ dirs = { { tmp .. "/linktarget", single = true } } })
capture()
eq("new with no scanned dir", projects.new_project({}), nil)
vim.notify = saved_notify
eq("new with no scanned dir warns", noted("no tracked directory"), true)

-- track_prompt asks from ~/ with directory completion; a directory with
-- no projects goes on to naming its first one
projects.setup({ dirs = { tmp .. "/Alpha" } })
local back = 0
local function go_back() back = back + 1 end
interact({ tmp .. "/Brand", "first" })
capture()
projects.track_prompt({ back = go_back })
vim.notify = saved_notify
eq("track prompt", prompts[1].prompt, "Track directory: ")
eq("track prompt starts at home", prompts[1].default, "~/")
eq("track prompt completes dirs", (prompts[1].completion or ""):find("complete_dir", 1, true) ~= nil, true)
eq("track prompt reports", noted("tracking"), true)
eq("empty tracked dir asks for a first project", prompts[2] and prompts[2].prompt:find("New project in", 1, true) ~= nil, true)
eq("first project made", switched, n(tmp .. "/Brand/first"))
eq("first project instead of back", back, 0)

-- Esc on that name leaves the new directory tracked, and empty
interact({ tmp .. "/Hollow" })
capture()
projects.track_prompt({ back = go_back })
vim.notify = saved_notify
eq("skipped first project still tracked", store.has(store.read().dirs, n(tmp .. "/Hollow")), true)
eq("skipped first project switches nowhere", switched, nil)

-- a directory with projects in it goes back (to the picker) instead
interact({})
capture()
projects.track_prompt({ path = tmp .. "/Firmware", back = go_back })
vim.notify = saved_notify
eq("track by path asks nothing", #prompts, 0)
eq("track with projects goes back", back, 1)
eq("tracked by path", find(projects.items(), "led") ~= nil, true)
capture()
projects.track_prompt({ path = tmp .. "/Firmware", back = go_back })
vim.notify = saved_notify
eq("track twice warns", noted("already tracked"), true)
eq("track twice doesn't go back", back, 1)

-- untrack_prompt lists every entry, missing ones marked, kinds noted,
-- the one asked for first
reset_store()
projects.setup({ dirs = { tmp .. "/Alpha", { tmp .. "/notes.md", file = true }, tmp .. "/Missing" } })
back = 0
capture()
p = projects.untrack_prompt({ near = { path = n(tmp .. "/notes.md") }, back = go_back })
eq("untrack chooser lists every entry", p:count(), 3)
eq("untrack chooser offers near first", p:selection().entry.kind, "file")
eq("untrack chooser notes the kind", p:selection().display:find("(file)", 1, true) ~= nil, true)
local missing_marked = false
for _, item in ipairs(p.items) do
    if item.display:find("(missing)", 1, true) then missing_marked = true end
end
eq("untrack chooser marks missing entries", missing_marked, true)
p:choose()
drain()
vim.notify = saved_notify
eq("untrack chooser untracked it", find(projects.items(), "notes.md"), nil)
eq("untrack chooser reports", noted("untracked"), true)
eq("untrack chooser goes back", back, 1)

-- the Projects picker: its keys, and the hint on its border
reset_store()
projects.setup({ dirs = { tmp .. "/Alpha", tmp .. "/Embedded" } })
p = projects.open()
local footer = vim.api.nvim_win_get_config(p.ui.results_win).footer
footer = type(footer) == "table" and footer[1][1] or footer
for _, lhs in ipairs({ "<C-n>", "<C-t>", "<C-x>", "<C-d>" }) do
    eq("picker maps " .. lhs, vim.fn.maparg(lhs, "i", false, true).buffer, 1)
    eq("picker footer shows " .. lhs, footer:find(lhs, 1, true) ~= nil, true)
end

-- <C-n>: what was typed becomes the name's default, and the highlighted
-- project's directory is offered first
vim.api.nvim_buf_set_lines(p.ui.prompt_buf, 0, -1, false, { "blinky" })
p:refresh()
interact({ "omega" })
vim.fn.maparg("<C-n>", "i", false, true).callback()
eq("<C-n> closes the picker", p:valid(), false)
drain()
local chooser = picker.current()
eq("<C-n> offers the highlighted project's dir", chooser and chooser:selection().entry.path, n(tmp .. "/Embedded"))
chooser:choose()
drain()
eq("<C-n> name defaults to the query", prompts[1] and prompts[1].default, "blinky")
eq("<C-n> made and switched", switched, n(tmp .. "/Embedded/omega"))

-- <C-t>: track, then back to the picker
p = projects.open()
interact({ tmp .. "/Firmware" })
capture()
vim.fn.maparg("<C-t>", "i", false, true).callback()
drain()
vim.notify = saved_notify
p = picker.current()
eq("<C-t> reopens the picker", p ~= nil and p:valid(), true)
eq("<C-t> tracked dir listed", p and find(p.items, "led") ~= nil, true)

-- <C-x>: untrack the highlighted project's directory, then back
vim.api.nvim_buf_set_lines(p.ui.prompt_buf, 0, -1, false, { "led" })
p:refresh()
vim.fn.maparg("<C-x>", "i", false, true).callback()
drain()
chooser = picker.current()
eq("<C-x> offers the highlighted project's dir", chooser and chooser:selection().entry.path, n(tmp .. "/Firmware"))
capture()
chooser:choose()
drain()
vim.notify = saved_notify
p = picker.current()
eq("<C-x> reopens the picker", p ~= nil and p:valid(), true)
eq("<C-x> untracked dir unlisted", p and find(p.items, "led"), nil)
p:close()

-- :Projects subcommands and their completion
eq("complete subcommands", table.concat(vim.fn.getcompletion("Projects ", "cmdline"), ","), "new,track,untrack,delete")
eq("complete subcommand prefix", table.concat(vim.fn.getcompletion("Projects un", "cmdline"), ","), "untrack")
eq("complete untrack paths", vim.tbl_contains(vim.fn.getcompletion("Projects untrack ", "cmdline"),
    vim.fn.fnamemodify(n(tmp .. "/Alpha"), ":~")), true)
eq("complete track dirs", vim.tbl_contains(vim.fn.getcompletion("Projects track " .. tmp .. "/Fi", "cmdline"),
    tmp .. "/Firmware/"), true)
if vim.fn.has("win32") == 0 then
    local saved_home = vim.env.HOME
    vim.env.HOME = tmp
    eq("bare names complete from home", vim.tbl_contains(projects.complete_dir("Fi"), "Firmware/"), true)
    vim.env.HOME = saved_home
end
capture()
vim.cmd("Projects track " .. tmp .. "/Firmware")
eq(":Projects track", find(projects.items(), "led") ~= nil, true)
vim.cmd("Projects untrack " .. tmp .. "/Firmware")
eq(":Projects untrack", find(projects.items(), "led"), nil)
interact({})
projects.setup({ dirs = { tmp .. "/Alpha" } })
vim.cmd("Projects new kappa")
eq(":Projects new", switched, n(tmp .. "/Alpha/kappa"))
vim.cmd("Projects bogus")
vim.notify = saved_notify
eq(":Projects unknown subcommand", noted("unknown subcommand"), true)

-- protected(): never the home directory, a root, what holds either, or
-- anything overlapping Neovim's config. HOME and the config dir are
-- pointed into the fixture, so a broken guard could only cost the fixture.
local function real(path) return n(vim.uv.fs_realpath(path) or path) end
local saved_home_env = vim.env.HOME
vim.fn.mkdir(tmp .. "/fakehome/code", "p")
vim.env.HOME = tmp .. "/fakehome"
eq("home is protected", projects.protected(tmp .. "/fakehome") ~= nil, true)
eq("what holds home is protected", projects.protected(tmp) ~= nil, true)
eq("a root is protected", projects.protected("/") ~= nil, true)
eq("inside home is not", projects.protected(tmp .. "/fakehome/code"), nil)
vim.env.HOME = saved_home_env
local real_stdpath = vim.fn.stdpath
local fake_config = tmp .. "/fakecfg"
vim.fn.mkdir(fake_config .. "/lua/neo", "p")
vim.fn.stdpath = function(what)
    if what == "config" then return fake_config end
    return real_stdpath(what)
end
eq("the config is protected", projects.protected(fake_config) ~= nil, true)
eq("inside the config is protected", (projects.protected(fake_config .. "/lua/neo") or ""):find("part of") ~= nil, true)
eq("what holds the config is protected", (projects.protected(tmp) or ""):find("holds") ~= nil, true)
eq("beside the config is not", projects.protected(tmp .. "/Alpha"), nil)
local _, refused = projects.delete(fake_config .. "/lua/neo")
eq("delete refuses the protected", refused and refused:find("won't delete", 1, true) ~= nil, true)
eq("refused delete touches nothing", vim.fn.isdirectory(fake_config .. "/lua/neo"), 1)
vim.fn.stdpath = nil

-- delete(): a directory with everything in it, a file, a link (never
-- what it points to)
vim.fn.mkdir(tmp .. "/Alpha/doomed/sub", "p")
vim.fn.writefile({ "x" }, tmp .. "/Alpha/doomed/sub/f.txt")
eq("delete a directory", projects.delete(tmp .. "/Alpha/doomed"), true)
eq("directory gone", vim.uv.fs_lstat(tmp .. "/Alpha/doomed"), nil)
vim.fn.writefile({ "x" }, tmp .. "/Alpha/loose.txt")
eq("delete a file", projects.delete(tmp .. "/Alpha/loose.txt"), true)
eq("file gone", vim.fn.filereadable(tmp .. "/Alpha/loose.txt"), 0)
vim.fn.writefile({ "keep" }, tmp .. "/linktarget/keep.txt")
if vim.uv.fs_symlink(tmp .. "/linktarget", tmp .. "/Alpha/dlink", { dir = true }) then
    eq("delete a link", projects.delete(tmp .. "/Alpha/dlink"), true)
    eq("link gone", vim.uv.fs_lstat(tmp .. "/Alpha/dlink"), nil)
    eq("what it pointed to kept", vim.fn.filereadable(tmp .. "/linktarget/keep.txt"), 1)
else
    print("skip delete a link (fs_symlink unavailable)")
end
_, err = projects.delete(tmp .. "/Alpha/nothing-here")
eq("delete nothing refused", err and err:find("nothing to delete") ~= nil, true)

-- buffers of files that went are wiped, modified or not; the rest stay;
-- a working directory inside moves to the parent
vim.fn.mkdir(tmp .. "/Alpha/busy", "p")
vim.fn.writefile({ "a" }, tmp .. "/Alpha/busy/a.txt")
local cwd_saved = vim.fn.getcwd()
vim.cmd("cd " .. vim.fn.fnameescape(tmp .. "/Alpha/busy"))
vim.cmd("edit a.txt")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" })
local busy_buf = vim.api.nvim_get_current_buf()
vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/Alpha/notes.txt"))
local kept_buf = vim.api.nvim_get_current_buf()
eq("delete the working directory", projects.delete(tmp .. "/Alpha/busy"), true)
eq("its buffers wiped", vim.api.nvim_buf_is_valid(busy_buf), false)
eq("other buffers kept", vim.api.nvim_buf_is_valid(kept_buf), true)
eq("working directory moved to the parent", real(vim.fn.getcwd()), real(tmp .. "/Alpha"))
vim.cmd("cd " .. vim.fn.fnameescape(cwd_saved))
vim.cmd("silent! %bwipeout!")

-- <C-d> in the picker: the highlighted project, a question that defaults
-- to No, then back to the picker
reset_store()
projects.setup({ dirs = { tmp .. "/Alpha", { tmp .. "/notes.md", file = true } } })
vim.fn.mkdir(tmp .. "/Alpha/victim", "p")
questions, confirm_answer = {}, 2
p = projects.open()
vim.api.nvim_buf_set_lines(p.ui.prompt_buf, 0, -1, false, { "victim" })
p:refresh()
vim.fn.maparg("<C-d>", "i", false, true).callback()
drain()
eq("<C-d> asks", last_question():find("victim and everything in it", 1, true) ~= nil, true)
eq("<C-d> defaults to No", questions[1] and questions[1].default, 2)
eq("No keeps it", vim.fn.isdirectory(tmp .. "/Alpha/victim"), 1)
eq("No stays out of the picker", picker.current(), nil)
confirm_answer = 1
p = projects.open()
vim.api.nvim_buf_set_lines(p.ui.prompt_buf, 0, -1, false, { "victim" })
p:refresh()
capture()
vim.fn.maparg("<C-d>", "i", false, true).callback()
drain()
vim.notify = saved_notify
eq("Yes deletes", vim.fn.isdirectory(tmp .. "/Alpha/victim"), 0)
eq("deleting reports", noted("deleted"), true)
p = picker.current()
eq("deleting goes back to the picker", p ~= nil and p:valid(), true)
eq("deleted project unlisted", p and find(p.items, "victim"), nil)
p:close()

-- with nothing highlighted, <C-d> does nothing
p = projects.open()
vim.api.nvim_buf_set_lines(p.ui.prompt_buf, 0, -1, false, { "zzzqqqxxx" })
p:refresh()
local asked_before = #questions
vim.fn.maparg("<C-d>", "i", false, true).callback()
drain()
eq("<C-d> on nothing keeps the picker", p:valid(), true)
eq("<C-d> on nothing asks nothing", #questions, asked_before)
p:close()

-- :Projects delete <path>: the question names the file of a file entry,
-- and warns about unsaved changes that would go
confirm_answer = 2
vim.cmd("Projects delete " .. vim.fn.fnameescape(tmp .. "/notes.md"))
eq("file entry question", last_question():find("the file", 1, true) ~= nil, true)
eq("file entry kept on No", vim.fn.filereadable(tmp .. "/notes.md"), 1)
vim.fn.mkdir(tmp .. "/Alpha/withbuf", "p")
vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/Alpha/withbuf/x.txt"))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" })
confirm_answer = 1
vim.cmd("Projects delete " .. vim.fn.fnameescape(tmp .. "/Alpha/withbuf"))
eq("question warns about unsaved changes", last_question():find("?\n1 open buffer with unsaved changes would go too.", 1, true) ~= nil, true)
eq(":Projects delete", vim.fn.isdirectory(tmp .. "/Alpha/withbuf"), 0)
vim.cmd("silent! %bwipeout!")
eq("complete delete paths", vim.tbl_contains(vim.fn.getcompletion("Projects delete ", "cmdline"),
    vim.fn.fnamemodify(n(tmp .. "/Alpha/beta"), ":~")), true)

-- only listed projects: a tracked directory itself is refused (untracking
-- offers that), and so is anything protected, without a question
asked_before = #questions
capture()
vim.cmd("Projects delete " .. vim.fn.fnameescape(tmp .. "/Alpha"))
eq("tracked dir isn't a project", noted("not a project"), true)
eq("tracked dir kept", vim.fn.isdirectory(tmp .. "/Alpha"), 1)
vim.fn.stdpath = function(what)
    if what == "config" then return tmp .. "/Alpha/gamma" end
    return real_stdpath(what)
end
projects.delete_prompt({ path = tmp .. "/Alpha/gamma" })
vim.fn.stdpath = nil
vim.notify = saved_notify
eq("protected project refused", noted("won't delete"), true)
eq("refusals ask nothing", #questions, asked_before)
eq("protected project kept", vim.fn.isdirectory(tmp .. "/Alpha/gamma"), 1)

-- untracking then asks whether to delete it too: No leaves it on disk,
-- Yes deletes it; the question counts a tracked directory's projects
reset_store()
projects.setup({ dirs = { tmp .. "/Alpha" } })
vim.fn.mkdir(tmp .. "/Spare/p1", "p")
vim.fn.mkdir(tmp .. "/Spare/p2", "p")
projects.track(tmp .. "/Spare")
confirm_answer = 2
capture()
projects.untrack_prompt({ path = tmp .. "/Spare" })
vim.notify = saved_notify
eq("untrack asks to delete", last_question():find("Untracked", 1, true) ~= nil, true)
eq("untrack question counts projects", last_question():find("(2 projects)", 1, true) ~= nil, true)
eq("untrack No leaves it on disk", vim.fn.isdirectory(tmp .. "/Spare/p1"), 1)
eq("untrack No still untracks", find(projects.items(), "p1"), nil)
eq("untrack No reports", noted("left on disk"), true)
projects.track(tmp .. "/Spare")
confirm_answer = 1
back = 0
capture()
projects.untrack_prompt({ path = tmp .. "/Spare", back = go_back })
vim.notify = saved_notify
eq("untrack Yes deletes", vim.uv.fs_lstat(tmp .. "/Spare"), nil)
eq("untrack Yes reports", noted("untracked and deleted"), true)
eq("untrack Yes goes back", back, 1)

-- nothing to ask about a missing entry or a protected one
projects.setup({ dirs = { tmp .. "/Alpha", tmp .. "/Missing", { fake_config, single = true } } })
asked_before = #questions
capture()
projects.untrack_prompt({ path = tmp .. "/Missing" })
vim.fn.stdpath = function(what)
    if what == "config" then return fake_config end
    return real_stdpath(what)
end
projects.untrack_prompt({ path = fake_config })
vim.fn.stdpath = nil
vim.notify = saved_notify
eq("missing or protected: no question", #questions, asked_before)
eq("protected untracked anyway", find(projects.items(), "fakecfg"), nil)
eq("protected left on disk", vim.fn.isdirectory(fake_config .. "/lua/neo"), 1)
confirm_answer = 2

-- clone_args(): what counts as asking for a clone
local function args_of(text)
    local a, e = projects.clone_args(text)
    return a and table.concat(a, " ") or e and ("ERR " .. e) or nil
end
eq("a plain name isn't a clone", args_of("myproject"), nil)
eq("a name with spaces isn't a clone", args_of("my project"), nil)
eq("https URL", args_of("https://example.com/a/b.git"), "https://example.com/a/b.git")
eq("scp-like URL", args_of("git@github.com:a/b.git"), "git@github.com:a/b.git")
eq("ssh URL", args_of("ssh://git@host/a/b"), "ssh://git@host/a/b")
eq("URL and a name", args_of("  https://example.com/a/b.git   mine "), "https://example.com/a/b.git mine")
eq("URL and a bad name", (args_of("https://example.com/a/b.git a/b") or ""):find("can't contain") ~= nil, true)
eq("URL and a dotted name", (args_of("https://example.com/a/b.git .b") or ""):find("dot") ~= nil, true)
eq("URL and too much", (args_of("https://example.com/a/b.git one two") or ""):find("at most") ~= nil, true)
eq("git clone passes args through", args_of("git clone --depth 1 -b main https://example.com/a.git dir"),
    "--depth 1 -b main https://example.com/a.git dir")
eq("git clone expands ~", args_of("git clone ~/src/repo"), n("~/src/repo"))
eq("git clone with nothing", (args_of("git clone") or ""):find("needs a repository") ~= nil, true)

-- clone(): git runs in the background in the tracked directory, then the
-- clone is switched into. A local repository stands in for a remote one.
if vim.fn.executable("git") == 1 then
    local src = tmp .. "/upstream"
    local function git(...)
        return vim.system(vim.list_extend({ "git", "-c", "user.name=t", "-c", "user.email=t@t",
            "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main" }, { ... }), { text = true }):wait()
    end
    git("init", "-q", src)
    vim.fn.writefile({ "hello" }, src .. "/README")
    git("-C", src, "add", "README")
    git("-C", src, "commit", "-q", "-m", "init")
    vim.fn.mkdir(tmp .. "/Repos", "p")
    reset_store()
    projects.setup({ dirs = { tmp .. "/Repos" } })

    local finished, cloned, clone_err
    local function on_done(path, e) finished, cloned, clone_err = true, path, e end
    local function wait_clone() vim.wait(30000, function() return finished end, 20) end

    -- a file:// URL, named after the repository
    finished, switched = false, nil
    capture()
    eq("clone starts", projects.clone(tmp .. "/Repos", { "file://" .. src }, on_done) ~= nil, true)
    eq("clone says it's cloning, by the repository's name", noted("cloning upstream"), true)
    wait_clone()
    vim.notify = saved_notify
    eq("clone made the repository", vim.fn.filereadable(tmp .. "/Repos/upstream/README"), 1)
    eq("clone is a git checkout", vim.fn.isdirectory(tmp .. "/Repos/upstream/.git"), 1)
    eq("clone hands back the path", cloned and n(cloned), n(tmp .. "/Repos/upstream"))
    eq("clone switches into it", switched, n(tmp .. "/Repos/upstream"))

    -- through the new-project prompt: a URL and a name for the directory
    interact({ "file://" .. src .. " renamed" })
    projects.new_project({})
    vim.wait(30000, function() return switched ~= nil end, 20)
    eq("prompt mentions git URLs", prompts[1].prompt:find("git URL", 1, true) ~= nil, true)
    eq("URL and name clones under that name", switched, n(tmp .. "/Repos/renamed"))
    eq("named clone has the files", vim.fn.filereadable(tmp .. "/Repos/renamed/README"), 1)

    -- a whole git clone line, options and all
    interact({ "git clone --depth 1 file://" .. src .. " shallow" })
    projects.new_project({})
    vim.wait(30000, function() return switched ~= nil end, 20)
    eq("git clone line clones", switched, n(tmp .. "/Repos/shallow"))
    local depth = git("-C", tmp .. "/Repos/shallow", "rev-parse", "--is-shallow-repository")
    eq("git clone line keeps its options", vim.trim(depth.stdout or ""), "true")

    -- :Projects new with a URL
    interact({})
    vim.cmd("Projects new file://" .. src .. " fromcmd")
    vim.wait(30000, function() return switched ~= nil end, 20)
    eq(":Projects new <url> clones", switched, n(tmp .. "/Repos/fromcmd"))

    -- a clone that fails is reported with git's reason and switches nowhere
    finished, switched = false, nil
    capture()
    projects.clone(tmp .. "/Repos", { "file://" .. tmp .. "/no-such-repo" }, on_done)
    wait_clone()
    vim.notify = saved_notify
    eq("failed clone reported", noted("git clone failed"), true)
    eq("failed clone gives git's reason", noted("fatal:"), true)
    eq("failed clone hands back an error", cloned == nil and clone_err ~= nil, true)
    eq("failed clone switches nowhere", switched, nil)
    eq("failed clone leaves nothing", vim.fn.isdirectory(tmp .. "/Repos/no-such-repo"), 0)

    -- an existing name is git's to refuse
    finished = false
    capture()
    projects.clone(tmp .. "/Repos", { "file://" .. src }, on_done)
    wait_clone()
    vim.notify = saved_notify
    eq("clone onto an existing dir refused", noted("already exists"), true)

    -- a bad name after the URL never reaches git
    interact({ "file://" .. src .. " a/b" })
    capture()
    projects.new_project({})
    vim.notify = saved_notify
    eq("bad clone name reported", noted("can't contain"), true)
    eq("bad clone name runs nothing", noted("cloning"), false)
else
    print("skip clone tests (git unavailable)")
end

projects.switch, vim.ui.input = saved_switch, saved_input
vim.fn.confirm = nil
reset_store()

-- switch() kills every open buffer (saving the file-backed modified ones),
-- collapses tabs and windows, cds, and lands in Harbor on the project root.
local harbor = require("neo.plugins.harbor")
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
eq("switch lands in Harbor", vim.bo.filetype, "harbor")
eq("switch Harbor shows project root",
    norm_dir(harbor.dir(0)), norm_dir(tmp .. "/Embedded/blinky"))

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
eq("failed save still lands in Harbor", vim.bo.filetype, "harbor")

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
