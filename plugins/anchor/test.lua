-- lua/neo/plugins/anchor/test.lua
-- Run from anywhere: nvim -l path/to/plugins/anchor/test.lua
-- Standalone: neo.* requires resolve relative to this file, so no rtp setup
-- is needed and an installed copy of the config never shadows this checkout.
-- The lists go to a temporary file, never to your own.
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

local anchor = require("neo.plugins.anchor")
local store = require("neo.plugins.anchor.store")
local menu = require("neo.plugins.anchor.menu")

local failures = 0
local function eq(desc, got, want)
    if got ~= want then
        failures = failures + 1
        print(("FAIL %s: got=%s want=%s"):format(desc, vim.inspect(got), vim.inspect(want)))
    else
        print("ok   " .. desc)
    end
end
-- eq for tables
local function same(desc, got, want)
    eq(desc, vim.inspect(got), vim.inspect(want))
end

local notes = {}
local saved_notify = vim.notify
vim.notify = function(msg) notes[#notes + 1] = msg end
local function noted(text)
    for _, msg in ipairs(notes) do
        if msg:find(text, 1, true) then return true end
    end
    return false
end

-- run what the menu scheduled (its close after a leave)
local function drain()
    local done = false
    vim.schedule(function() done = true end)
    vim.wait(1000, function() return done end, 5)
end

local function feed(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function write(path, lines)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(lines, path)
end

local function read_text(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

local function edit(path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
end

local function current_file()
    return store.real(vim.api.nvim_buf_get_name(0))
end

-- fixtures: a project with a subdirectory, a file outside it, and a
-- 30-line file for cursor positions
-- Resolved: a Windows temp directory can be an 8.3 short name, which
-- would never match the real paths anchor stores.
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
tmp = store.real(tmp)
local proj, other = tmp .. "/proj", tmp .. "/other"
-- what the statusline separates a relative path with
local SEP = (vim.fn.has("win32") == 1 and not vim.o.shellslash) and "\\" or "/"
write(proj .. "/a.txt", { "a" })
write(proj .. "/b.txt", { "b" })
write(proj .. "/sub/c.txt", { "c" })
local long = {}
for i = 1, 30 do long[i] = "line " .. i end
write(proj .. "/long.txt", long)
write(other .. "/o.txt", { "o" })
local data = tmp .. "/data/anchor.json"

local orig_cwd = vim.fn.getcwd()
anchor.setup({ file = data })
eq("setup repoints the file", store.file, vim.fs.normalize(data))
eq("setup defines :Anchor", vim.fn.exists(":Anchor"), 2)
vim.cmd("cd " .. vim.fn.fnameescape(proj))

-- paths: relative inside the project, absolute outside, one name per file
local R = store.real(proj)
local O = store.real(other) .. "/o.txt"
eq("root is the cwd", store.root(), R)
eq("stored inside", store.to_stored(R .. "/sub/c.txt", R), "sub/c.txt")
eq("stored outside", store.to_stored(O, R), O)
eq("stored sibling with root as prefix", store.to_stored(R .. "x/y.txt", R), R .. "x/y.txt")
eq("stored under /", store.to_stored("/etc/hosts", "/"), "etc/hosts")
eq("to_abs relative", store.to_abs("sub/c.txt", R), R .. "/sub/c.txt")
eq("to_abs absolute", store.to_abs(O, R), O)
eq("canonical dots", store.canonical("./sub/../a.txt", R), "a.txt")
eq("canonical absolute inside", store.canonical(R .. "/b.txt", R), "b.txt")
eq("canonical tilde", store.canonical("~/nowhere/x.txt", R),
    vim.fs.normalize(vim.uv.os_homedir()) .. "/nowhere/x.txt")
if vim.uv.fs_symlink(proj, tmp .. "/plink", { dir = true }) then
    eq("real resolves symlinks", store.real(tmp .. "/plink/a.txt"), R .. "/a.txt")
    eq("canonical through a symlink", store.canonical(tmp .. "/plink/a.txt", R), "a.txt")
else
    print("skip real resolves symlinks (fs_symlink unavailable)")
end

-- the file: missing reads empty; set() trims and replaces one project,
-- keeping what another Neovim wrote for others
eq("missing file reads empty", next(store.read().projects), nil)
same("get from a missing file", store.get(R), {})
eq("set", store.set(R, { "a.txt", "", "b.txt", "", "" }), true)
same("trailing empty slots dropped", store.get(R), { "a.txt", "", "b.txt" })
local doc = vim.json.decode(read_text(data))
eq("version written", doc.version, 1)
doc.projects["/elsewhere"] = { "x.lua" }
write(data, { vim.json.encode(doc) })
store.set(R, { "b.txt" })
doc = vim.json.decode(read_text(data))
same("another project survives a save", doc.projects["/elsewhere"], { "x.lua" })
same("ours replaced", doc.projects[R], { "b.txt" })
store.set(R, {})
eq("empty list drops the project", vim.json.decode(read_text(data)).projects[R], nil)
store.set("/elsewhere", { "", "" })
eq("no projects is an object", read_text(data):find('"projects":{}', 1, true) ~= nil, true)
local leftovers = vim.fn.glob(tmp .. "/data/*.tmp", false, true)
eq("no temporary files left", #leftovers, 0)

-- a file that doesn't parse is moved aside, not overwritten
write(data, { "not json {" })
notes = {}
same("corrupt file reads empty", store.get(R), {})
eq("corrupt file reported", noted("isn't valid anchor data"), true)
eq("corrupt file moved aside", read_text(data .. ".bad"), "not json {\n")
eq("corrupt file gone", vim.uv.fs_stat(data), nil)
os.remove(data .. ".bad")
write(data, { '{"version":1,"projects":{"' .. R .. '":["a.txt",7,"b.txt"]}}' })
same("non-string slots read as empty", store.get(R), { "a.txt", "", "b.txt" })
store.set(R, {})

-- add: the first empty slot, else a new one; no duplicates
edit(proj .. "/a.txt")
eq("add first", anchor.add(), 1)
edit(proj .. "/sub/c.txt")
eq("add second", anchor.add(), 2)
edit(other .. "/o.txt")
eq("add outside the project", anchor.add(), 3)
same("list", anchor.list(), { "a.txt", "sub/c.txt", O })
edit(proj .. "/sub/c.txt")
notes = {}
eq("add again keeps the slot", anchor.add(), 2)
eq("add again says so", noted("already in slot 2"), true)
eq("add again no duplicate", #anchor.list(), 3)

-- only files: not scratch, unnamed, directory or terminal buffers
local function refused(desc)
    notes = {}
    eq(desc .. " refused", anchor.add(), nil)
    eq(desc .. " says why", noted("only files can be anchored"), true)
end
local scratch = vim.api.nvim_create_buf(true, true)
vim.api.nvim_set_current_buf(scratch)
refused("scratch")
vim.cmd("enew")
refused("unnamed")
edit(proj .. "/sub")
refused("directory")
vim.cmd("terminal")
refused("terminal")
eq("refusals change nothing", #anchor.list(), 3)

-- remove: the slot empties and the others keep their numbers; add then
-- fills that slot first
edit(proj .. "/sub/c.txt")
eq("remove", anchor.remove(), 2)
same("remove leaves a hole", anchor.list(), { "a.txt", "", O })
notes = {}
eq("remove again", anchor.remove(), nil)
eq("remove again says so", noted("isn't anchored"), true)
edit(proj .. "/b.txt")
eq("add fills the hole", anchor.add(), 2)
same("hole filled", anchor.list(), { "a.txt", "b.txt", O })
edit(other .. "/o.txt")
eq("remove the last", anchor.remove(), 3)
same("trailing hole dropped", anchor.list(), { "a.txt", "b.txt" })

-- select: open in the current window, with a short name when it opens
-- the file afresh (a buffer already open keeps the name it was opened by)
vim.cmd("enew")
for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if store.real(vim.api.nvim_buf_get_name(b)) == R .. "/a.txt" then
        vim.api.nvim_buf_delete(b, { force = true })
    end
end
eq("select 1", anchor.select(1), true)
eq("select 1 opens it", current_file(), R .. "/a.txt")
eq("select gives a short name", vim.fn.bufname(), "a.txt")
local a_buf = vim.api.nvim_get_current_buf()
eq("select the current file", anchor.select(1), true)
eq("select the current file keeps it", vim.api.nvim_get_current_buf(), a_buf)
vim.api.nvim_buf_set_lines(0, 0, 0, false, { "unsaved" })
eq("select from a modified buffer", anchor.select(2), true)
eq("select from a modified buffer opens it", current_file(), R .. "/b.txt")
eq("the modified buffer survives", vim.bo[a_buf].modified, true)
vim.api.nvim_buf_call(a_buf, function() vim.cmd("edit!") end)
notes = {}
eq("select an empty slot", anchor.select(9), false)
eq("select an empty slot says so", noted("slot 9 is empty"), true)
store.set(R, { "a.txt", "b.txt", "gone.txt" })
notes = {}
eq("select a missing file", anchor.select(3), false)
eq("select a missing file says so", noted("gone.txt no longer exists"), true)
eq("select a missing file stays put", current_file(), R .. "/b.txt")

-- select goes back to where you were: a loaded buffer keeps its place,
-- one opened afresh goes to its '" mark (kept in shada across restarts;
-- :bdelete keeps it here)
store.set(R, { "a.txt", "b.txt", "long.txt" })
edit(proj .. "/long.txt")
vim.api.nvim_win_set_cursor(0, { 20, 2 })
vim.cmd("enew")
anchor.select(3)
same("loaded buffer keeps its place", vim.api.nvim_win_get_cursor(0), { 20, 2 })
vim.api.nvim_win_set_cursor(0, { 17, 3 })
local long_buf = vim.api.nvim_get_current_buf()
vim.cmd("enew")
vim.cmd("bdelete " .. long_buf)
eq("long.txt unloaded", vim.api.nvim_buf_is_loaded(long_buf), false)
anchor.select(3)
same("reopened file goes to its '\" mark", vim.api.nvim_win_get_cursor(0), { 17, 3 })

-- each working directory has its own list; :lcd counts
vim.cmd("lcd " .. vim.fn.fnameescape(other))
same("another directory's list", anchor.list(), {})
edit(other .. "/o.txt")
eq("add there", anchor.add(), 1)
same("stored relative to that directory", anchor.list(), { "o.txt" })
vim.cmd("lcd " .. vim.fn.fnameescape(proj))
same("back to the first list", anchor.list(), { "a.txt", "b.txt", "long.txt" })

-- :Anchor and its completion
notes = {}
vim.cmd("Anchor bogus")
eq("unknown command", noted("unknown command 'bogus'"), true)
eq("unknown command lists them", noted("add, menu, remove"), true)
vim.cmd("Anchor 2")
eq(":Anchor N", current_file(), R .. "/b.txt")
vim.cmd("Anchor 1")
eq(":Anchor N again", current_file(), R .. "/a.txt")
notes = {}
vim.cmd("Anchor 0")
eq(":Anchor 0 is unknown", noted("unknown command '0'"), true)
same("complete everything", anchor.complete(""), { "add", "menu", "remove", "1", "2", "3" })
same("complete a command", anchor.complete("r"), { "remove" })
same("complete a slot", anchor.complete("2"), { "2" })

-- the menu: one line per slot, opened over the current file's line
store.set(R, { "a.txt", "b.txt", O })
edit(proj .. "/b.txt")
local origin = vim.api.nvim_get_current_win()
local buf, win = anchor.menu()
eq("menu is current", vim.api.nvim_get_current_win(), win)
eq("menu is a float", vim.api.nvim_win_get_config(win).relative, "editor")
same("menu lines", vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "a.txt", "b.txt", O })
eq("menu starts on the current file", vim.api.nvim_win_get_cursor(win)[1], 2)
eq("menu numbers its lines", vim.wo[win].number, true)
eq("menu numbers aren't relative", vim.wo[win].relativenumber, false)
eq("menu isn't modified", vim.bo[buf].modified, false)
local buf2, win2 = anchor.menu()
eq("menu again goes to it", win2, win)
eq("menu again same buffer", buf2, buf)

-- :w saves in place: reordered, a blank slot, typed paths in any form, a
-- duplicate blanked, trailing blank lines dropped
vim.api.nvim_buf_set_lines(buf, 0, -1, false,
    { "b.txt", "  ./a.txt ", "", proj .. "/sub/c.txt", "a.txt", "", "" })
eq("edits mark it modified", vim.bo[buf].modified, true)
vim.cmd("write")
same(":w saves", anchor.list(), { "b.txt", "a.txt", "", "sub/c.txt" })
same(":w shows what it saved", vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    { "b.txt", "a.txt", "", "sub/c.txt" })
eq(":w stays open", vim.api.nvim_win_is_valid(win), true)
eq(":w clears modified", vim.bo[buf].modified, false)

-- q saves and closes, back to where it was opened from
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a.txt", "", "b.txt" })
feed("q")
eq("q closes", vim.api.nvim_win_is_valid(win), false)
eq("q wipes the buffer", vim.api.nvim_buf_is_valid(buf), false)
eq("q goes back", vim.api.nvim_get_current_win(), origin)
same("q saves", anchor.list(), { "a.txt", "", "b.txt" })
eq("q leaves no menu", menu.current(), nil)

-- <Esc> too
buf, win = anchor.menu()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a.txt", "b.txt" })
feed("<Esc>")
eq("<Esc> closes", vim.api.nvim_win_is_valid(win), false)
same("<Esc> saves", anchor.list(), { "a.txt", "b.txt" })

-- <CR> saves, closes, and opens the line's file in the window it came from
edit(proj .. "/a.txt")
buf, win = anchor.menu()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a.txt", "", "sub/c.txt" })
vim.api.nvim_win_set_cursor(win, { 3, 0 })
feed("<CR>")
eq("<CR> closes", vim.api.nvim_win_is_valid(win), false)
eq("<CR> goes back", vim.api.nvim_get_current_win(), origin)
eq("<CR> opens the file", current_file(), R .. "/sub/c.txt")
same("<CR> saves", anchor.list(), { "a.txt", "", "sub/c.txt" })
buf, win = anchor.menu()
vim.api.nvim_win_set_cursor(win, { 2, 0 })
feed("<CR>")
eq("<CR> on a blank line closes", vim.api.nvim_win_is_valid(win), false)
eq("<CR> on a blank line opens nothing", current_file(), R .. "/sub/c.txt")

-- leaving any other way saves too: :q (modified, which a buffer that
-- would be wiped refuses with E37), and going to another window
buf, win = anchor.menu()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "b.txt" })
local ok, err = pcall(vim.cmd, "quit")
eq(":q works on a modified menu", ok, true)
if not ok then print(err) end
drain()
eq(":q closes", vim.api.nvim_win_is_valid(win), false)
eq(":q wipes the buffer", vim.api.nvim_buf_is_valid(buf), false)
same(":q saves", anchor.list(), { "b.txt" })
buf, win = anchor.menu()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a.txt" })
ok, err = pcall(vim.cmd, "close")
eq(":close (<C-w>c) works on a modified menu", ok, true)
if not ok then print(err) end
drain()
eq(":close closes", vim.api.nvim_win_is_valid(win), false)
same(":close saves", anchor.list(), { "a.txt" })
buf, win = anchor.menu()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a.txt", "b.txt" })
vim.cmd("wincmd p")
drain()
eq("leaving closes", vim.api.nvim_win_is_valid(win), false)
same("leaving saves", anchor.list(), { "a.txt", "b.txt" })
buf, win = anchor.menu()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "sub/c.txt" })
vim.api.nvim_exec_autocmds("QuitPre", { buffer = buf })
eq("QuitPre (:qa) saves", anchor.list()[1], "sub/c.txt")
eq("QuitPre (:qa) clears modified", vim.bo[buf].modified, false)
vim.api.nvim_win_close(win, true)
drain()
eq("closed from elsewhere", menu.current(), nil)
eq("closed from elsewhere wipes it", vim.api.nvim_buf_is_valid(buf), false)

-- a slot key inside the menu: it saves and leaves first, so the file
-- opens in the window it came from with the edited list
edit(proj .. "/a.txt")
buf, win = anchor.menu()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "b.txt" })
vim.cmd("Anchor 1")
eq("select from the menu closes it", vim.api.nvim_win_is_valid(win), false)
eq("select from the menu opens there", vim.api.nvim_get_current_win(), origin)
eq("select from the menu uses the edits", current_file(), R .. "/b.txt")

