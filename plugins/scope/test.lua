-- lua/neo/plugins/scope/test.lua
-- Run from anywhere: nvim -l path/to/plugins/scope/test.lua
local here = debug.getinfo(1, "S").source:sub(2):match("(.*)[/\\]")
local scope = dofile(here .. "/init.lua")
local parse = scope._parse_grep_line
local fuzzy = scope._fuzzy_score

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
eq("fuzzy empty pattern", fuzzy("anything", ""), 1)
eq("fuzzy no match", fuzzy("main.c", "xyz"), 0)
assert(fuzzy("src/app/main.py", "mainpy") > 0, "subsequence must match")
assert(fuzzy("config.lua", "conf") > fuzzy("src/config.lua", "conf"),
    "shorter path must outrank longer on the same match")
assert(fuzzy(string.rep("abcdefghij/", 30) .. "z.txt", "z") > 0,
    "match in a long path must stay positive")

if failures > 0 then
    print("FAILURES: " .. failures)
    os.exit(1)
end
print("ALL SCOPE TESTS PASSED")
