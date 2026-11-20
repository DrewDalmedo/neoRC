-- lua/neo/plugins/picker/test.lua
-- Run from anywhere: nvim -l path/to/plugins/picker/test.lua
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

local statusline = require("neo.plugins.picker.statusline")
local util = require("neo.plugins.picker.util")

local failures = 0
local function eq(desc, got, want)
    if got ~= want then
        failures = failures + 1
        print(("FAIL %s: got=%s want=%s"):format(desc, vim.inspect(got), vim.inspect(want)))
    else
        print("ok   " .. desc)
    end
end

local ITEM = "%{%v:lua.require('neo.plugins.picker.statusline').file()%}"

-- setup() swaps the %f of the statusline it finds for the item and keeps
-- the rest; running it again changes nothing
local default = vim.go.statusline
statusline.setup()
local function swap_f(line)
    return (line:gsub("%%f", function() return ITEM end, 1))
end
if default ~= "" then
    eq("setup replaces %f", vim.go.statusline, swap_f(default))
else
    eq("setup replaces %f", vim.go.statusline, swap_f("%<%f %h%w%m%r%=%-14.(%l,%c%V%) %P"))
end
local installed = vim.go.statusline
statusline.setup()
eq("setup twice is setup once", vim.go.statusline, installed)

-- an empty statusline (older Neovim's) becomes the built-in one, with the
-- item (newer Neovim reads an emptied statusline back as its default);
-- one without %f is left as it is; %%f is a literal, not %f
vim.go.statusline = ""
if vim.go.statusline == "" then
    statusline.setup()
    eq("empty statusline", vim.go.statusline, "%<" .. ITEM .. " %h%w%m%r%=%-14.(%l,%c%V%) %P")
else
    print("skip empty statusline (it can't be emptied here)")
end
vim.go.statusline = "%l,%c"
statusline.setup()
eq("no %f left alone", vim.go.statusline, "%l,%c")
vim.go.statusline = "100%%f %f"
statusline.setup()
eq("%%f is not %f", vim.go.statusline, "100%%f " .. ITEM)
vim.go.statusline = installed

-- a fixture project, with a file outside it
local tree = vim.fs.normalize(vim.uv.fs_realpath(vim.fn.tempname():match("(.*)[/\\]")) or "")
tree = vim.fs.joinpath(tree, "statusline-test")
vim.fn.mkdir(tree .. "/proj/sub", "p")
vim.fn.mkdir(tree .. "/outside", "p")
vim.fn.writefile({ "one", "two" }, tree .. "/proj/sub/file.txt")
vim.fn.writefile({ "x" }, tree .. "/proj/100%.txt")
vim.fn.writefile({ "x" }, tree .. "/outside/far.txt")
local saved_cwd = vim.fn.getcwd()
vim.cmd("cd " .. vim.fn.fnameescape(tree .. "/proj"))

-- what the statusline of the current window shows
local function shown()
    return vim.api.nvim_eval_statusline(vim.go.statusline, { winid = vim.api.nvim_get_current_win() }).str
end

-- a picked file: the project, then the path inside it
util.open_file(tree .. "/proj/sub/file.txt")
eq("label", statusline.label(), "proj: sub/file.txt")
eq("statusline shows the project", shown():match("^proj: sub/file%.txt ") ~= nil, true)
-- so does one opened by its full path, and one opened relative
vim.cmd("edit " .. vim.fn.fnameescape(tree .. "/proj/sub/file.txt"))
eq("full path opened", statusline.label(), "proj: sub/file.txt")
vim.cmd("edit sub/file.txt")
eq("relative path opened", statusline.label(), "proj: sub/file.txt")
-- a new file that isn't written yet is in the project too
vim.cmd("edit sub/new.txt")
eq("unwritten file", statusline.label(), "proj: sub/new.txt")

-- a % in the name is text, not a statusline item
vim.cmd("edit " .. vim.fn.fnameescape(tree .. "/proj/100%.txt"))
eq("percent label", statusline.label(), "proj: 100%.txt")
eq("percent escaped", statusline.file(), "proj: 100%%.txt")
eq("percent shown", shown():match("^proj: 100%%%.txt ") ~= nil, true)

-- files outside the project, and buffers that aren't files, show as %f
util.open_file(tree .. "/outside/far.txt")
eq("outside: no label", statusline.label(), nil)
eq("outside: %f", statusline.file(), "%f")
eq("outside shown as before", shown():find("proj:", 1, true), nil)
vim.cmd("enew")
eq("no name: %f", statusline.file(), "%f")
eq("no name shown as before", shown():match("^%[No Name%]") ~= nil, true)
vim.bo.buftype = "nofile"
vim.api.nvim_buf_set_name(0, tree .. "/proj/scratch")
eq("nofile buffer: %f", statusline.file(), "%f")
vim.cmd("enew")
vim.cmd("terminal")
eq("terminal: %f", statusline.file(), "%f")
vim.cmd("enew")
vim.api.nvim_buf_set_name(0, tree .. "/proj")
eq("the project directory itself: %f", statusline.file(), "%f")

-- each window's statusline follows its own working directory
vim.cmd("edit " .. vim.fn.fnameescape(tree .. "/proj/sub/file.txt"))
vim.cmd("split")
vim.cmd("lcd sub")
eq("lcd: project is the window's dir", statusline.label(), "sub: file.txt")
local other = vim.fn.win_getid(vim.fn.winnr("j"))
eq("lcd: the other window keeps its own",
    vim.api.nvim_eval_statusline(vim.go.statusline, { winid = other }).str:match("^proj: sub/file%.txt ") ~= nil, true)
vim.cmd("close")

-- a namer names the project; nil, "" or an error leaves it to the basename
local asked
statusline.set_namer(function(dir)
    asked = dir
    return "Named"
end)
eq("namer names it", statusline.label(), "Named: sub/file.txt")
eq("namer gets the dir", asked, vim.fn.getcwd())
asked = nil
statusline.label()
eq("names are remembered", asked, nil)
statusline.set_namer(function() return nil end)
eq("namer nil", statusline.label(), "proj: sub/file.txt")
statusline.set_namer(function() return "" end)
eq("namer empty", statusline.label(), "proj: sub/file.txt")
statusline.set_namer(function() error("boom") end)
eq("namer error", statusline.label(), "proj: sub/file.txt")
statusline.set_namer(nil)

-- the home directory and the root aren't projects
local home = vim.uv.os_homedir()
eq("home is no project", statusline.project(home), nil)
eq("root is no project", statusline.project("/"), nil)
eq("a dir is one", statusline.project(tree .. "/proj"), "proj")

vim.cmd("cd " .. vim.fn.fnameescape(saved_cwd))
vim.fn.delete(tree, "rf")

if failures > 0 then
    print("FAILURES: " .. failures)
    os.exit(1)
end
print("ALL PICKER TESTS PASSED")
