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

local picker = require("neo.plugins.picker")
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

-- the buffer-local mapping for lhs in mode, from the current (prompt) buffer
local function map(lhs, mode)
    local m = vim.fn.maparg(lhs, mode, false, true)
    return m.buffer == 1 and m or nil
end

local function footer_text(win)
    local footer = vim.api.nvim_win_get_config(win).footer
    if type(footer) ~= "table" then return footer end
    local parts = {}
    for _, chunk in ipairs(footer) do
        parts[#parts + 1] = chunk[1]
    end
    return table.concat(parts)
end

-- keys: mapped in the prompt in insert and normal mode, handed the open
-- controller; footer: shown on the results window's bottom border
local chosen, handed
local p = picker.open({
    title = " Test ",
    footer = " <C-y> yank ",
    items = { { display = "alpha" }, { display = "beta" } },
    on_select = function(item) chosen = item.display end,
    keys = { ["<C-y>"] = function(pp) handed = pp end },
})
eq("footer shown", footer_text(p.ui.results_win), " <C-y> yank ")
eq("key mapped in insert mode", map("<C-y>", "i") ~= nil, true)
eq("key mapped in normal mode", map("<C-y>", "n") ~= nil, true)
map("<C-y>", "i").callback()
eq("key gets the controller", handed, p)
eq("key leaves the picker open", p:valid(), true)

-- selection() is the highlighted item; choose() is what <CR> does
eq("selection starts at the top", p:selection().display, "alpha")
p:select(2)
eq("selection follows the cursor", p:selection().display, "beta")
p:choose()
eq("choose selects the highlighted item", chosen, "beta")
eq("choose closes", p:valid(), false)
eq("nothing selected once closed", p:selection(), nil)

-- no footer unless asked for
p = picker.open({ items = { { display = "x" } } })
eq("no footer by default", footer_text(p.ui.results_win) or "", "")
p:close()

-- choose on an empty list just closes
local called = false
p = picker.open({ items = {}, on_select = function() called = true end })
eq("empty selection", p:selection(), nil)
p:choose()
eq("empty choose selects nothing", called, false)
eq("empty choose closes", p:valid(), false)

-- without on_select, choose runs the item's own action
local acted
p = picker.open({ items = { { display = "x", action = function(item) acted = item.display end } } })
p:choose()
eq("choose falls back to item.action", acted, "x")

-- keys win over the built-in maps
local overridden = false
p = picker.open({ items = { { display = "x" } }, keys = { ["<CR>"] = function() overridden = true end } })
map("<CR>", "i").callback()
eq("keys override built-ins", overridden, true)
eq("overridden <CR> doesn't close", p:valid(), true)
p:close()

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

-- a slotter puts the file's slot in front, a number or text (the key that
-- opens it); nil, "", a number that isn't a slot or an error leaves it off
local slot_args
statusline.set_slotter(function(path, dir)
    slot_args = { path, dir }
    return 2
end)
eq("slot", statusline.slot(), "2")
eq("slotter gets the file", slot_args[1], vim.api.nvim_buf_get_name(0))
eq("slotter gets the dir", slot_args[2], vim.fn.getcwd())
eq("slot in front of the label", statusline.file(), "[2] proj: sub/file.txt")
eq("slot shown", shown():match("^%[2%] proj: sub/file%.txt ") ~= nil, true)
vim.cmd("edit " .. vim.fn.fnameescape(tree .. "/proj/100%.txt"))
eq("slot with a percent label", statusline.file(), "[2] proj: 100%%.txt")
util.open_file(tree .. "/outside/far.txt")
eq("slot in front of %f", statusline.file(), "[2] %f")
eq("slot shown in front of %f", shown():match("^%[2%] .*far%.txt ") ~= nil, true)
vim.cmd("enew")
eq("no slot without a file", statusline.file(), "%f")
vim.cmd("terminal")
eq("no slot for a terminal", statusline.file(), "%f")
vim.cmd("edit " .. vim.fn.fnameescape(tree .. "/proj/sub/file.txt"))
statusline.set_slotter(function() return "T" end)
eq("slot as text", statusline.file(), "[T] proj: sub/file.txt")
eq("slot as text shown", shown():match("^%[T%] proj: sub/file%.txt ") ~= nil, true)
statusline.set_slotter(function() return "5%" end)
eq("slot text escaped", statusline.file(), "[5%%] proj: sub/file.txt")
util.open_file(tree .. "/outside/far.txt")
eq("slot text escaped before %f", statusline.file(), "[5%%] %f")
vim.cmd("edit " .. vim.fn.fnameescape(tree .. "/proj/sub/file.txt"))
for _, bad in ipairs({ "nil", "empty", "zero", "fraction", "table", "error" }) do
    statusline.set_slotter(function()
        if bad == "error" then error("boom") end
        return ({ empty = "", zero = 0, fraction = 1.5, table = {} })[bad]
    end)
    eq("slotter " .. bad, statusline.file(), "proj: sub/file.txt")
end
statusline.set_slotter(nil)
eq("no slotter", statusline.file(), "proj: sub/file.txt")

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