-- emptying the menu drops the project from the file
buf, win = anchor.menu()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
feed("q")
same("empty menu", anchor.list(), {})
eq("empty menu drops the project", vim.json.decode(read_text(data)).projects[R], nil)

-- the statusline: an anchored file's slot goes in front of its name, by
-- each window's own project
local statusline = require("neo.plugins.picker.statusline")
local saved_statusline = vim.go.statusline
statusline.setup()
local function shown(winid)
    return vim.api.nvim_eval_statusline(vim.go.statusline,
        { winid = winid or vim.api.nvim_get_current_win() }).str
end
local function starts(desc, text, winid)
    local got = shown(winid)
    if got:sub(1, #text) == text then
        eq(desc, true, true)
    else
        eq(desc, got, text .. "...")
    end
end
store.set(R, { "a.txt", "", O })
eq("slot of a file", anchor.slot(R .. "/a.txt"), 1)
eq("slot of a file outside the project", anchor.slot(O), 3)
eq("slot of a file in no slot", anchor.slot(R .. "/b.txt"), nil)
eq("slot in another project", anchor.slot(O, other), 1)
edit(proj .. "/a.txt")
starts("statusline shows the slot", "[1] proj: a.txt ")
edit(other .. "/o.txt")
eq("statusline slot outside the project", shown():match("^%[3%] .*o%.txt ") ~= nil, true)
edit(proj .. "/b.txt")
starts("statusline without a slot", "proj: b.txt ")

-- add, remove and the menu show at once
anchor.add()
starts("statusline after add", "[2] proj: b.txt ")
anchor.remove()
starts("statusline after remove", "proj: b.txt ")
buf, win = anchor.menu()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "b.txt", "a.txt" })
feed("q")
starts("statusline after the menu", "[1] proj: b.txt ")

