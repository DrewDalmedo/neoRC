-- lua/neo/plugins/scope/test.lua
-- Run from anywhere: nvim -l path/to/plugins/scope/test.lua
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

local grep = require("neo.plugins.scope.grep")
local fuzzy = require("neo.plugins.picker.fuzzy")
local parse = grep.parse_line

local failures = 0
local function eq(desc, got, want)
    if got ~= want then
        failures = failures + 1
        print(("FAIL %s: got=%s want=%s"):format(desc, vim.inspect(got), vim.inspect(want)))
    else
        print("ok   " .. desc)
    end
end

-- rg --vimgrep: file:line:col:text
local f, l, c, t = parse('src/app/main.py:2:12:print("x")', true)
eq("rg file", f, "src/app/main.py")
eq("rg lnum", l, 2)
eq("rg col", c, 12)
eq("rg text", t, 'print("x")')

-- text containing colon-number pairs must split at the first field boundary
f, l, c, t = parse("a.c:5:3:t[3]:9:x", true)
eq("colons in text file", f, "a.c")
eq("colons in text col", c, 3)
eq("colons in text text", t, "t[3]:9:x")

-- grep -rn / findstr: file:line:text, no column; leading ./ or .\ stripped
f, l, c, t = parse("./docs/readme.md:2:hello", false)
eq("grep file", f, "docs/readme.md")
eq("grep lnum", l, 2)
eq("grep default col", c, 1)
f, l, c, t = parse("a.c:12:34 lines follow", false)
eq("grep digit text file", f, "a.c")
eq("grep digit text", t, "34 lines follow")
f, l, c, t = parse([[src\app\main.py:2:print("x")]], false)
eq("findstr backslash file", f, [[src\app\main.py]])
f, l, c, t = parse([[.\sub\x.txt:4:y]], false)
eq("findstr dot prefix", f, [[sub\x.txt]])

-- absolute Windows paths: the drive colon must not confuse the split
f, l, c, t = parse([[C:\Users\drew\proj\x.txt:7:some text]], false)
eq("drive file", f, [[C:\Users\drew\proj\x.txt]])
eq("drive lnum", l, 7)
f, l, c, t = parse("C:/code/x.lua:3:9:local x", true)
eq("drive+col file", f, "C:/code/x.lua")
eq("drive+col col", c, 9)

-- junk lines are rejected
eq("garbage", parse("no line numbers here", false), nil)
eq("empty", parse("", false), nil)
eq("findstr warning line", parse("FINDSTR: Cannot open foo", false), nil)

-- fuzzy scorer contract
eq("fuzzy empty pattern", fuzzy.score("anything", ""), 1)
eq("fuzzy no match", fuzzy.score("main.c", "xyz"), 0)
assert(fuzzy.score("src/app/main.py", "mainpy") > 0, "subsequence must match")
assert(fuzzy.score("config.lua", "conf") > fuzzy.score("src/config.lua", "conf"),
    "shorter path must outrank longer on the same match")
assert(fuzzy.score(string.rep("abcdefghij/", 30) .. "z.txt", "z") > 0,
    "match in a long path must stay positive")

