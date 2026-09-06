-- lua/neo/plugins/syntax/test.lua
-- Run from anywhere: nvim -l path/to/plugins/syntax/test.lua
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

local syntax = require("neo.plugins.syntax")

local failures = 0
local function eq(desc, got, want)
    if got ~= want then
        failures = failures + 1
        print(("FAIL %s: got=%s want=%s"):format(desc, vim.inspect(got), vim.inspect(want)))
    else
        print("ok   " .. desc)
    end
end

-- rule application is scheduled past the builtin "syn clear"; queue a
-- sentinel behind any pending applies and pump the loop until it runs
local function drain()
    local done = false
    vim.schedule(function() done = true end)
    vim.wait(1000, function() return done end, 5)
end

-- scratch buffer with the given lines and filetype, applied and drained
local function open_buffer(lines, ft)
    local buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo.filetype = ft
    drain()
    return buf
end

-- syntax group name at (lnum, first occurrence of needle [+ offset])
local function group_at(lines, lnum, needle, offset)
    local col = lines[lnum]:find(needle, 1, true)
    if not col then return "needle '" .. needle .. "' missing on line " .. lnum end
    return vim.fn.synIDattr(vim.fn.synID(lnum, col + (offset or 0), 1), "name")
end

local notes = {}
local function noted(pat)
    for _, msg in ipairs(notes) do
        if msg:find(pat, 1, true) then return true end
    end
    return false
end
local saved_notify = vim.notify

