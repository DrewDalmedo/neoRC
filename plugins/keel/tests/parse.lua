-- lua/neo/plugins/keel/tests/parse.lua
local parse = require("neo.plugins.keel.parse")

local function z(...)
    return table.concat({ ... }, "\0") .. "\0"
end

local H = "000000 100644 100644 100644 aaaa bbbb"

return function(t)
    do
        local s = parse.status(z(
            "# branch.oid 1234567890",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -3",
            "1 M. N... 100644 100644 100644 aaaa bbbb staged.txt",
            "1 .M N... 100644 100644 100644 aaaa bbbb has space.txt",
            "1 MM N... 100644 100644 100644 aaaa bbbb both.txt",
            "1 .D N... 100644 100644 000000 aaaa bbbb gone.txt",
            "1 .M S.M. 160000 160000 160000 aaaa bbbb vendored",
            "2 R. N... 100644 100644 100644 aaaa bbbb R100 new name.txt",
            "old name.txt",
            "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc conflict file.txt",
            "? untracked é.txt",
            "? dir/"
        ))
        t.eq("branch", s.head, "main")
        t.eq("upstream", s.upstream, "origin/main")
        t.eq("ahead", s.ahead, 2)
        t.eq("behind", s.behind, 3)
        t.eq("not detached", s.detached, false)
        t.eq("staged paths", vim.tbl_map(function(e) return e.path end, s.staged),
            { "staged.txt", "both.txt", "new name.txt" })
        t.eq("unstaged paths", vim.tbl_map(function(e) return e.path end, s.unstaged),
            { "has space.txt", "both.txt", "gone.txt", "vendored" })
        t.eq("rename keeps the old path", s.staged[3].orig, "old name.txt")
        t.eq("rename status", s.staged[3].status, "R")
        t.eq("deleted status", s.unstaged[3].status, "D")
        t.eq("submodule noticed", s.unstaged[4].submodule, true)
        t.eq("conflict path", s.conflicted[1].path, "conflict file.txt")
        t.eq("conflict status", s.conflicted[1].status, "UU")
        t.eq("untracked keeps unicode", s.untracked[1].path, "untracked é.txt")
        t.eq("untracked directory", s.untracked[2].path, "dir/")
    end

    do
        local s = parse.status(z("# branch.oid (initial)", "# branch.head main"))
        t.eq("unborn branch", s.unborn, true)
        t.eq("no upstream", s.upstream, nil)
        local d = parse.status(z("# branch.oid abc", "# branch.head (detached)"))
        t.eq("detached head", d.detached, true)
    end

    do
        local files = parse.diff(table.concat({
            "diff --git a/f b/f",
            "index 111..222 100644",
            "--- a/f",
            "+++ b/f",
            "@@ -1,3 +1,4 @@ context here",
            " one",
            "+two\r",
            " three",
            "@@ -10 +11,0 @@",
            "-ten",
            "\\ No newline at end of file",
            "diff --git a/img b/img",
            "index 333..444 100644",
            "Binary files a/img and b/img differ",
            "",
        }, "\n"))
        t.eq("two files", #files, 2)
        t.eq("header kept", #files[1].header, 4)
        t.eq("two hunks", #files[1].hunks, 2)
        local h = files[1].hunks[1]
        t.eq("hunk starts", { h.old_start, h.old_count, h.new_start, h.new_count }, { 1, 3, 1, 4 })
        t.eq("hunk keeps bytes", h.lines[2], "+two\r")
        local h2 = files[1].hunks[2]
        t.eq("omitted count is 1", { h2.old_start, h2.old_count, h2.new_start, h2.new_count }, { 10, 1, 11, 0 })
        t.eq("newline marker kept", h2.lines[2], "\\ No newline at end of file")
        t.eq("line count", files[1].line_count, 5)
        t.eq("binary file", files[2].binary, true)
        t.eq("binary has no hunks", #files[2].hunks, 0)
        t.eq("empty diff", parse.diff(""), {})
    end

    do
        local c = parse.commits("aaa\0a\0Ann\0today\0HEAD -> main\0first subject\30\nbbb\0b\0Bo\0then\0\0\30\n")
        t.eq("two commits", #c, 2)
        t.eq("commit fields", { c[1].hash, c[1].short, c[1].author, c[1].refs, c[1].subject },
            { "aaa", "a", "Ann", "HEAD -> main", "first subject" })
        t.eq("empty fields survive", { c[2].refs, c[2].subject }, { "", "" })
        local s = parse.stashes("stash@{0}\0WIP on main\30\n")
        t.eq("stash", { s[1].ref, s[1].subject }, { "stash@{0}", "WIP on main" })
    end
    local _ = H
end
