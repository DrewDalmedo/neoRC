-- lua/neo/plugins/keel/tests/status.lua
-- Drives the status view with real keystrokes against real repositories.
return function(t)
    t.child(function(c)
        local repo = t.repo({ ["tracked.txt"] = "one\ntwo\nthree\n", ["other.txt"] = "x\n" })
        t.write(repo, "tracked.txt", "one\nTWO\nthree\n")
        t.write(repo, "new file.txt", "fresh\n")
        c.open(repo)
        t.ok("shows the branch", c.has("Head:     main  base"))
        t.ok("shows untracked", c.has("Untracked files (1)"))
        t.ok("shows the untracked path", c.has("? new file.txt"))
        t.ok("shows unstaged", c.has("Unstaged changes (1)"))
        t.ok("shows recent commits", c.has("Recent commits (1)"))
        t.eq("buffer can't be edited", c.lua("return vim.bo.modifiable"), false)

        c.jump("M tracked.txt")
        c.keys("<Tab>")
        t.ok("Tab shows the diff", c.has("+TWO"))
        t.ok("Tab shows the hunk", c.has("@@ -1,3 +1,3 @@"))
        c.keys("<Tab>")
        t.ok("Tab hides the diff", not c.has("+TWO"))

        c.jump("Unstaged changes")
        c.keys("<Tab>")
        t.ok("Tab collapses a section", not c.has("M tracked.txt"))
        c.keys("<Tab>")
        t.ok("Tab reopens it", c.has("M tracked.txt"))

        c.jump("M tracked.txt")
        c.keys("s")
        t.eq("s stages a file", t.index(repo, "tracked.txt"), "one\nTWO\nthree\n")
        t.ok("it moves to staged", c.has("Staged changes (1)"))
        t.ok("unstaged is gone", not c.has("Unstaged changes"))

        c.jump("M tracked.txt")
        c.keys("u")
        t.eq("u unstages a file", t.index(repo, "tracked.txt"), "one\ntwo\nthree\n")
        t.ok("back in unstaged", c.has("Unstaged changes (1)"))

        c.jump("? new file.txt")
        c.keys("s")
        t.eq("s adds an untracked file", t.index(repo, "new file.txt"), "fresh\n")

        c.keys("U")
        t.ok("U unstages everything", not c.has("Staged changes"))
        c.keys("S")
        t.eq("S stages tracked changes", t.index(repo, "tracked.txt"), "one\nTWO\nthree\n")
        t.ok("S leaves untracked alone", c.has("? new file.txt"))
    end)

    t.child(function(c) -- hunks and lines
        local repo = t.repo({ f = "a\nb\nc\nd\n" })
        t.write(repo, "f", "a\nX\nb\nc\nY\nd\n")
        c.open(repo)
        c.jump("M f")
        c.keys("<Tab>")

        c.jump("+X")
        c.keys("V")
        c.keys("s")
        c.settle()
        t.eq("Visual s leaves Visual", c.mode(), "n")
        t.eq("Visual s stages only that line", t.index(repo, "f"), "a\nX\nb\nc\nd\n")
        t.eq("the file keeps both lines", t.read(repo, "f"), "a\nX\nb\nc\nY\nd\n")
        t.ok("open diff stays open", c.has("+Y"))

        c.jump("Staged changes")
        c.jump("M f")
        c.lua([[
            local rows = vim.api.nvim_buf_get_lines(0, 0, -1, false)
            for row = #rows, 1, -1 do
                if rows[row]:find("M f", 1, true) then
                    vim.api.nvim_win_set_cursor(0, { row, 0 })
                    break
                end
            end
        ]])
        c.keys("<Tab>")
        c.lua([[
            local rows = vim.api.nvim_buf_get_lines(0, 0, -1, false)
            for row = #rows, 1, -1 do
                if rows[row] == "+X" then
                    vim.api.nvim_win_set_cursor(0, { row, 0 })
                    break
                end
            end
        ]])
        c.keys("u")
        t.eq("u on a line unstages its hunk", t.index(repo, "f"), "a\nb\nc\nd\n")
    end)

    t.child(function(c) -- a refresh during a selection acts on what was selected
        local repo = t.repo({ f = "a\nb\nc\nd\n" })
        t.write(repo, "f", "a\nX\nb\nc\nY\nd\n")
        c.open(repo)
        c.jump("M f")
        c.keys("<Tab>")
        local row = c.jump("+Y")
        c.keys("V")
        t.write(repo, "brand new.txt", "shifts every row\n")
        c.lua([[require("neo.plugins.keel.status").refresh(vim.fn.getcwd())]])
        c.settle()
        t.eq("still in Visual", c.mode(), "V")
        t.eq("selection stays put", c.lua([[return vim.fn.line("v")]]), row)
        t.ok("held refresh hasn't drawn", not c.has("brand new.txt"))
        c.keys("s")
        c.settle()
        t.eq("stages the selected line", t.index(repo, "f"), "a\nb\nc\nY\nd\n")
        t.ok("refresh lands afterward", c.has("brand new.txt"))
    end)

    t.child(function(c) -- discard asks first, and No means no
        local repo = t.repo({ f = "a\nb\n" })
        t.write(repo, "f", "a\nCHANGED\n")
        t.write(repo, "junk.txt", "junk\n")
        c.open(repo)

        c.jump("M f")
        c.keys("x")
        t.eq("discard opens a confirm", c.lua("return vim.bo.filetype"), "malleable_confirm")
        c.keys("<CR>")
        t.eq("<CR> keeps the change", t.read(repo, "f"), "a\nCHANGED\n")

        c.jump("M f")
        c.keys("x")
        c.keys("n")
        t.eq("n keeps the change", t.read(repo, "f"), "a\nCHANGED\n")

        c.jump("M f")
        c.keys("x")
        c.keys("y")
        t.eq("y discards", t.read(repo, "f"), "a\nb\n")
        t.ok("it leaves the view", not c.has("Unstaged changes"))

        c.jump("? junk.txt")
        c.keys("x")
        t.ok("untracked confirm says delete", c.has("Permanently delete"))
        c.keys("<Esc>")
        t.eq("<Esc> keeps the file", t.read(repo, "junk.txt"), "junk\n")
        c.jump("? junk.txt")
        c.keys("x")
        c.keys("y")
        t.eq("y deletes the untracked file", t.read(repo, "junk.txt"), nil)
    end)

    t.child(function(c) -- one hunk of a file, discarded from a line
        local lines = {}
        for i = 1, 30 do lines[i] = "l" .. i end
        local repo = t.repo({ f = table.concat(lines, "\n") .. "\n" })
        lines[3], lines[25] = "first", "second"
        t.write(repo, "f", table.concat(lines, "\n") .. "\n")
        c.open(repo)
        c.jump("M f")
        c.keys("<Tab>")
        c.jump("+second")
        c.keys("x")
        c.keys("y")
        local text = t.read(repo, "f")
        t.ok("first hunk survives", text:find("first", 1, true))
        t.ok("second hunk discarded", not text:find("second", 1, true))
    end)

    t.child(function(c) -- paths that look like patterns are only paths
        local repo = t.repo({ ["a.txt"] = "1\n", ["*.txt"] = "2\n" })
        t.write(repo, "a.txt", "changed\n")
        t.write(repo, "*.txt", "changed\n")
        c.open(repo)
        c.jump("M *.txt")
        c.keys("s")
        t.eq("the literal file is staged", t.index(repo, "*.txt"), "changed\n")
        t.eq("a pattern match isn't", t.index(repo, "a.txt"), "1\n")
    end)

    t.child(function(c) -- edge cases that must not break the view
        local repo = t.repo({ ["img.bin"] = "a\0b\n", gone = "x\n" })
        t.write(repo, "img.bin", "c\0d\n")
        vim.fn.delete(repo .. "/gone")
        c.open(repo)
        c.jump("M img.bin")
        c.keys("<Tab>")
        t.ok("binary file noted", c.has("(binary file)"))
        c.jump("D gone")
        c.keys("<CR>")
        t.ok("deleted file can't open", c.lua([[
            return table.concat(notes, "\n"):find("no such file", 1, true) ~= nil
        ]]))
        c.keys("s")
        t.ok("a deleted file stages", c.has("Staged changes"))
    end)

    t.child(function(c) -- no commits yet
        local repo = t.repo()
        t.write(repo, "first.txt", "hello\n")
        c.open(repo)
        t.ok("unborn branch shows", c.has("(no commits yet)"))
        c.jump("? first.txt")
        c.keys("s")
        t.ok("staging works", c.has("Staged changes (1)"))
        c.keys("U")
        t.ok("unstage all works", not c.has("Staged changes"))
    end)

    t.child(function(c) -- a merge in progress
        local repo = t.repo({ f = "base\n" })
        t.git(repo, "switch", "-qc", "other")
        t.write(repo, "f", "theirs\n")
        t.git(repo, "commit", "-qam", "theirs")
        t.git(repo, "switch", "-q", "main")
        t.write(repo, "f", "ours\n")
        t.git(repo, "commit", "-qam", "ours")
        vim.system({ "git", "merge", "other" }, { cwd = repo }):wait()
        c.open(repo)
        t.ok("merge banner", c.has("Merging: finish or abort it with git"))
        t.ok("conflict listed", c.has("Conflicts (1)"))
        c.jump("UU f")
        c.keys("s")
        t.ok("won't mark it resolved", c.has("UU f"))
    end)

    t.child(function(c) -- leaving and coming back
        local repo = t.repo({ f = "a\n" })
        c.lua([[vim.cmd("edit " .. vim.fn.fnameescape(...))]], repo .. "/f")
        local file_buf = c.lua("return vim.api.nvim_get_current_buf()")
        c.open(repo)
        t.ok("q has somewhere to go", c.lua("return vim.bo.filetype") == "keelstatus")
        c.keys("q")
        t.eq("q returns to the file", c.lua("return vim.api.nvim_get_current_buf()"), file_buf)
        t.write(repo, "f", "changed\n")
        c.lua([[require("neo.plugins.keel").open()]])
        c.settle()
        t.ok("reopening refreshes", c.has("M f"))
    end)

    t.child(function(c) -- help
        local repo = t.repo({ f = "a\n" })
        c.open(repo)
        c.keys("g?")
        t.eq("g? opens help", c.lua("return vim.bo.filetype"), "malleable_help")
        t.ok("help lists Stage", c.has("Stage"))
        c.keys("q")
        t.eq("q closes help", c.lua("return vim.bo.filetype"), "keelstatus")
    end)
end