-- malformed specs and rules are reported, and the good rules still apply
notes = {}
vim.notify = function(msg) notes[#notes + 1] = msg end
syntax.setup({ langs = {
    { rules = {} },
    { filetype = "partial", rules = {
        { "pGood", link = "Keyword", keywords = { "yes" } },
        { "pBad" },
        { "pBoth", keywords = { "a" }, match = "b" },
        { 42 },
        { "pNoDelim", match = [["'/+@#!%&;=]] },
        { "pRegion", region = { "a" } },
    } },
} })
vim.notify = saved_notify
eq("spec without filetype reported", noted("filetype string"), true)
eq("rule without a form reported", noted("exactly one of"), true)
eq("rule with two forms reported", noted("exactly one of") and noted("rule 3"), true)
eq("rule without group reported", noted("group name at [1]"), true)
eq("undelimitable pattern reported", noted("no delimiter"), true)
eq("region without end reported", noted("start and end"), true)

local partial_lines = { "yes no" }
open_buffer(partial_lines, "partial")
eq("good rule survives bad siblings", group_at(partial_lines, 1, "yes"), "pGood")
eq("partial buffer marked", vim.b.current_syntax, "partial")

-- case = "ignore" keywords, delimiter fallback for patterns holding '"',
-- buffer-local options, and detection registration
syntax.setup({ langs = {
    {
        filetype = "fakelang",
        extensions = { "fkl" },
        filenames = { "Fakefile" },
        case = "ignore",
        options = { commentstring = "; %s" },
        rules = {
            { "fakeString", link = "String", region = { [[']], [[']] } },
            { "fakeKw", link = "Keyword", keywords = { "BEGIN" } },
            { "fakeQuoted", link = "Constant", match = [["quoted"]] },
        },
    },
} })
eq("extension detected", vim.filetype.match({ filename = "t.fkl" }), "fakelang")
eq("filename detected", vim.filetype.match({ filename = "Fakefile" }), "fakelang")

local fake_lines = { [[begin "quoted" 'str']] }
open_buffer(fake_lines, "fakelang")
eq("case-ignore keyword", group_at(fake_lines, 1, "begin"), "fakeKw")
eq("quote-holding pattern delimited", group_at(fake_lines, 1, '"quoted"'), "fakeQuoted")
eq("region rule", group_at(fake_lines, 1, "'str'", 1), "fakeString")
eq("options applied", vim.bo.commentstring, "; %s")
eq("link registered", vim.api.nvim_get_hl(0, { name = "fakeKw" }).link, "Keyword")

-- a buffer that already has b:current_syntax (a dedicated plugin got there
-- first) is left alone
local claimed_lines = { "begin" }
local buf = vim.api.nvim_create_buf(true, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, claimed_lines)
vim.b.current_syntax = "elsewhere"
vim.bo.filetype = "fakelang"
drain()
eq("claimed buffer untouched", group_at(claimed_lines, 1, "begin"), "")
eq("claimed marker kept", vim.b.current_syntax, "elsewhere")

-- load_dir: *.lua files sorted, broken ones reported, other files ignored
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, "p")
local function write(name, text)
    local f = assert(io.open(fixture .. "/" .. name, "w"))
    f:write(text)
    f:close()
end
write("good.lua", 'return { filetype = "goodlang" }')
write("broken.lua", 'error("kaboom")')
write("nottable.lua", "return 42")
write("readme.txt", "not lua")

notes = {}
vim.notify = function(msg) notes[#notes + 1] = msg end
local entries = syntax.load_dir(fixture)
vim.notify = saved_notify
eq("load_dir entry count", #entries, 2)
eq("load_dir sorted first", entries[1].source, "good.lua")
eq("load_dir keeps non-table returns", entries[2].source, "nottable.lua")
eq("load_dir reports broken file", noted("kaboom"), true)
eq("load_dir on missing dir", #syntax.load_dir(fixture .. "/absent"), 0)

-- setup() scans M.langs_dir; a repointed dir feeds specs through the same
-- validation as inline ones
local saved_dir = syntax.langs_dir
syntax.langs_dir = fixture
notes = {}
vim.notify = function(msg) notes[#notes + 1] = msg end
syntax.setup()
vim.notify = saved_notify
syntax.langs_dir = saved_dir
eq("scanned non-table spec reported", noted("nottable.lua") and noted("filetype string"), true)
vim.fn.delete(fixture, "rf")

-- the shipped langs: HolyC
syntax.setup()
eq("HC detected", vim.filetype.match({ filename = "Doc.HC" }), "holyc")
eq("hc detected", vim.filetype.match({ filename = "prog.hc" }), "holyc")
eq("plain C untouched", vim.filetype.match({ filename = "main.c" }), "c")

local holyc = {
    [[// line comment TODO mov RAX]],
    [[/* block comment 42 */]],
    [[#include "KernelA.HH"]],
    [[U0 Main(I64 count)]],
    [[{]],
    [[    I64 x = 0x1F + 42;]],
    [[    F64 f = 1.5;]],
    [[    U8 *msg = "if \" 42 //x";]],
    [[    if (x > 5 && TRUE) {]],
    [[        MOV RAX, 5]],
    [[        mov DX, 2]],
    [[    }]],
    [[    return;]],
    [[}]],
}
open_buffer(holyc, "holyc")
eq("holyc marked", vim.b.current_syntax, "holyc")
eq("holyc commentstring", vim.bo.commentstring, "// %s")

-- comments beat the operator match (the ordering fix over the reference)
eq("line comment slashes", group_at(holyc, 1, "//"), "holycComment")
eq("todo in comment", group_at(holyc, 1, "TODO"), "holycTodo")
eq("register inside comment stays comment", group_at(holyc, 1, "RAX"), "holycComment")
eq("block comment open", group_at(holyc, 2, "/*"), "holycComment")
eq("number inside block comment", group_at(holyc, 2, "42"), "holycComment")

eq("preproc line", group_at(holyc, 3, "#include"), "holycPreProc")
eq("preproc swallows its string", group_at(holyc, 3, "KernelA"), "holycPreProc")

eq("return type", group_at(holyc, 4, "U0"), "holycType")
eq("type translates to Type", vim.fn.synIDattr(vim.fn.synIDtrans(vim.fn.synID(4,
    holyc[4]:find("U0"), 1)), "name"), "Type")
eq("function name unhighlighted", group_at(holyc, 4, "Main"), "")
eq("parameter type", group_at(holyc, 4, "I64"), "holycType")
eq("paren", group_at(holyc, 4, "("), "holycPunctuation")

eq("hex literal", group_at(holyc, 6, "0x1F"), "holycNumber")
eq("decimal literal", group_at(holyc, 6, "42"), "holycNumber")
eq("plus operator", group_at(holyc, 6, "+"), "holycOperator")
eq("assignment operator", group_at(holyc, 6, "="), "holycOperator")
eq("semicolon", group_at(holyc, 6, ";"), "holycPunctuation")
eq("float literal dot", group_at(holyc, 7, "1.5", 1), "holycNumber")

eq("string open", group_at(holyc, 8, '"if'), "holycString")
eq("keyword inside string stays string", group_at(holyc, 8, "if \\"), "holycString")
eq("escaped quote stays string", group_at(holyc, 8, [[\"]], 1), "holycString")
eq("slashes inside string stay string", group_at(holyc, 8, "//x"), "holycString")
eq("pointer star", group_at(holyc, 8, "*"), "holycOperator")

eq("if keyword", group_at(holyc, 9, "if"), "holycKeyword")
eq("and operator", group_at(holyc, 9, "&&"), "holycOperator")
eq("TRUE constant", group_at(holyc, 9, "TRUE"), "holycConstant")

eq("asm mnemonic", group_at(holyc, 10, "MOV"), "holycBuiltin")
eq("register", group_at(holyc, 10, "RAX"), "holycRegister")
eq("case-sensitive mnemonic", group_at(holyc, 11, "mov"), "")
eq("short register", group_at(holyc, 11, "DX"), "holycRegister")
eq("return keyword", group_at(holyc, 13, "return"), "holycKeyword")

-- a second holyc buffer gets its own application
local second = { [[I64 n = 7;]] }
open_buffer(second, "holyc")
eq("second buffer type", group_at(second, 1, "I64"), "holycType")
eq("second buffer marked", vim.b.current_syntax, "holyc")

if failures > 0 then
    print("FAILURES: " .. failures)
    os.exit(1)
end
print("ALL SYNTAX TESTS PASSED")
