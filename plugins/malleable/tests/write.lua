-- lua/neo/plugins/malleable/tests/write.lua
local malleable = require("neo.plugins.malleable")

local count = 0

-- An editable view in the current window, holding "saved" plus one edit.
local function dirty(on_write)
    count = count + 1
    local view = malleable.open({
        name = "malltest://write/" .. count,
        editable = true,
        on_write = on_write,
    })
    view:replace({ "saved" })
    vim.api.nvim_set_current_buf(view.buf)
    vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, { "edited" })
    return view
end

local function get(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function read(path)
    return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or nil
end

return function(t)
    local real_notify = vim.notify
    local notes = {}
    vim.notify = function(message) notes[#notes + 1] = message end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")

    do
        local calls = 0
        local view = dirty(function(v, done)
            calls = calls + 1
            t.ok("on_write gets the view", v.buf == vim.api.nvim_get_current_buf())
            t.eq("done(true) reports saved", done(true), true)
            t.eq("a second done is ignored", done(false), false)
        end)
        vim.cmd("write")
        t.eq(":w runs on_write", calls, 1)
        t.eq("done(true) clears modified", vim.bo[view.buf].modified, false)
        t.eq("text unchanged by a save", get(view.buf), { "edited" })
    end

    do
        local view = dirty(function(_, done) done(true) end)
        vim.cmd("split")
        local before = #vim.api.nvim_list_wins()
        vim.cmd("wq")
        t.eq("synchronous save lets :wq close", #vim.api.nvim_list_wins(), before - 1)
        t.eq(":wq leaves it saved", vim.bo[view.buf].modified, false)
    end

    do
        local view = dirty(function(_, done) t.eq("done(false) returns false", done(false), false) end)
        pcall(vim.cmd, "write")
        t.eq("failed write keeps text", get(view.buf), { "edited" })
        t.eq("failed write keeps modified", vim.bo[view.buf].modified, true)
    end

    do
        local calls, finish = 0, nil
        local view = dirty(function(_, done)
            calls = calls + 1
            finish = done
        end)
        vim.cmd("split")
        local before = #vim.api.nvim_list_wins()
        pcall(vim.cmd, "write")
        t.eq("pending write keeps modified", vim.bo[view.buf].modified, true)
        pcall(vim.cmd, "write")
        t.eq("second :w doesn't run on_write", calls, 1)
        pcall(vim.cmd, "wq")
        t.eq("pending :wq doesn't run on_write", calls, 1)
        t.eq("pending :wq leaves the window", #vim.api.nvim_list_wins(), before)
        t.eq("async done(true) saves", finish(true), true)
        t.eq("async done clears modified", vim.bo[view.buf].modified, false)
        pcall(vim.cmd, "write")
        t.eq("a later :w runs again", calls, 2)
        finish(false)
        vim.cmd("silent! only")
    end

    do
        local finish
        local view = dirty(function(_, done) finish = done end)
        pcall(vim.cmd, "write")
        vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, { "typed during the write" })
        t.eq("done(true) refuses after new edits", finish(true), false)
        t.eq("new edits stay unsaved", vim.bo[view.buf].modified, true)
        t.eq("new edits stay in place", get(view.buf), { "typed during the write" })
    end

    do
        local calls = 0
        local view = dirty(function()
            calls = calls + 1
            if calls == 1 then error("boom", 0) end
        end)
        notes = {}
        pcall(vim.cmd, "write")
        t.eq("a thrown error keeps modified", vim.bo[view.buf].modified, true)
        t.ok("a thrown error is reported", (notes[1] or ""):find("boom", 1, true))
        pcall(vim.cmd, "write")
        t.eq("a thrown error doesn't lock writes", calls, 2)
    end

    do
        local finish
        local view = dirty(function(_, done) finish = done end)
        pcall(vim.cmd, "write")
        vim.cmd("enew")
        vim.cmd("bwipeout! " .. view.buf)
        t.eq("done after a wipe is harmless", finish(true), false)
    end

    do
        local calls = 0
        local view = dirty(function() calls = calls + 1 end)
        vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, { "one", "two", "three" })

        local copy = dir .. "/copy.txt"
        vim.cmd("write " .. vim.fn.fnameescape(copy))
        t.eq(":w other never runs on_write", calls, 0)
        t.eq(":w other writes a copy", read(copy), { "one", "two", "three" })
        t.eq(":w other keeps modified", vim.bo[view.buf].modified, true)

        vim.fn.writefile({ "keep me" }, copy)
        local ok, err = pcall(vim.cmd, "write " .. vim.fn.fnameescape(copy))
        t.eq(":w other won't overwrite", read(copy), { "keep me" })
        t.ok(":w other says why", not ok and tostring(err):find("E13", 1, true))
        local range_ok = pcall(vim.cmd, "1write " .. vim.fn.fnameescape(copy))
        t.ok("range write won't overwrite", not range_ok and read(copy)[1] == "keep me")
        vim.cmd("write! " .. vim.fn.fnameescape(copy))
        t.eq(":w! other overwrites", read(copy), { "one", "two", "three" })

        local range = dir .. "/range.txt"
        vim.cmd("2,3write " .. vim.fn.fnameescape(range))
        t.eq("range write copies its lines", read(range), { "two", "three" })
        t.eq("range write never runs on_write", calls, 0)

        pcall(vim.cmd, "write >> " .. vim.fn.fnameescape(dir .. "/append.txt"))
        t.eq(":w >> never runs on_write", calls, 0)
    end

    t.child(function(c) -- a confirm from on_write opens on the next tick
        c.lua([[
            local malleable = require("neo.plugins.malleable")
            _G.answer = nil
            _G.view = malleable.open({
                name = "malltest://write/confirm",
                editable = true,
                on_write = function(_, done)
                    vim.schedule(function()
                        malleable.confirm({
                            lines = { "Apply?" },
                            on_yes = function() answer = "yes"; done(true) end,
                            on_no = function() answer = "no"; done(false) end,
                        })
                    end)
                end,
            })
            vim.api.nvim_win_set_buf(0, view.buf)
            vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, { "edit" })
        ]])
        local result = "return { answer, vim.bo[view.buf].modified }"
        c.keys(":w<CR>")
        t.eq("scheduled confirm has focus", c.lua("return vim.bo.filetype"), "malleable_confirm")
        c.keys("n")
        t.eq("No fails the write", c.lua(result), { "no", true })
        c.keys(":w<CR>")
        t.eq("a retry asks again", c.lua("return vim.bo.filetype"), "malleable_confirm")
        c.keys("y")
        t.eq("Yes saves", c.lua(result), { "yes", false })
    end)

    vim.cmd("enew!")
    vim.fn.delete(dir, "rf")
    vim.notify = real_notify
end