-- a window with its own working directory goes by that project's list
local first = vim.api.nvim_get_current_win()
vim.cmd("split")
vim.cmd("lcd " .. vim.fn.fnameescape(other))
edit(other .. "/o.txt")
starts("lcd: that project's slot", "[1] other: o.txt ")
edit(proj .. "/b.txt")
eq("lcd: no slot there", shown():match("^%[") , nil)
starts("lcd: the other window keeps its own", "[1] proj: b.txt ", first)
vim.cmd("close")

-- another Neovim's save shows, and the list isn't read again until then
local doc2 = vim.json.decode(read_text(data))
doc2.projects[R] = { "a.txt", "", "b.txt" }
write(data .. ".other", { vim.json.encode(doc2) })
vim.uv.fs_rename(data .. ".other", data)
local reads, real_read = 0, store.read
store.read = function(...)
    reads = reads + 1
    return real_read(...)
end
starts("another Neovim's save shows", "[3] proj: b.txt ")
eq("another Neovim's save read once", reads, 1)
for _ = 1, 5 do shown() end
anchor.slot(R .. "/a.txt")
eq("unchanged list not read again", reads, 1)
store.read = real_read

-- a broken file reads as no slots, quietly, and stays for :Anchor to report
local good = read_text(data)
write(data, { "not json {" })
notes = {}
starts("broken file: no slot", "proj: b.txt ")
eq("broken file: nothing reported", #notes, 0)
eq("broken file: left in place", read_text(data), "not json {\n")
write(data, { good })
starts("fixed file: the slot again", "[3] proj: b.txt ")

-- map(): the keys open their slots, and the statusline shows a file's key
-- while it still opens the slot here; past the keys, or with the key
-- taken over, the number
store.set(R, { "a.txt", "b.txt", "sub/c.txt" })
anchor.map({ "<C-p>", "<C-t>" })
eq("map maps the key", vim.fn.maparg("<C-t>", "n", false, true).desc, "Anchor: Go to Slot 2")
edit(proj .. "/a.txt")
feed("<C-t>")
eq("the key opens its slot", current_file(), R .. "/b.txt")
starts("statusline shows a Ctrl key by its letter", "[T] proj: b.txt ")
eq("slot_label is the key", anchor.slot_label(R .. "/a.txt", proj), "P")
eq("slot_label of a slot without a key", anchor.slot_label(R .. "/sub/c.txt", proj), "3")
eq("slot_label of no slot", anchor.slot_label(R .. "/long.txt", proj), nil)
edit(proj .. "/sub/c.txt")
starts("statusline: a slot without a key", "[3] proj: sub" .. SEP .. "c.txt ")
edit(proj .. "/b.txt")
vim.keymap.set("n", "<C-t>", "<Nop>", { buffer = 0 })
starts("statusline: a key taken over in the buffer", "[2] proj: b.txt ")
vim.keymap.del("n", "<C-t>", { buffer = 0 })
starts("statusline: the key back", "[T] proj: b.txt ")
vim.keymap.set("n", "<C-t>", "<Nop>")
starts("statusline: a key mapped to something else", "[2] proj: b.txt ")
anchor.map({ "<leader>1", "<M-t>", "<c-s>" })
edit(proj .. "/a.txt")
starts("statusline: a key that isn't a lone <...>", "[<leader>1] proj: a.txt ")
edit(proj .. "/b.txt")
starts("statusline: another lone <...> key", "[M-t] proj: b.txt ")
edit(proj .. "/sub/c.txt")
starts("statusline: a Ctrl key written in lowercase", "[S] proj: sub" .. SEP .. "c.txt ")
for _, lhs in ipairs({ "<leader>1", "<M-t>", "<C-s>", "<C-p>", "<C-t>" }) do
    vim.keymap.del("n", lhs)
end
vim.go.statusline = saved_statusline

-- rename: slots in every project follow a file or directory that moved,
-- and a project that moved keeps its list
store.set("/r/proj", { "a.txt", "d/b.txt", "", "/r/out/c.txt" })
store.set("/r/other", { "/r/proj/a.txt" })
eq("rename a file", store.rename("/r/proj/a.txt", "/r/proj/z.txt"), true)
same("rename: its own project", store.get("/r/proj"), { "z.txt", "d/b.txt", "", "/r/out/c.txt" })
same("rename: another project", store.get("/r/other"), { "/r/proj/z.txt" })
eq("rename a directory", store.rename("/r/proj/d", "/r/proj/e"), true)
same("rename: inside a directory", store.get("/r/proj"), { "z.txt", "e/b.txt", "", "/r/out/c.txt" })
eq("rename out of the project", store.rename("/r/proj/z.txt", "/r/out/z.txt"), true)
same("rename: goes absolute", store.get("/r/proj"), { "/r/out/z.txt", "e/b.txt", "", "/r/out/c.txt" })
eq("rename back in", store.rename("/r/out/z.txt", "/r/proj/z.txt"), true)
same("rename: goes relative", store.get("/r/proj"), { "z.txt", "e/b.txt", "", "/r/out/c.txt" })
eq("rename the project", store.rename("/r/proj", "/r/new"), true)
same("rename: the list moved", store.get("/r/new"), { "z.txt", "e/b.txt", "", "/r/out/c.txt" })
same("rename: nothing left behind", store.get("/r/proj"), {})
same("rename: others follow it", store.get("/r/other"), { "/r/new/z.txt" })
eq("rename something unanchored", store.rename("/r/nothing", "/r/else"), true)
same("rename: a similar prefix isn't inside", (function()
    store.set("/r/sim", { "/r/new2/x.txt" })
    store.rename("/r/new", "/r/newer")
    return store.get("/r/sim")
end)(), { "/r/new2/x.txt" })
for _, r in ipairs({ "/r/newer", "/r/other", "/r/sim" }) do
    store.set(r, {})
end

vim.notify = saved_notify
vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
vim.fn.delete(tmp, "rf")

if failures > 0 then
    print("FAILURES: " .. failures)
    os.exit(1)
end
print("ALL ANCHOR TESTS PASSED")