-- fuzzy.filter: the ranking pipeline the picker uses
local items = {
    { display = "src/config.lua" },
    { display = "config.lua" },
    { display = "README.md" },
}
local out = fuzzy.filter(items, "conf")
eq("filter drops non-matches", #out, 2)
eq("filter ranks shorter first", out[1].display, "config.lua")
out = fuzzy.filter(items, "")
eq("filter empty query keeps count", #out, 3)
eq("filter empty query keeps order", out[1].display, "src/config.lua")
out = fuzzy.filter(items, "conf", { limit = 1 })
eq("filter respects limit", #out, 1)
out = fuzzy.filter({ { name = "abc" }, { name = "xyz" } }, "b",
    { key = function(i) return i.name end })
eq("filter custom key count", #out, 1)
eq("filter custom key match", out[1].name, "abc")

-- gitignore rule semantics: M.match gives one rule list's verdict on a path
-- relative to the .gitignore's directory (true ignore / false negated / nil
-- no opinion)
local gitignore = require("neo.plugins.scope.gitignore")
local function ig(text, rel, is_dir)
    return gitignore.match(gitignore.parse(text), rel, is_dir or false)
end

eq("ig name", ig("foo", "foo"), true)
eq("ig name at depth", ig("foo", "a/b/foo"), true)
eq("ig name no substring", ig("foo", "foobar"), nil)
eq("ig star ext", ig("*.log", "x.log"), true)
eq("ig star ext deep", ig("*.log", "a/b/x.log"), true)
eq("ig star no dir cross", ig("*.log", "x.logs"), nil)
eq("ig dot is literal", ig("*.log", "xzlog"), nil)
eq("ig question", ig("?.txt", "a.txt"), true)
eq("ig question one char", ig("?.txt", "ab.txt"), nil)
eq("ig class", ig("[abc].txt", "b.txt"), true)
eq("ig class miss", ig("[abc].txt", "d.txt"), nil)
eq("ig class range", ig("[a-c].txt", "b.txt"), true)
eq("ig negated class", ig("[!a].txt", "b.txt"), true)
eq("ig negated class miss", ig("[!a].txt", "a.txt"), nil)
eq("ig anchored root", ig("/build", "build"), true)
eq("ig anchored not deep", ig("/build", "src/build"), nil)
eq("ig inner slash anchors", ig("doc/frotz", "doc/frotz"), true)
eq("ig inner slash not deep", ig("doc/frotz", "a/doc/frotz"), nil)
eq("ig dir only on dir", ig("build/", "build", true), true)
eq("ig dir only on file", ig("build/", "build", false), nil)
eq("ig doublestar lead", ig("**/foo", "a/b/foo"), true)
eq("ig doublestar mid zero dirs", ig("a/**/b", "a/b"), true)
eq("ig doublestar mid deep", ig("a/**/b", "a/x/y/b"), true)
eq("ig doublestar tail", ig("foo/**", "foo/x/y"), true)
eq("ig doublestar tail not itself", ig("foo/**", "foo", true), nil)
eq("ig negation last wins", ig("*.log\n!keep.log", "keep.log"), false)
eq("ig negation order matters", ig("!keep.log\n*.log", "keep.log"), true)
eq("ig comment", ig("#foo", "foo"), nil)
eq("ig escaped hash", ig("\\#foo", "#foo"), true)
eq("ig trailing space stripped", ig("foo ", "foo"), true)
eq("ig blank lines skipped", ig("\n\nfoo\n\n", "foo"), true)
eq("ig crlf endings", ig("a.log\r\nb.log\r\n", "b.log"), true)
eq("ig lua magic literal", ig("a+b(1).txt", "a+b(1).txt"), true)
eq("ig percent literal", ig("100%.txt", "100%.txt"), true)

-- nested .gitignore files against a real tree: the checker (used by the
-- grep fallbacks) and the file scan must agree with git's precedence
local root = vim.fn.tempname():gsub("\\", "/")
vim.fn.mkdir(root .. "/src/generated", "p")
vim.fn.mkdir(root .. "/build", "p")
local function write_file(rel, text)
    local f = assert(io.open(root .. "/" .. rel, "w"))
    f:write(text)
    f:close()
end
write_file(".gitignore", "*.log\n!keep.log\n/build\n")
write_file("src/.gitignore", "generated/\n!important.log\n")
write_file("keep.log", "needle keep\n")
write_file("x.log", "needle x\n")
write_file("build/out.txt", "needle out\n")
write_file("src/main.c", "needle main\n")
write_file("src/other.log", "needle other\n")
write_file("src/important.log", "needle important\n")
write_file("src/generated/a.txt", "needle gen\n")

local check = gitignore.checker(root)
eq("checker keeps plain file", check("src/main.c"), false)
eq("checker root pattern", check("x.log"), true)
eq("checker root pattern deep", check("src/other.log"), true)
eq("checker negation", check("keep.log"), false)
eq("checker nested negation beats outer", check("src/important.log"), false)
eq("checker nested dir rule", check("src/generated/a.txt"), true)
eq("checker anchored dir contents", check("build/out.txt"), true)
eq("checker windows separators", check("src\\other.log"), true)
eq("checker absolute path passes", check("/etc/hosts"), false)

-- the file scan applies the same rules and prunes ignored directories
local files = require("neo.plugins.scope.files")
local got, scan_done = {}, false
files.scan_async({ cwd = root }, function(chunk)
    for _, rel in ipairs(chunk) do got[#got + 1] = rel end
end, function() scan_done = true end)
vim.wait(2000, function() return scan_done end)
eq("scan completed", scan_done, true)
table.sort(got)
eq("scan result", table.concat(got, " "),
    ".gitignore keep.log src/.gitignore src/important.log src/main.c")

-- live grep on the same tree: rg filters natively (--no-require-git makes
-- that hold outside git repos too); grep/findstr go through opts.ignored
local hits = {}
local handle = grep.run("needle", { cwd = root, ignored = gitignore.checker(root) },
    function(file) hits[#hits + 1] = (file:gsub("\\", "/")) end)
vim.wait(4000, function() return handle.stopped end)
eq("grep run finished", handle.stopped, true)
table.sort(hits)
eq("grep run hits", table.concat(hits, " "), "keep.log src/important.log src/main.c")

vim.fn.delete(root, "rf")

-- only rg is trusted to enforce .gitignore itself
local cmd, _, native_ignore = grep.build_cmd("q")
eq("native ignore only for rg", native_ignore, cmd[1] == "rg")
if cmd[1] == "rg" then
    eq("rg ignores outside git repos too", vim.tbl_contains(cmd, "--no-require-git"), true)
end

if failures > 0 then
    print("FAILURES: " .. failures)
    os.exit(1)
end
print("ALL SCOPE TESTS PASSED")
