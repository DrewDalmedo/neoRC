-- lua/neo/plugins/keel/tests/patch.lua
-- Every patch is applied by real git to a real repository.
local parse = require("neo.plugins.keel.parse")
local patch = require("neo.plugins.keel.patch")

local function picked(hunk, text)
    for i, line in ipairs(hunk.lines) do
        if line:gsub("\r$", "") == text then return i end
    end
    error("no line " .. text)
end

local function apply(repo, text, ...)
    local args = { "git", "apply", "--recount", "--whitespace=nowarn" }
    vim.list_extend(args, { ... })
    args[#args + 1] = "-"
    return vim.system(args, { cwd = repo, stdin = text, text = false }):wait()
end

local function diff(t, repo, ...)
    local args = { "diff", "--no-ext-diff", "--no-color", "-U3" }
    vim.list_extend(args, { ... })
    return parse.diff(t.git(repo, unpack(args)))[1]
end

local CASES = {
    { name = "one of two additions", base = "a\nb\nc\nd\n", work = "a\nX\nb\nc\nY\nd\n", pick = "+X", want = "a\nX\nb\nc\nd\n" },
    { name = "a deletion only", base = "a\nb\nc\nd\n", work = "a\nc\nZ\nd\n", pick = "-b", want = "a\nc\nd\n" },
    { name = "half of a replacement", base = "a\nb\nc\n", work = "a\nB\nc\n", pick = "+B", want = "a\nb\nB\nc\n" },
    { name = "deletion before a missing newline", base = "a\nb", work = "a\nc\n", pick = "-b", want = "a\n" },
    { name = "CRLF file", base = "a\r\nb\r\nc\r\n", work = "a\r\nX\r\nb\r\nY\r\nc\r\n", pick = "+X", want = "a\r\nX\r\nb\r\nc\r\n" },
    { name = "autocrlf", autocrlf = true, base = "a\r\nb\r\nc\r\n", work = "a\r\nX\r\nb\r\nY\r\nc\r\n", pick = "+X", want = "a\nX\nb\nc\n" },
}

return function(t)
    for _, case in ipairs(CASES) do
        local repo = t.repo()
        if case.autocrlf then t.git(repo, "config", "core.autocrlf", "true") end
        t.write(repo, "f", case.base)
        t.git(repo, "add", "f")
        t.git(repo, "commit", "-qm", "base")
        t.write(repo, "f", case.work)
        local file = diff(t, repo, "--", "f")
        local index = picked(file.hunks[1], case.pick)
        local text = assert(patch.lines(file, file.hunks[1], index, index, false))
        local result = apply(repo, text, "--cached")
        t.eq("stage " .. case.name .. " applies", result.code, 0)
        t.eq("stage " .. case.name, t.index(repo, "f"), case.want)
        t.eq("worktree kept: " .. case.name, t.read(repo, "f"), case.work)
    end

    do -- unstaging one line of two
        local repo = t.repo({ f = "a\nb\nc\n" })
        t.write(repo, "f", "a\nX\nb\nY\nc\n")
        t.git(repo, "add", "f")
        local file = diff(t, repo, "--cached", "--", "f")
        local index = picked(file.hunks[1], "+X")
        local text = assert(patch.lines(file, file.hunks[1], index, index, true))
        t.eq("unstage applies", apply(repo, text, "--cached", "-R").code, 0)
        t.eq("unstage one line", t.index(repo, "f"), "a\nb\nY\nc\n")
        t.eq("unstage leaves the file", t.read(repo, "f"), "a\nX\nb\nY\nc\n")
    end

    do -- unstaging a deletion
        local repo = t.repo({ f = "a\nb\nc\nd\n" })
        t.write(repo, "f", "a\nd\n")
        t.git(repo, "add", "f")
        local file = diff(t, repo, "--cached", "--", "f")
        local index = picked(file.hunks[1], "-b")
        local text = assert(patch.lines(file, file.hunks[1], index, index, true))
        t.eq("unstage deletion applies", apply(repo, text, "--cached", "-R").code, 0)
        t.eq("unstage one deletion", t.index(repo, "f"), "a\nb\nd\n")
    end

    do -- discarding one line from the working tree
        local repo = t.repo({ f = "a\nb\nc\n" })
        t.write(repo, "f", "a\nX\nb\nY\nc\n")
        local file = diff(t, repo, "--", "f")
        local index = picked(file.hunks[1], "+X")
        local text = assert(patch.lines(file, file.hunks[1], index, index, true))
        t.eq("discard applies", apply(repo, text, "-R").code, 0)
        t.eq("discard one line", t.read(repo, "f"), "a\nb\nY\nc\n")
        t.eq("discard leaves the index", t.index(repo, "f"), "a\nb\nc\n")
    end

    do -- discarding in a CRLF working tree
        local repo = t.repo()
        t.git(repo, "config", "core.autocrlf", "true")
        t.write(repo, "f", "a\r\nb\r\nc\r\n")
        t.git(repo, "add", "f")
        t.git(repo, "commit", "-qm", "base")
        t.write(repo, "f", "a\r\nX\r\nb\r\nc\r\n")
        local file = diff(t, repo, "--", "f")
        local result = apply(repo, patch.hunk(file, file.hunks[1]), "-R")
        t.eq("autocrlf discard applies", result.code, 0)
        t.eq("autocrlf discard keeps CRLF", t.read(repo, "f"), "a\r\nb\r\nc\r\n")
    end

    do -- whole hunks, with another hunk left alone
        local lines = {}
        for i = 1, 30 do lines[i] = "l" .. i end
        local base = table.concat(lines, "\n") .. "\n"
        local repo = t.repo({ f = base })
        lines[3], lines[25] = "first", "second"
        t.write(repo, "f", table.concat(lines, "\n") .. "\n")
        local file = diff(t, repo, "--", "f")
        t.eq("two hunks to choose from", #file.hunks, 2)
        t.eq("second hunk applies", apply(repo, patch.hunk(file, file.hunks[2]), "--cached").code, 0)
        local index = t.index(repo, "f")
        t.ok("second hunk staged", index:find("second", 1, true))
        t.ok("first hunk left out", not index:find("first", 1, true))
    end

    -- A patch git would accept and apply wrongly must never be built.
    do
        local repo = t.repo({ f = "a\nb" })
        t.write(repo, "f", "a\nc\n")
        local file = diff(t, repo, "--", "f")
        local hunk = file.hunks[1]
        local add = picked(hunk, "+c")
        local text, why = patch.lines(file, hunk, add, add, false)
        t.eq("no patch glues lines together", text, nil)
        t.ok("says to use the whole hunk", why:find("whole hunk", 1, true))
        local whole = patch.hunk(file, hunk)
        t.eq("the whole hunk still applies", apply(repo, whole, "--cached").code, 0)
        t.eq("the whole hunk is right", t.index(repo, "f"), "a\nc\n")
    end

    do -- the same trap in reverse
        local repo = t.repo({ f = "a\nb" })
        t.write(repo, "f", "a\nc\n")
        t.git(repo, "add", "f")
        local file = diff(t, repo, "--cached", "--", "f")
        local hunk = file.hunks[1]
        local remove = picked(hunk, "-b")
        local text = patch.lines(file, hunk, remove, remove, true)
        t.eq("no reverse patch glues lines", text, nil)
    end

    do
        local repo = t.repo({ f = "a\nb\nc\n" })
        t.write(repo, "f", "a\nX\nb\nc\n")
        local file = diff(t, repo, "--", "f")
        local hunk = file.hunks[1]
        local context = picked(hunk, " a")
        local text, why = patch.lines(file, hunk, context, context, false)
        t.eq("context alone isn't a patch", text, nil)
        t.eq("and says so", why, "no changed lines selected")
    end
end
