-- lua/neo/plugins/keel/tests/flow.lua
-- Whole workflows, and the repository shapes that break naive Git tools.
local function all_notes(c)
    return c.lua([[return table.concat(notes, "\n")]])
end

return function(t)
    t.child(function(c) -- the daily loop, start to finish
        local repo = t.repo({ f = "a\nb\nc\nd\n" })
        local bare = repo .. "-remote.git"
        vim.fn.mkdir(bare, "p")
        t.git(bare, "init", "-q", "--bare")
        t.git(repo, "remote", "add", "origin", bare)
        t.git(repo, "push", "-qu", "origin", "main")
        t.write(repo, "f", "a\nKEEP\nb\nc\nLATER\nd\n")
        c.open(repo)

        c.jump("M f")
        c.keys("<Tab>")
        c.jump("+KEEP")
        c.keys("V")
        c.keys("s")
        c.keys("cc")
        c.keys("Add the keeper")
        c.keys("<C-c><C-c>")
        t.eq("commit holds only the selected line",
            t.git(repo, "show", "HEAD:f"), "a\nKEEP\nb\nc\nd\n")
        t.eq("the other change is still there", t.read(repo, "f"), "a\nKEEP\nb\nc\nLATER\nd\n")
        t.ok("still listed as unstaged", c.has("Unstaged changes (1)"))

        c.keys("ca")
        c.keys("A, amended<Esc>")
        c.keys("<C-c><C-c>")
        t.eq("amended", vim.trim(t.git(repo, "log", "-1", "--format=%s")), "Add the keeper, amended")

        c.keys("b")
        c.lua("vim.wait(80)")
        c.keys("topic")
        c.lua("vim.wait(120)")
        c.keys("<C-n>")
        c.lua("vim.wait(50)")
        c.settle()
        t.eq("on the new branch", vim.trim(t.git(repo, "branch", "--show-current")), "topic")

        c.keys("P")
        c.keys("y")
        t.eq("published", vim.trim(t.git(bare, "log", "-1", "--format=%s", "topic")), "Add the keeper, amended")
        t.eq("uncommitted work survived it all", t.read(repo, "f"), "a\nKEEP\nb\nc\nLATER\nd\n")
    end)

    t.child(function(c) -- staging quickly can't apply a patch twice
        local repo = t.repo({ f = "x\nx\nx\nx\nx\nx\nx\nx\n" })
        t.write(repo, "f", "x\nx\nnew\nx\nx\nx\nx\nx\nx\n")
        c.open(repo)
        c.jump("M f")
        c.keys("<Tab>")
        c.jump("+new")
        c.keys("ss")
        t.eq("the hunk applied once", t.index(repo, "f"), "x\nx\nnew\nx\nx\nx\nx\nx\nx\n")
        t.ok("the second press says why", all_notes(c):find("still updating", 1, true))
        c.jump("M f")
        c.keys("u")
        t.eq("actions work again afterward", t.index(repo, "f"), "x\nx\nx\nx\nx\nx\nx\nx\n")
    end)

    t.child(function(c) -- staging moves to the next file
        local repo = t.repo({ a = "1\n", b = "1\n", c = "1\n" })
        t.write(repo, "a", "2\n")
        t.write(repo, "b", "2\n")
        t.write(repo, "c", "2\n")
        c.open(repo)
        c.jump("M b")
        c.keys("s")
        t.ok("cursor lands on the next file", c.lua([[return vim.api.nvim_get_current_line()]]):find("M c", 1, true))
    end)

    t.child(function(c) -- the cursor stays on its line through a refresh
        local repo = t.repo({ f = "1\n2\n3\n" })
        t.write(repo, "f", "1\nTWO\n3\n")
        c.open(repo)
        c.jump("M f")
        c.keys("<Tab>")
        c.jump("+TWO")
        t.write(repo, "aaa-new.txt", "pushes everything down\n")
        c.keys("gr")
        t.eq("cursor follows its line", c.lua("return vim.api.nvim_get_current_line()"), "+TWO")
    end)

    t.child(function(c) -- renames
        local repo = t.repo({ ["old name.txt"] = "same\ncontent\nhere\n" })
        t.git(repo, "mv", "old name.txt", "new name.txt")
        c.open(repo)
        t.ok("shows both names", c.has("old name.txt -> new name.txt"))
        c.jump("R ")
        c.keys("u")
        local status = t.git(repo, "status", "--porcelain")
        t.ok("unstages the deletion", status:find(" D \"?old name", 1) or status:find("%sD old name"))
        t.ok("unstages the addition", status:find("?? \"?new name", 1) or status:find("%?%? new name"))
    end)

    t.child(function(c) -- from a subdirectory, with awkward names
        local repo = t.repo({ ["src/deep/my file é.txt"] = "1\n2\n" })
        t.write(repo, "src/deep/my file é.txt", "1\nTWO\n")
        c.lua([[vim.cmd("cd " .. vim.fn.fnameescape(...))]], repo .. "/src/deep")
        c.lua([[
            _G.notes = {}
            vim.notify = function(message) table.insert(notes, message) end
            require("neo.plugins.keel").setup()
            require("neo.plugins.keel").open()
        ]])
        c.settle()
        t.ok("finds the repository", c.has("M src/deep/my file é.txt"))
        c.jump("M src/deep")
        c.keys("<Tab>")
        t.ok("loads the diff", c.has("+TWO"))
        c.jump("+TWO")
        c.keys("s")
        t.eq("stages the right file", t.index(repo, "src/deep/my file é.txt"), "1\nTWO\n")
        c.jump("M src/deep")
        c.keys("<CR>")
        t.ok("opens the right file", c.lua("return vim.api.nvim_buf_get_name(0)"):find("my file é.txt", 1, true))
    end)

    t.child(function(c) -- a repository path with spaces
        local base = t.repo({ f = "1\n" })
        local spaced = t.tmp .. "/has spaces [1]"
        vim.fn.delete(spaced, "rf")
        t.git(t.tmp, "clone", "-q", base, spaced)
        t.write(spaced, "f", "2\n")
        c.open(spaced)
        c.jump("M f")
        c.keys("s")
        t.eq("works there", t.index(spaced, "f"), "2\n")
        c.keys("cc")
        c.keys("Spaced")
        c.keys("<C-c><C-c>")
        t.eq("commits there", vim.trim(t.git(spaced, "log", "-1", "--format=%s")), "Spaced")
    end)

    t.child(function(c) -- a linked worktree keeps its draft in its own git dir
        local repo = t.repo({ f = "1\n" })
        local linked = t.tmp .. "/linked-worktree"
        vim.fn.delete(linked, "rf")
        t.git(repo, "worktree", "add", "-q", "-b", "linked", linked)
        t.write(linked, "f", "2\n")
        t.git(linked, "add", "f")
        c.open(linked)
        c.keys("cc")
        c.keys("Worktree draft<Esc>")
        c.keys(":w<CR>")
        t.eq("draft in the worktree's git dir",
            t.read(repo, ".git/worktrees/linked-worktree/KEEL_COMMIT_DRAFT"), "Worktree draft\n")
        t.eq("not in the main one", t.read(repo, ".git/KEEL_COMMIT_DRAFT"), nil)
        c.keys("<C-c><C-c>")
        t.eq("commits on the worktree's branch",
            vim.trim(t.git(repo, "log", "-1", "--format=%s", "linked")), "Worktree draft")
        t.eq("main untouched", vim.trim(t.git(repo, "log", "-1", "--format=%s", "main")), "base")
    end)

    t.child(function(c) -- untracked directories
        local repo = t.repo({ f = "1\n" })
        t.write(repo, "newdir/inner.txt", "x\n")
        c.open(repo)
        c.jump("? newdir/")
        c.keys("<Tab>")
        t.ok("says what it is", c.has("(untracked directory)"))
        t.ok("isn't stuck loading", not c.has("(loading)"))
        c.jump("? newdir/")
        c.keys("s")
        t.eq("stages its contents", t.index(repo, "newdir/inner.txt"), "x\n")
    end)

    t.child(function(c) -- untracked file diffs are for reading
        local repo = t.repo({ f = "1\n" })
        t.write(repo, "fresh.txt", "one\ntwo\n")
        c.open(repo)
        c.jump("? fresh.txt")
        c.keys("<Tab>")
        t.ok("shows its content", c.has("+two"))
        c.jump("+two")
        c.keys("s")
        t.ok("explains line staging", all_notes(c):find("whole file", 1, true))
        t.ok("nothing staged", not c.has("Staged changes"))
    end)

    t.child(function(c) -- a huge diff doesn't flood the buffer
        local lines = {}
        for i = 1, 6000 do lines[i] = "line " .. i end
        local repo = t.repo({ big = "start\n" })
        t.write(repo, "big", table.concat(lines, "\n") .. "\n")
        c.open(repo)
        c.jump("M big")
        c.keys("<Tab>")
        t.ok("a placeholder instead", c.has("diff too large"))
        t.ok("the buffer stays small", #c.lines() < 50)
        c.jump("M big")
        c.keys("s")
        t.ok("the file still stages", c.has("Staged changes (1)"))
    end)

    t.child(function(c) -- open files follow a discard
        local repo = t.repo({ f = "old\n" })
        t.write(repo, "f", "new\n")
        c.lua([[vim.cmd("edit " .. vim.fn.fnameescape(...))]], repo .. "/f")
        local buf = c.lua("return vim.api.nvim_get_current_buf()")
        c.open(repo)
        c.jump("M f")
        c.keys("x")
        c.keys("y")
        c.lua("vim.wait(60)")
        t.eq("the open buffer reloads",
            c.lua("return vim.api.nvim_buf_get_lines(..., 0, -1, false)", buf), { "old" })
    end)

    t.child(function(c) -- not a repository
        local dir = t.tmp .. "/plain-dir"
        vim.fn.mkdir(dir, "p")
        c.lua([[
            vim.cmd("cd " .. vim.fn.fnameescape(...))
            _G.notes = {}
            vim.notify = function(message) table.insert(notes, message) end
            require("neo.plugins.keel").setup()
            vim.cmd("Keel")
        ]], dir)
        t.ok("says so", all_notes(c):find("not in a git repository", 1, true))
        t.ok("opens nothing", c.lua("return vim.bo.filetype") ~= "keelstatus")
    end)
end
