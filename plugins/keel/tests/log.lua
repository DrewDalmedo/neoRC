-- lua/neo/plugins/keel/tests/log.lua
return function(t)
    t.child(function(c)
        local repo = t.repo({ f = "a\n" })
        t.write(repo, "f", "b\n")
        t.git(repo, "commit", "-qam", "second commit")
        c.open(repo)
        c.keys("l")
        c.lua("vim.wait(60)")
        t.eq("l opens the log", c.lua("return vim.bo.filetype"), "keellog")
        t.ok("lists the newest", c.lines()[1]:find("second commit", 1, true))
        t.ok("lists the oldest", c.lines()[2]:find("base", 1, true))
        t.ok("shows refs", c.lines()[1]:find("main", 1, true))

        c.keys("<CR>")
        c.lua("vim.wait(60)")
        t.eq("<CR> shows the commit", c.lua("return vim.bo.filetype"), "keelshow")
        t.ok("with its message", c.has("second commit"))
        t.ok("and its diff", c.has("+b"))
        t.eq("cursor at the top", c.lua([[return vim.fn.line(".")]]), 1)

        c.keys("q")
        t.eq("q returns to the log", c.lua("return vim.bo.filetype"), "keellog")
        c.keys("q")
        t.eq("q returns to status", c.lua("return vim.bo.filetype"), "keelstatus")

        c.jump("base")
        c.lua([[
            local rows = vim.api.nvim_buf_get_lines(0, 0, -1, false)
            for row = #rows, 1, -1 do
                if rows[row]:find("base", 1, true) then
                    vim.api.nvim_win_set_cursor(0, { row, 0 })
                    break
                end
            end
        ]])
        c.keys("<CR>")
        c.lua("vim.wait(60)")
        t.eq("a recent commit opens from status", c.lua("return vim.bo.filetype"), "keelshow")
        t.ok("it's the right commit", c.has("+a"))
        c.keys("q")
        t.eq("q returns to status again", c.lua("return vim.bo.filetype"), "keelstatus")
    end)

    t.child(function(c) -- stashes
        local repo = t.repo({ f = "a\n" })
        t.write(repo, "f", "stashed change\n")
        t.git(repo, "stash", "push", "-qm", "my stash")
        c.open(repo)
        t.ok("lists stashes", c.has("Stashes (1)"))
        t.ok("with the message", c.has("my stash"))
        c.jump("stash@{0}")
        c.keys("<CR>")
        c.lua("vim.wait(60)")
        t.eq("opens the stash", c.lua("return vim.bo.filetype"), "keelshow")
        t.ok("with its diff", c.has("+stashed change"))
        t.eq("showing it doesn't apply it", t.read(repo, "f"), "a\n")
    end)

    t.child(function(c) -- paging
        local repo = t.repo({ f = "0\n" })
        for i = 1, 205 do
            t.git(repo, "commit", "-q", "--allow-empty", "-m", "commit " .. i)
        end
        c.open(repo)
        c.keys("l")
        c.lua("vim.wait(120)")
        t.eq("first page", #c.lines(), 200)
        c.keys("+")
        c.lua("vim.wait(120)")
        t.eq("+ loads more", #c.lines(), 206)
    end)

    t.child(function(c) -- an empty repository
        local repo = t.repo()
        c.open(repo)
        c.keys("l")
        c.lua("vim.wait(60)")
        t.eq("no commits is a message", c.lines(), { "No commits yet" })
    end)
end
