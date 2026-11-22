-- lua/neo/plugins/malleable/tests/view.lua
local View = require("neo.plugins.malleable.view")

local function numbered(prefix, n)
    local out = {}
    for i = 1, n do out[i] = prefix .. i end
    return out
end

local function make(lines, editable)
    local buf = vim.api.nvim_create_buf(true, not editable)
    if editable then vim.bo[buf].buftype = "acwrite" end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false
    return buf, View.new({ buf = buf, editable = editable })
end

local function get(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- Sets up a view on the child's current buffer, and queue(id) to refresh it.
local SETUP = [[
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c", "d", "e" })
vim.bo[buf].modified = false
_G.view = require("neo.plugins.malleable.view").new({ buf = buf })
_G.ran = {}
_G.queue = function(id)
    return view:when_stable(function() table.insert(ran, id) end)
end
]]

local function held(t, name, enter, leave)
    t.child(function(c)
        c.lua(SETUP)
        c.keys(enter)
        t.eq(name .. ": held back", c.lua("return queue(1)"), false)
        t.eq(name .. ": not run yet", c.lua("return ran"), {})
        c.keys(leave)
        t.eq(name .. ": back in Normal", c.mode(), "n")
        t.eq(name .. ": runs on leaving", c.lua("return ran"), { 1 })
    end)
end

return function(t)
    -- replace
    do
        local buf, view = make({ "a" })
        vim.bo[buf].modifiable = false
        t.eq("replace returns true", view:replace({ "x", "y" }), true)
        t.eq("replace sets the lines", get(buf), { "x", "y" })
        t.eq("replace keeps nomodifiable", vim.bo[buf].modifiable, false)
        t.eq("replace leaves it unmodified", vim.bo[buf].modified, false)
    end

    do
        local buf, view = make({ "old1", "old2" }, true)
        vim.api.nvim_set_current_buf(buf)
        local undolevels = vim.bo[buf].undolevels
        vim.cmd("normal! ggdd")
        view:replace({ "fresh" }, { force = true })
        pcall(vim.cmd, "silent undo")
        t.eq("undo can't bring back replaced text", get(buf), { "fresh" })
        t.eq("undolevels restored", vim.bo[buf].undolevels, undolevels)
    end

    do
        local buf, view = make(numbered("m", 3))
        local other = vim.api.nvim_create_namespace("malleable.test.other")
        vim.api.nvim_buf_set_extmark(buf, view.ns, 1, 0, {})
        vim.api.nvim_buf_set_extmark(buf, other, 1, 0, {})
        view:replace(numbered("n", 3))
        t.eq("replace clears view.ns", #vim.api.nvim_buf_get_extmarks(buf, view.ns, 0, -1, {}), 0)
        t.eq("replace leaves other namespaces", #vim.api.nvim_buf_get_extmarks(buf, other, 0, -1, {}), 1)
    end

    do
        local buf, view = make({ "saved" }, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "pending edit" })
        t.eq("modified editable buffer refused", view:replace({ "refresh" }), false)
        t.eq("refused replace keeps the edit", get(buf), { "pending edit" })
        t.eq("refused replace keeps modified", vim.bo[buf].modified, true)
        t.eq("force overwrites it", view:replace({ "refresh" }, { force = true }), true)
        t.eq("forced replace sets the lines", get(buf), { "refresh" })
    end

    do
        local buf, view = make({ "a" })
        view:dispose()
        view:dispose()
        t.eq("disposed view refuses replace", view:replace({ "b" }), false)
        t.eq("disposed view keeps its lines", get(buf), { "a" })
        t.eq("disposed view refuses when_stable", view:when_stable(function() end), false)
    end

    -- windows
    do
        local buf, view = make(numbered("l", 40))
        vim.api.nvim_set_current_buf(buf)
        vim.cmd("silent! only")
        vim.cmd("split")
        local w1 = vim.api.nvim_get_current_win()
        local w2 = vim.fn.win_getid(2)
        vim.api.nvim_win_set_cursor(w1, { 5, 1 })
        vim.api.nvim_win_call(w2, function()
            vim.fn.winrestview({ topline = 15, lnum = 20, col = 1 })
        end)

        view:replace(numbered("n", 40))
        t.eq("cursor kept in the current window", vim.api.nvim_win_get_cursor(w1), { 5, 1 })
        t.eq("cursor kept in another window", vim.api.nvim_win_get_cursor(w2), { 20, 1 })
        t.eq("scroll kept in another window", vim.api.nvim_win_call(w2, function()
            return vim.fn.winsaveview().topline
        end), 15)

        local seen = {}
        view:replace(numbered("o", 40), {
            cursor = function(win, old_row)
                seen[win] = old_row
                if win == w1 then return old_row + 2 end
            end,
        })
        t.eq("cursor callback gets the old row", seen, { [w1] = 5, [w2] = 20 })
        t.eq("cursor callback moves the cursor", vim.api.nvim_win_get_cursor(w1)[1], 7)
        t.eq("nil from the callback stays put", vim.api.nvim_win_get_cursor(w2)[1], 20)

        view:replace({ "only1", "only2" })
        t.eq("cursor clamped to a shorter buffer", vim.api.nvim_win_get_cursor(w2)[1], 2)

        view:replace(numbered("p", 10))
        local ok, err = pcall(function()
            view:replace(numbered("q", 10), {
                cursor = function() error("mapping broke", 0) end,
            })
        end)
        t.eq("a failing cursor callback is reported", { ok, err }, { false, "mapping broke" })
        t.eq("lines still replaced after it", get(buf)[1], "q1")
        t.ok("windows still valid after it", vim.api.nvim_win_get_cursor(w1)[1] <= 10)
        vim.cmd("silent! only")
    end

    -- when_stable, with real modes
    t.child(function(c)
        c.lua(SETUP)
        t.eq("Normal mode runs now", c.lua("return queue(1)"), true)
        t.eq("Normal mode ran it", c.lua("return ran"), { 1 })
    end)

    held(t, "Visual", "ggVj", "<Esc>")
    held(t, "Insert", "i", "<Esc>")
    held(t, "Replace", "R", "<Esc>")
    held(t, "operator-pending", "d", "<Esc>")
    held(t, "Select", "gh", "<Esc>")
    held(t, "command line", ":", "<C-c>")
    held(t, "Insert <C-o>", "i<C-o>", "<Esc><Esc>")
    held(t, "command-line window", "q:", ":q<CR>")

    t.child(function(c)
        c.lua(SETUP)
        c.keys("ggVj")
        c.lua("queue(1)")
        t.eq("selection untouched while held", c.lua([[
            return { vim.fn.line("v"), vim.fn.line(".") }
        ]]), { 1, 2 })
        c.keys(":")
        t.eq("Visual to cmdline is in cmdline", c.mode(), "c")
        t.eq("Visual to cmdline stays held", c.lua("return ran"), {})
        c.keys("<C-c>")
        t.eq("runs once truly Normal", c.lua("return ran"), { 1 })
    end)

    t.child(function(c)
        c.lua(SETUP)
        c.keys("V")
        c.lua("queue(1); queue(2)")
        c.keys("<Esc>")
        t.eq("only the latest held fn runs", c.lua("return ran"), { 2 })
    end)

    t.child(function(c)
        c.lua(SETUP)
        c.keys("V")
        c.lua("queue(1)")
        c.keys("<Esc>")
        c.lua("queue(2)")
        c.keys("V<Esc>")
        t.eq("a fired fn doesn't run again", c.lua("return ran"), { 1, 2 })
    end)

    t.child(function(c)
        c.lua(SETUP)
        c.lua([[
            vim.cmd("vnew")
            _G.other = vim.api.nvim_get_current_win()
            vim.cmd("wincmd p")
        ]])
        c.keys("i")
        t.eq("held in Insert on this buffer", c.lua("return queue(1)"), false)
        c.lua("vim.api.nvim_set_current_win(other)")
        c.settle()
        t.eq("still in Insert elsewhere", c.mode(), "i")
        t.eq("leaving the window runs it", c.lua("return ran"), { 1 })
        t.eq("another buffer's Insert doesn't hold it", c.lua("return queue(2)"), true)
    end)

    t.child(function(c)
        c.lua(SETUP)
        c.keys("V")
        c.lua("queue(1); view:dispose()")
        c.keys("<Esc>")
        t.eq("dispose drops the held fn", c.lua("return ran"), {})
    end)

    t.child(function(c)
        c.lua(SETUP)
        c.keys("V")
        c.lua([[
            queue(1)
            local buf = view.buf
            vim.cmd("enew")
            vim.api.nvim_buf_delete(buf, { force = true })
        ]])
        c.keys("<Esc>")
        t.eq("wiping the buffer drops the held fn", c.lua("return ran"), {})
    end)
end
