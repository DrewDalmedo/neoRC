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

if failures > 0 then
    print("FAILURES: " .. failures)
    os.exit(1)
end
print("ALL SCOPE TESTS PASSED")
