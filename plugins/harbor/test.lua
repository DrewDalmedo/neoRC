-- lua/neo/plugins/harbor/test.lua
-- Run from anywhere: nvim -l path/to/plugins/harbor/test.lua
-- Standalone: neo.* requires resolve relative to this file, so no rtp setup
-- is needed and an installed copy of the config never shadows this checkout.
-- Every file it touches is in a temporary directory.
local here = debug.getinfo(1, "S").source:sub(2):match("(.*)[/\\]")
local root = vim.fn.fnamemodify(here .. "/../..", ":p")

-- Also sent to the child Neovim, so it has to stand alone.
local LOADER = [[
local root = ...
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
]]
assert(loadstring(LOADER))(root)

local diff = require("neo.plugins.harbor.diff")
local plan = require("neo.plugins.harbor.plan")
local hfs = require("neo.plugins.harbor.fs")
local hview = require("neo.plugins.harbor.view")

local uv = vim.uv
local passed, failures = 0, {}

local function out(text)
    io.stdout:write(text .. "\n")
end

local function record(desc, good, detail)
    if good then
        passed = passed + 1
        out("ok   " .. desc)
    else
        failures[#failures + 1] = desc
        out("FAIL " .. desc .. (detail and (": " .. detail) or ""))
    end
end

local function eq(desc, got, want)
    record(desc, vim.deep_equal(got, want), ("got=%s want=%s"):format(vim.inspect(got), vim.inspect(want)))
end

local function ok(desc, cond)
    record(desc, not not cond)
end

local function mentions(desc, errors, text)
    local joined = table.concat(errors or {}, "\n")
    record(desc, joined:find(text, 1, true) ~= nil, "errors: " .. joined)
end

local base = vim.fn.tempname()
vim.fn.mkdir(base, "p")
base = vim.fs.normalize(uv.fs_realpath(base), { expand_env = false })

local case_number = 0

-- A fresh tree: "a.txt" is a file, "sub/" a directory, "sub/b.txt" a file
-- inside it. A file's content is its own path.
local function tree(paths)
    case_number = case_number + 1
    local dir = base .. "/case" .. case_number
    vim.fn.mkdir(dir, "p")
    for _, rel in ipairs(paths) do
        local path = dir .. "/" .. rel
        if rel:sub(-1) == "/" then
            vim.fn.mkdir(path, "p")
        else
            vim.fn.mkdir(vim.fs.dirname(path), "p")
            local f = assert(io.open(path, "wb"))
            f:write(rel)
            f:close()
        end
    end
    return dir
end

local function content(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

local function exists(path)
    return uv.fs_lstat(path) ~= nil
end

local function listing(dir)
    local entries = assert(hview.scan(dir, true))
    local ids, by_name = {}, {}
    for i, entry in ipairs(entries) do
        ids[i] = entry.id
        by_name[entry.name] = entry
    end
    return { dir = dir, lines = hview.lines(entries), shown = ids, by_name = by_name }
end

-- The listing's line for name, with its text replaced when text is given.
local function line_for(b, name, text)
    local entry = b.by_name[name]
    return ("/%d %s"):format(entry.id, text or entry.text)
end

local function without(b, name)
    local keep, gone = {}, line_for(b, name)
    for _, line in ipairs(b.lines) do
        if line ~= gone then keep[#keep + 1] = line end
    end
    b.lines = keep
end

local function rename(b, name, text)
    local gone = line_for(b, name)
    for i, line in ipairs(b.lines) do
        if line == gone then b.lines[i] = line_for(b, name, text) end
    end
end

local function compute(buffers, windows)
    return diff.compute({ buffers = buffers, entry = hview.entry, windows = windows })
end

-- diff -> plan -> run. Returns the result, or nil and the errors.
local function save(buffers, opts)
    local changes, errors = compute(buffers, opts and opts.windows)
    if not changes then return nil, errors end
    local built, build_errors = plan.build(changes, opts)
    if not built then return nil, build_errors end
    return hfs.run(built.ops), built
end

local function kinds(changes)
    local out_kinds = {}
    for i, change in ipairs(changes) do
        out_kinds[i] = change.kind
    end
    return out_kinds
end

-- ---------------------------------------------------------------- names
eq("parse_line with id", { diff.parse_line("/12 foo bar") }, { 12, "foo bar" })
eq("parse_line without id", { diff.parse_line("foo") }, { nil, "foo" })
eq("name_col", hview.name_col("/12 foo"), 4)
eq("name_col without id", hview.name_col("foo"), 0)

ok("plain name", diff.is_plain("notes é.txt"))
ok("newline isn't plain", not diff.is_plain("a\nb"))
ok("edge space isn't plain", not diff.is_plain(" a"))
ok("trailing space isn't plain", not diff.is_plain("a "))
ok("backslash isn't plain", not diff.is_plain("a\\b"))
ok("invalid utf-8 isn't plain", not diff.is_plain("a\xFFb"))
ok("overlong utf-8 is invalid", not diff.valid_utf8("\xC0\xAF"))
ok("surrogate is invalid", not diff.valid_utf8("\xED\xA0\x80"))
ok("four-byte utf-8 is valid", diff.valid_utf8("\xF0\x9F\x98\x80"))
eq("newline escaped", diff.display("a\nb"), "a\\nb")
eq("backslash escaped", diff.display("a\\b"), "a\\\\b")
eq("invalid byte escaped", diff.display("a\xFFb"), "a\\xFFb")
eq("edge spaces escaped", diff.display(" a "), "\\x20a\\x20")

eq("parse_name file", { diff.parse_name("a.txt", false) }, { "a.txt", false })
eq("parse_name dir", { diff.parse_name("a/", false) }, { "a", true })
eq("parse_name nested", { diff.parse_name("a/b.txt", false) }, { "a/b.txt", false })
for _, bad in ipairs({ "/abs", "a//b", "../x", "a/../b", ".", "..", "a\\b" }) do
    eq("refused name " .. bad, diff.parse_name(bad, false), nil)
end
eq("a $VAR stays literal", diff.parse_name("$HOME", false), "$HOME")
eq("windows backslash is a separator", { diff.parse_name("a\\b.txt", true) }, { "a/b.txt", false })
for _, bad in ipairs({ "CON", "nul.txt", "COM1", "lpt9.log", "a<b", "a:b", 'a"b', "a|b", "a?b", "a*b", "a.", "a ", "C:/x" }) do
    eq("windows refuses " .. bad, diff.parse_name(bad, true), nil)
end
eq("windows allows console.txt", diff.parse_name("console.txt", true), "console.txt")
eq("unix allows a colon", diff.parse_name("a:b", false), "a:b")

-- ----------------------------------------------------------------- diff
do
    local dir = tree({ "a.txt", "b.txt", "sub/c.txt" })
    local b = listing(dir)
    eq("no edits, no changes", compute({ b }), {})

    b = listing(dir)
    b.lines = vim.fn.reverse(b.lines)
    eq("reordering lines changes nothing", compute({ b }), {})

    b = listing(dir)
    rename(b, "a.txt", "z.txt")
    local changes = compute({ b })
    eq("rename", kinds(changes), { "move" })
    eq("rename target", changes[1].to, dir .. "/z.txt")

    b = listing(dir)
    without(b, "a.txt")
    eq("delete", kinds(compute({ b })), { "delete" })

    b = listing(dir)
    b.lines[#b.lines + 1] = "new.txt"
    b.lines[#b.lines + 1] = "newdir/"
    b.lines[#b.lines + 1] = "   "
    changes = compute({ b })
    eq("creates", kinds(changes), { "create", "create" })
    eq("create dir flag", changes[2].is_dir, true)

    b = listing(dir)
    b.lines[#b.lines + 1] = line_for(b, "a.txt", "copy.txt")
    changes = compute({ b })
    eq("copy in place", kinds(changes), { "copy" })
    eq("copy source", changes[1].from, dir .. "/a.txt")

    b = listing(dir)
    local sub = listing(dir .. "/sub")
    sub.lines[#sub.lines + 1] = line_for(b, "a.txt")
    without(b, "a.txt")
    changes = compute({ b, sub })
    eq("move across listings", kinds(changes), { "move" })
    eq("move target", changes[1].to, dir .. "/sub/a.txt")

    b = listing(dir)
    sub = listing(dir .. "/sub")
    sub.lines[#sub.lines + 1] = line_for(b, "a.txt")
    eq("paste with the source kept is a copy", kinds(compute({ b, sub })), { "copy" })

    -- only the pasting listing was edited: the source isn't being saved
    b = listing(dir)
    sub = listing(dir .. "/sub")
    sub.lines[#sub.lines + 1] = line_for(b, "a.txt")
    eq("source listing unmodified is a copy", kinds(compute({ sub })), { "copy" })

    b = listing(dir)
    sub = listing(dir .. "/sub")
    sub.lines[#sub.lines + 1] = line_for(b, "a.txt")
    rename(b, "a.txt", "renamed.txt")
    changes = compute({ b, sub })
    eq("rename here plus paste there", kinds(changes), { "move", "copy" })
    eq("the rename is the move", changes[1].to, dir .. "/renamed.txt")

    b = listing(dir)
    b.lines[#b.lines + 1] = line_for(b, "a.txt")
    local none, errors = compute({ b })
    eq("duplicate refused", none, nil)
    mentions("duplicate says so", errors, "listed twice")

    b = listing(dir)
    rename(b, "a.txt", "b.txt")
    none, errors = compute({ b })
    eq("rename onto a kept name refused", none, nil)
    mentions("collision says so", errors, "listed twice")

    b = listing(dir)
    rename(b, "a.txt", "a/")
    none, errors = compute({ b })
    eq("file to directory refused", none, nil)
    mentions("type change says so", errors, "file and a directory")

    b = listing(dir)
    rename(b, "sub", "sub2")
    none = compute({ b })
    eq("directory to file refused", none, nil)

    b = listing(dir)
    b.lines[#b.lines + 1] = "/999999 ghost"
    none, errors = compute({ b })
    eq("unknown id refused", none, nil)
    mentions("unknown id says so", errors, "unknown entry")

    b = listing(dir)
    rename(b, "a.txt", "a.txt " .. line_for(b, "b.txt"))
    without(b, "b.txt")
    none, errors = compute({ b })
    eq("joined lines refused", none, nil)
    mentions("joined lines say so", errors, "joined")

    b = listing(dir)
    b.lines[#b.lines + 1] = "notes/5 plan.txt"
    eq("a number after a slash is fine", kinds(compute({ b })), { "create" })

    eq("windows sees case-only names as equal",
        (function()
            local w = listing(dir)
            w.lines[#w.lines + 1] = "A.TXT"
            return compute({ w }, true)
        end)(), nil)
end

do
    local dir = tree({ "weird" })
    local odd = dir .. "/line\nbreak"
    local f = io.open(odd, "wb")
    if f then
        f:write("odd")
        f:close()
        local b = listing(dir)
        eq("odd name is flagged", b.by_name["line\nbreak"].escaped, true)
        eq("odd name unedited", compute({ b }), {})
        rename(b, "line\nbreak", "line break")
        local none, errors = compute({ b })
        eq("odd name can't be renamed", none, nil)
        mentions("odd name says why", errors, "unusual name")

        vim.fn.mkdir(dir .. "/into", "p")
        b = listing(dir)
        local into = listing(dir .. "/into")
        into.lines[#into.lines + 1] = line_for(b, "line\nbreak")
        without(b, "line\nbreak")
        local result = save({ b, into })
        ok("odd name moved", result and not result.failed)
        eq("odd name kept its name", content(dir .. "/into/line\nbreak"), "odd")
    end
end

-- ------------------------------------------------------------ plan + run
do
    local dir = tree({ "a.txt", "b.txt" })
    local b = listing(dir)
    local l1, l2 = line_for(b, "a.txt", "b.txt"), line_for(b, "b.txt", "a.txt")
    b.lines = { l1, l2 }
    local result = save({ b })
    ok("swap runs", result and not result.failed)
    eq("swap a", content(dir .. "/a.txt"), "b.txt")
    eq("swap b", content(dir .. "/b.txt"), "a.txt")
    eq("swap leaves no temp", #vim.fn.readdir(dir), 2)
end

do
    local dir = tree({ "a", "b", "c" })
    local b = listing(dir)
    b.lines = { line_for(b, "a", "b"), line_for(b, "b", "c"), line_for(b, "c", "a") }
    local result = save({ b })
    ok("three-way cycle runs", result and not result.failed)
    eq("cycle a", content(dir .. "/a"), "c")
    eq("cycle b", content(dir .. "/b"), "a")
    eq("cycle c", content(dir .. "/c"), "b")
end

do
    local dir = tree({ "a", "b" })
    local b = listing(dir)
    b.lines = { line_for(b, "a", "b"), line_for(b, "b", "c") }
    local result = save({ b })
    ok("chain runs", result and not result.failed)
    eq("chain moved a", content(dir .. "/b"), "a")
    eq("chain moved b", content(dir .. "/c"), "b")
    ok("chain freed a", not exists(dir .. "/a"))
end

do
    local dir = tree({ "Foo.txt" })
    local b = listing(dir)
    rename(b, "Foo.txt", "foo.txt")
    local result = save({ b })
    ok("case-only rename runs", result and not result.failed)
    eq("case-only rename applied", vim.fn.readdir(dir), { "foo.txt" })
end

do
    local dir = tree({ "one" })
    if uv.fs_link(dir .. "/one", dir .. "/two") then
        ok("hard links aren't the same entry", not plan.same_entry(dir .. "/one", dir .. "/two"))
        local b = listing(dir)
        b.lines = { line_for(b, "one", "two") }
        local none, errors = save({ b })
        -- "two" is deleted and "one" takes its name: deletes come last, so
        -- the target is still there
        eq("a hard link's name isn't free", none, nil)
        mentions("hard link says so", errors, "already exists")
        ok("both links kept", exists(dir .. "/one") and exists(dir .. "/two"))
    end
end

do
    local dir = tree({ "a.txt", "sub/" })
    local b = listing(dir)
    b.lines[#b.lines + 1] = "deep/er/new.txt"
    b.lines[#b.lines + 1] = "made/"
    local result = save({ b })
    ok("nested create runs", result and not result.failed)
    eq("nested file", content(dir .. "/deep/er/new.txt"), "")
    eq("new directory", vim.fn.isdirectory(dir .. "/made"), 1)
end

do
    local dir = tree({ "a.txt", "sub/b.txt" })
    local b, sub = listing(dir), listing(dir .. "/sub")
    sub.lines[#sub.lines + 1] = line_for(b, "a.txt")
    without(b, "a.txt")
    local result = save({ b, sub })
    ok("cross-directory move runs", result and not result.failed)
    eq("moved content", content(dir .. "/sub/a.txt"), "a.txt")
    ok("moved away", not exists(dir .. "/a.txt"))
end

do
    local dir = tree({ "tree/x.txt", "tree/deep/y.txt" })
    local b = listing(dir)
    b.lines[#b.lines + 1] = line_for(b, "tree", "copy/")
    local result = save({ b })
    ok("directory copy runs", result and not result.failed)
    eq("copied file", content(dir .. "/copy/deep/y.txt"), "tree/deep/y.txt")
    eq("original kept", content(dir .. "/tree/x.txt"), "tree/x.txt")
end

do
    local dir = tree({ "tree/x.txt", "keep.txt" })
    local b, inner = listing(dir), listing(dir .. "/tree")
    b.lines[#b.lines + 1] = line_for(inner, "x.txt")
    without(b, "tree")
    inner.lines = {}
    local result = save({ b, inner })
    ok("move out of a deleted directory runs", result and not result.failed)
    eq("the moved file survived", content(dir .. "/x.txt"), "tree/x.txt")
    ok("the directory went", not exists(dir .. "/tree"))
end

do
    local dir = tree({ "gone/x.txt", "stay.txt" })
    local b = listing(dir)
    without(b, "gone")
    local result, built = save({ b })
    ok("directory delete runs", result and not result.failed)
    ok("confirmation counts its items", built.lines[1]:find("(1 item inside)", 1, true))
    ok("directory deleted", not exists(dir .. "/gone"))
    ok("sibling kept", exists(dir .. "/stay.txt"))
end

do
    local dir = tree({ "real/keep.txt" })
    if uv.fs_symlink(dir .. "/real", dir .. "/link", { dir = true }) then
        local b = listing(dir)
        without(b, "link")
        local result = save({ b })
        ok("link delete runs", result and not result.failed)
        ok("link gone", not exists(dir .. "/link"))
        eq("link target kept", content(dir .. "/real/keep.txt"), "real/keep.txt")

        uv.fs_symlink("real/keep.txt", dir .. "/rel")
        b = listing(dir)
        b.lines[#b.lines + 1] = line_for(b, "rel", "rel2")
        result = save({ b })
        ok("link copy runs", result and not result.failed)
        eq("link copied as a link", uv.fs_readlink(dir .. "/rel2"), "real/keep.txt")
    end
end

do
    local dir = tree({ "a.txt", "b.txt" })
    local b = listing(dir)
    rename(b, "a.txt", "c.txt")
    vim.fn.writefile({ "someone else" }, dir .. "/c.txt")
    local none, errors = save({ b })
    eq("existing target refused", none, nil)
    mentions("existing target says so", errors, "already exists")
    eq("existing target untouched", vim.fn.readfile(dir .. "/c.txt"), { "someone else" })

    b = listing(dir)
    without(b, "a.txt")
    os.remove(dir .. "/a.txt")
    none, errors = save({ b })
    eq("vanished source refused", none, nil)
    mentions("vanished source says so", errors, "no longer exists")
end

do
    local dir = tree({ "a.txt" })
    local b = listing(dir)
    rename(b, "a.txt", "z.txt")
    os.remove(dir .. "/a.txt")
    vim.fn.mkdir(dir .. "/a.txt")
    local none, errors = save({ b })
    eq("replaced source refused", none, nil)
    mentions("replaced source says so", errors, "changed on disk")
end

do
    local dir = tree({ "a.txt", "sub/b.txt" })
    local b = listing(dir)
    without(b, "a.txt")
    local none, errors = save({ b }, {
        protected = function(path) return path:find("a.txt", 1, true) and "it's protected" or nil end,
    })
    eq("protected refused", none, nil)
    mentions("protected says why", errors, "it's protected")
    ok("protected file kept", exists(dir .. "/a.txt"))

    b = listing(dir)
    without(b, "a.txt")
    none, errors = save({ b }, { unsaved = function() return true end })
    eq("unsaved refused", none, nil)
    mentions("unsaved says so", errors, "unsaved changes")
    ok("unsaved file kept", exists(dir .. "/a.txt"))
end

do
    local dir = tree({ "top/inner/x.txt" })
    local b, top = listing(dir), listing(dir .. "/top")
    top.lines[#top.lines + 1] = line_for(b, "top", "copy/")
    local none, errors = save({ b, top })
    eq("copy into itself refused", none, nil)
    mentions("into itself says so", errors, "inside itself")

    b, top = listing(dir), listing(dir .. "/top")
    rename(b, "top", "moved/")
    rename(top, "inner", "inner2/")
    none, errors = save({ b, top })
    eq("moved directory with inner change refused", none, nil)
    mentions("inner change says so", errors, "separate save")

    b, top = listing(dir), listing(dir .. "/top")
    without(b, "top")
    top.lines[#top.lines + 1] = "new.txt"
    none, errors = save({ b, top })
    eq("create inside a deleted directory refused", none, nil)
    mentions("deleted directory says so", errors, "being deleted")
    ok("nothing was deleted", exists(dir .. "/top/inner/x.txt"))
end

do
    local dir = tree({ "a.txt" })
    local b = listing(dir)
    without(b, "a.txt")
    b.lines[#b.lines + 1] = "a.txt"
    local none, errors = save({ b })
    eq("delete then recreate takes two saves", none, nil)
    mentions("recreate says so", errors, "already exists")
    eq("original kept", content(dir .. "/a.txt"), "a.txt")

    b = listing(dir)
    b.lines[#b.lines + 1] = "a.txt/inner.txt"
    none, errors = save({ b })
    eq("a file can't be a parent", none, nil)
    mentions("file parent says so", errors, "isn't a directory")

    b = listing(dir)
    b.lines[#b.lines + 1] = "both"
    b.lines[#b.lines + 1] = "both/inner.txt"
    none, errors = save({ b })
    eq("file and directory at once refused", none, nil)
    mentions("both says so", errors, "both a file and a directory")
end

-- (Windows has no FIFOs, whatever a mkfifo from Git's tools makes there)
if vim.fn.has("win32") == 0 and vim.fn.executable("mkfifo") == 1 then
    local dir = tree({ "d/x.txt" })
    vim.fn.system({ "mkfifo", dir .. "/d/pipe" })
    if vim.v.shell_error == 0 then
        local b = listing(dir)
        b.lines[#b.lines + 1] = line_for(b, "d", "copy/")
        local none, errors = save({ b })
        eq("copying a FIFO refused", none, nil)
        mentions("FIFO says so", errors, "FIFO")
        ok("nothing copied", not exists(dir .. "/copy"))
    end
end

-- A failure stops the run, reports what happened, and leaves deletes undone.
do
    local dir = tree({ "a.txt", "b.txt", "c.txt" })
    local ops = {
        { op = "move", from = dir .. "/a.txt", to = dir .. "/a2.txt" },
        { op = "move", from = dir .. "/missing", to = dir .. "/x" },
        { op = "delete", from = dir .. "/b.txt" },
    }
    local result = hfs.run(ops)
    eq("partial failure counts done", #result.done, 1)
    ok("partial failure names the op", result.failed and result.failed.op == ops[2])
    eq("partial failure counts skipped", #result.skipped, 1)
    ok("the delete never ran", exists(dir .. "/b.txt"))

    -- a failed swap puts the parked name back
    ops = {
        { op = "move", from = dir .. "/b.txt", to = dir .. "/b.tmp", temp = true },
        { op = "move", from = dir .. "/missing", to = dir .. "/x" },
    }
    result = hfs.run(ops)
    ok("failed swap fails", result.failed)
    eq("parked name restored", content(dir .. "/b.txt"), "b.txt")
    eq("nothing left parked", result.parked, {})

    eq("move won't overwrite", (function()
        local r = hfs.run({ { op = "move", from = dir .. "/b.txt", to = dir .. "/c.txt" } })
        return r.failed ~= nil and content(dir .. "/c.txt")
    end)(), "c.txt")
end

-- ------------------------------------------------------- real keystrokes
-- A separate Neovim, since `nvim -l` can't take typed keys. Its clipboard
-- is a fake one, so the tests never touch yours.
local CHILD_SETUP = [[
local store_file = ...
_G.clip, _G.notes = nil, {}
local function copy(lines) _G.clip = lines end
local function paste() return _G.clip or {} end
vim.g.clipboard = {
    name = "fake",
    copy = { ["+"] = copy, ["*"] = copy },
    paste = { ["+"] = paste, ["*"] = paste },
}
vim.o.clipboard = "unnamedplus"
vim.notify = function(message) table.insert(_G.notes, message) end
require("neo.plugins.anchor.store").file = store_file
require("neo.plugins.harbor").setup()
]]

local function child(fn, args)
    local argv = { vim.v.progpath, "--embed", "--headless", "--clean", "-n" }
    vim.list_extend(argv, args or {})
    local chan = vim.fn.jobstart(argv, { rpc = true })
    local c = {}
    function c.lua(code, ...)
        return vim.rpcrequest(chan, "nvim_exec_lua", code, { ... })
    end
    function c.settle()
        vim.rpcrequest(chan, "nvim_exec_lua", "vim.wait(30)", {})
    end
    function c.keys(keys)
        vim.rpcrequest(chan, "nvim_input", keys)
        c.settle()
    end
    function c.open(dir)
        c.lua("require('neo.plugins.harbor').open(...)", dir)
        c.settle()
    end
    function c.names()
        return c.lua([[
            local names = {}
            for _, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
                names[#names + 1] = (line:gsub("^/%d+ ", ""))
            end
            return names
        ]])
    end
    function c.go(text)
        local found = c.lua([[
            for row, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
                if line:gsub("^/%d+ ", "") == ... then
                    vim.api.nvim_win_set_cursor(0, { row, 0 })
                    return true
                end
            end
            return false
        ]], text)
        assert(found, "no line for " .. text)
        c.settle()
    end
    function c.ft()
        return c.lua("return vim.bo.filetype")
    end
    function c.modified()
        return c.lua("return vim.bo.modified")
    end
    function c.save()
        c.keys(":w<CR>")
        c.keys("y")
    end
    c.lua(LOADER, root)
    local good, err = xpcall(fn, debug.traceback, c)
    pcall(vim.fn.jobstop, chan)
    vim.fn.jobwait({ chan }, 2000)
    if not good then
        record("keystroke tests finished", false, err)
    end
end

child(function(c)
    local store_file = base .. "/anchor.json"
    c.lua(CHILD_SETUP, store_file)

    -- browsing
    local dir = tree({ "a.txt", "b.txt", "sub/c.txt", ".hidden" })
    c.open(dir)
    eq("listing filetype", c.ft(), "harbor")
    eq("listing names", c.names(), { "sub/", ".hidden", "a.txt", "b.txt" })
    eq("listing is acwrite", c.lua("return vim.bo.buftype"), "acwrite")
    eq("ids concealed", c.lua("return { vim.wo.conceallevel, vim.wo.concealcursor }"), { 3, "nvic" })
    eq("clipboard is off in a listing", c.lua("return vim.o.clipboard"), "")
    eq("starts unmodified", c.modified(), false)
    local function col() return c.lua("return vim.fn.col('.') - 1") end
    local function name_col() return c.lua("return require('neo.plugins.harbor.view').name_col(vim.api.nvim_get_current_line())") end
    ok("cursor starts on the name", col() == name_col())
    c.keys("$0")
    eq("0 stops at the name", col(), name_col())
    c.keys("g.")
    eq("g. hides dotfiles", c.names(), { "sub/", "a.txt", "b.txt" })
    c.keys("g.")
    eq("g. shows them again", c.names(), { "sub/", ".hidden", "a.txt", "b.txt" })
    c.go("sub/")
    c.keys("<CR>")
    eq("<CR> enters a directory", c.names(), { "c.txt" })
    c.keys("-")
    eq("- goes up", c.names()[1], "sub/")
    eq("- lands on where it came from", c.lua("return vim.fn.line('.')"), 1)
    c.go("a.txt")
    c.keys("<CR>")
    eq("<CR> opens a file", c.lua("return vim.fn.expand('%:t')"), "a.txt")
    eq("clipboard back outside a listing", c.lua("return vim.o.clipboard"), "unnamedplus")
    eq("conceal stays in the listing", c.lua("return vim.wo.conceallevel"), 0)
    eq("wrap isn't left off", c.lua("return vim.wo.wrap"), true)
    c.lua("vim.cmd('Harbor')")
    c.settle()
    eq(":Harbor opens the file's directory", c.ft(), "harbor")
    eq(":Harbor lands on the file", c.lua("return vim.api.nvim_get_current_line():match('a%.txt$') ~= nil"), true)

    -- rename, with the question answered both ways
    c.go("a.txt")
    c.keys("ccz.txt<Esc>")
    eq("cc keeps the id", c.lua("return vim.api.nvim_get_current_line():match('^/%d+ z%.txt$') ~= nil"), true)
    eq("edit marks it modified", c.modified(), true)
    c.keys(":w<CR>")
    eq("save asks first", c.ft(), "malleable_confirm")
    ok("question shows the rename", c.lua("return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false))"):find("RENAME", 1, true))
    ok("nothing moved yet", exists(dir .. "/a.txt"))
    c.keys("n")
    eq("no goes back", c.ft(), "harbor")
    eq("no keeps the edit", c.modified(), true)
    ok("no changes nothing", exists(dir .. "/a.txt") and not exists(dir .. "/z.txt"))
    c.save()
    ok("yes renames", exists(dir .. "/z.txt") and not exists(dir .. "/a.txt"))
    eq("saved is unmodified", c.modified(), false)
    eq("listing shows it", c.names(), { "sub/", ".hidden", "b.txt", "z.txt" })
    c.keys("u")
    eq("u can't undo past a save", c.names(), { "sub/", ".hidden", "b.txt", "z.txt" })
    eq("u leaves it unmodified", c.modified(), false)

    -- the id survives insert-mode deleting
    c.go("b.txt")
    c.keys("I<BS><BS><C-u><C-w>x<Esc>")
    eq("insert keys can't reach the id", c.lua("return vim.api.nvim_get_current_line():match('^/%d+ xb%.txt$') ~= nil"), true)
    c.keys("A<C-u>q.txt<Esc>")
    eq("<C-u> stops at the name", c.lua("return vim.api.nvim_get_current_line():match('^/%d+ q%.txt$') ~= nil"), true)
    c.keys(":e!<CR>")
    eq(":e! discards edits", c.names(), { "sub/", ".hidden", "b.txt", "z.txt" })
    eq(":e! leaves it unmodified", c.modified(), false)

    -- :w other-file saves a copy of the text and applies nothing
    c.go("b.txt")
    c.keys("dd")
    local copy_path = base .. "/copy-of-listing"
    c.keys(":w " .. copy_path .. "<CR>")
    ok(":w other-file writes it", exists(copy_path))
    ok(":w other-file applies nothing", exists(dir .. "/b.txt"))
    eq(":w other-file keeps it modified", c.modified(), true)
    c.keys(":e!<CR>")

    -- :wq asks too, and stays open
    c.go("b.txt")
    c.keys("dd")
    c.keys(":wq<CR>")
    eq(":wq asks", c.ft(), "malleable_confirm")
    c.keys("n")
    eq(":wq leaves the listing open", c.ft(), "harbor")
    ok(":wq answered no deletes nothing", exists(dir .. "/b.txt"))
    c.keys(":e!<CR>")

    -- move across directories, by yank registers alone
    c.go("b.txt")
    c.keys("dd")
    c.go("sub/")
    c.keys("<CR>")
    c.keys("p")
    eq("clipboard never saw the id", c.lua("return _G.clip"), vim.NIL)
    c.save()
    eq("move arrived", content(dir .. "/sub/b.txt"), "b.txt")
    ok("move left", not exists(dir .. "/b.txt"))
    eq("both listings clean", c.lua([[
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.bo[b].filetype == "harbor" and vim.bo[b].modified then return true end
        end
        return false
    ]]), false)
    c.keys("-")
    eq("the source listing updated", c.names(), { "sub/", ".hidden", "z.txt" })

    -- copy
    c.go("z.txt")
    c.keys("yyp")
    c.keys("cccopy.txt<Esc>")
    c.save()
    eq("copy made", content(dir .. "/copy.txt"), "a.txt")
    eq("copy source kept", content(dir .. "/z.txt"), "a.txt")

    -- delete and create
    c.go("copy.txt")
    c.keys("dd")
    c.keys("onew/inner.txt<Esc>")
    c.save()
    ok("deleted", not exists(dir .. "/copy.txt"))
    ok("created with parents", exists(dir .. "/new/inner.txt"))

    -- refused saves change nothing and keep the edits
    c.go("z.txt")
    c.keys("cc.hidden<Esc>")
    c.keys(":w<CR>")
    eq("a collision never reaches the question", c.ft(), "harbor")
    eq("a refused save keeps the edit", c.modified(), true)
    ok("the refusal is reported", c.lua("return _G.notes[#_G.notes]"):find("listed twice", 1, true))
    c.keys(":e!<CR>")

    -- gy puts the path on the (fake) clipboard
    c.go("z.txt")
    c.keys("gy")
    eq("gy copies the path", c.lua("return _G.clip"), { dir .. "/z.txt" })
    c.lua("_G.clip = nil")

    -- open buffers follow
    local d2 = tree({ "file.txt", "gone.txt", "dirty.txt", "folder/in.txt", "folder2/x.txt" })
    c.lua([[
        local d = ...
        vim.cmd("edit " .. vim.fn.fnameescape(d .. "/file.txt"))
        vim.cmd("edit " .. vim.fn.fnameescape(d .. "/gone.txt"))
        vim.cmd("edit " .. vim.fn.fnameescape(d .. "/folder/in.txt"))
        vim.cmd("edit " .. vim.fn.fnameescape(d .. "/dirty.txt"))
        vim.api.nvim_buf_set_lines(0, 0, 0, false, { "unsaved" })
    ]], d2)
    c.open(d2)
    c.go("file.txt")
    c.keys("ccmoved.txt<Esc>")
    c.save()
    local function buffer_named(path)
        return c.lua("return vim.fn.bufexists(...) == 1 and vim.api.nvim_buf_is_loaded(vim.fn.bufnr(...))", path)
    end
    eq("open buffer renamed", buffer_named(d2 .. "/moved.txt"), true)
    eq("old name is gone", c.lua("return vim.fn.bufexists(...)", d2 .. "/file.txt"), 0)
    c.lua([[
        local d = ...
        vim.cmd("buffer " .. vim.fn.fnameescape(d .. "/moved.txt"))
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "written after the rename" })
        vim.cmd("write")
    ]], d2)
    eq("renamed buffer can :w", vim.fn.readfile(d2 .. "/moved.txt"), { "written after the rename" })

    c.open(d2)
    c.go("gone.txt")
    c.keys("dd")
    c.save()
    eq("deleted file's buffer wiped", c.lua("return vim.fn.bufexists(...)", d2 .. "/gone.txt"), 0)

    c.go("folder/")
    c.keys("ccfolder3/<Esc>")
    c.save()
    eq("buffer inside a moved directory follows", buffer_named(d2 .. "/folder3/in.txt"), true)

    c.go("dirty.txt")
    c.keys("dd")
    c.keys(":w<CR>")
    eq("unsaved file blocks the save", c.ft(), "harbor")
    ok("unsaved file kept", exists(d2 .. "/dirty.txt"))
    ok("unsaved says why", c.lua("return _G.notes[#_G.notes]"):find("unsaved changes", 1, true))
    c.keys(":e!<CR>")
    c.lua([[
        local d = ...
        local b = vim.fn.bufnr(d .. "/dirty.txt")
        vim.api.nvim_buf_call(b, function() vim.cmd("edit!") end)
    ]], d2)

    -- anchor slots follow
    c.lua([[
        local store = require("neo.plugins.anchor.store")
        local d = ...
        store.set(d, { "moved.txt", "folder3/in.txt", "/elsewhere/x" })
    ]], d2)
    c.go("moved.txt")
    c.keys("ccanchored.txt<Esc>")
    c.save()
    c.go("folder3/")
    c.keys("ccfolder4/<Esc>")
    c.save()
    eq("anchor slots follow", c.lua("return require('neo.plugins.anchor.store').get(...)", d2),
        { "anchored.txt", "folder4/in.txt", "/elsewhere/x" })

    -- working directories follow, and a listing of a moved directory too
    c.lua("vim.cmd('cd ' .. vim.fn.fnameescape(...))", d2 .. "/folder4")
    c.open(d2 .. "/folder4")
    c.keys("-")
    c.go("folder4/")
    c.keys("ccfolder5/<Esc>")
    c.save()
    eq("cwd follows a move", vim.fs.normalize(c.lua("return vim.fn.getcwd()")), d2 .. "/folder5")
    eq("no listing left on the old path", c.lua([[
        return vim.fn.bufexists("harbor://" .. ...)
    ]], d2 .. "/folder4"), 0)

    -- deleting the working directory leaves it on the parent
    c.go("folder5/")
    c.keys("dd")
    c.save()
    ok("directory deleted", not exists(d2 .. "/folder5"))
    eq("cwd moved up", vim.fs.normalize(c.lua("return vim.fn.getcwd()")), d2)

    -- files inside the config can change, the config itself can't
    local cfg = c.lua("return vim.fs.normalize(vim.fn.stdpath('config'))")
    eq("projects keeps the config whole", c.lua(
        "return require('neo.plugins.projects').protected(..., { allow_config_contents = true }) ~= nil", cfg), true)
    eq("files inside the config may change", c.lua(
        "return require('neo.plugins.projects').protected(..., { allow_config_contents = true })", cfg .. "/init.lua"), vim.NIL)
    eq("projects itself still protects them", c.lua(
        "return require('neo.plugins.projects').protected(...) ~= nil", cfg .. "/init.lua"), true)

    -- swapping two open files keeps each buffer on its own file
    local d4 = tree({ "one.txt", "two.txt", "Case.txt" })
    c.lua([[
        local d = ...
        vim.cmd("edit " .. vim.fn.fnameescape(d .. "/one.txt"))
        _G.one_buf = vim.api.nvim_get_current_buf()
        vim.cmd("edit " .. vim.fn.fnameescape(d .. "/two.txt"))
        _G.two_buf = vim.api.nvim_get_current_buf()
        vim.cmd("edit " .. vim.fn.fnameescape(d .. "/Case.txt"))
        _G.case_buf = vim.api.nvim_get_current_buf()
        require("neo.plugins.anchor.store").set(d, { "one.txt", "two.txt" })
    ]], d4)
    c.open(d4)
    c.go("one.txt")
    c.keys("ccswap.txt<Esc>")
    c.go("two.txt")
    c.keys("ccone.txt<Esc>")
    c.go("swap.txt")
    c.keys("cctwo.txt<Esc>")
    c.go("Case.txt")
    c.keys("cccase.txt<Esc>")
    c.save()
    eq("swap on disk", { content(d4 .. "/one.txt"), content(d4 .. "/two.txt") }, { "two.txt", "one.txt" })
    eq("first buffer followed its file", c.lua("return vim.api.nvim_buf_get_name(_G.one_buf)"), d4 .. "/two.txt")
    eq("second buffer followed its file", c.lua("return vim.api.nvim_buf_get_name(_G.two_buf)"), d4 .. "/one.txt")
    eq("first buffer's text", c.lua("return vim.api.nvim_buf_get_lines(_G.one_buf, 0, 1, false)[1]"), "one.txt")
    eq("case-only rename renames its buffer", c.lua("return vim.api.nvim_buf_get_name(_G.case_buf)"), d4 .. "/case.txt")
    eq("anchor slots swap too", c.lua("return require('neo.plugins.anchor.store').get(...)", d4), { "two.txt", "one.txt" })
    eq("no temporary names left", vim.fn.sort(vim.fn.readdir(d4)), { "case.txt", "one.txt", "two.txt" })

    -- what's on screen: names, never ids
    local d5 = tree({ "shown.txt" })
    if uv.fs_symlink("shown.txt", d5 .. "/pointer") then
        c.open(d5)
        c.lua("vim.cmd('redraw!')")
        local screen = c.lua([[
            local rows = {}
            for row = 1, 2 do
                local text = {}
                for col = 1, 40 do text[col] = vim.fn.screenstring(row, col) end
                rows[row] = vim.trim(table.concat(text))
            end
            return rows
        ]])
        eq("ids aren't drawn", screen[2], "shown.txt")
        eq("a link shows its target", screen[1], "pointer -> shown.txt")
    end

    -- a harbor:// name opens as a listing (as a restored session does)
    c.lua("vim.cmd('enew!')")
    c.keys(":e harbor://" .. d5 .. "<CR>")
    c.settle()
    eq("harbor:// name opens a listing", c.lua("return require('neo.plugins.harbor').dir(0)"), d5)

    -- netrw: directories come here, :Explore still goes there
    local d3 = tree({ "x.txt", "y/z.txt" })
    c.lua("vim.cmd('edit ' .. vim.fn.fnameescape(...))", d4 .. "/one.txt")
    c.keys(":e " .. d3 .. "<CR>")
    c.settle()
    eq(":e dir opens a listing", c.ft(), "harbor")
    eq(":e dir lists it", c.names(), { "y/", "x.txt" })
    eq("the plain directory buffer is gone", c.lua("return vim.fn.bufexists(...)", d3), 0)
    eq("# still points back", c.lua("return vim.fn.expand('#:t')"), "one.txt")
    c.lua("vim.cmd('enew!')")
    c.keys(":Explore " .. d3 .. "<CR>")
    c.settle()
    eq(":Explore is still netrw", c.ft(), "netrw")
end)

-- nvim <dir>: Harbor from the very start
do
    local dir = tree({ "start.txt", "inner/x.txt" })
    local init = base .. "/init-for-start.lua"
    local f = assert(io.open(init, "wb"))
    f:write(("assert(loadstring(%q))(%q)\n"):format(LOADER, root))
    f:write('require("neo.plugins.harbor").setup()\n')
    f:close()
    child(function(c)
        c.settle()
        eq("nvim <dir> opens a listing", c.ft(), "harbor")
        eq("nvim <dir> lists it", c.names(), { "inner/", "start.txt" })
    end, { "-u", init, dir })
end

vim.fn.delete(base, "rf")

out(("\n%d passed, %d failed"):format(passed, #failures))
for _, desc in ipairs(failures) do
    out("  failed: " .. desc)
end
vim.cmd("cquit " .. (#failures == 0 and 0 or 1))
