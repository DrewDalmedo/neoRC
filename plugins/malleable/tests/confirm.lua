-- lua/neo/plugins/malleable/tests/confirm.lua
local malleable = require("neo.plugins.malleable")

local function press(lhs)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "mx", false)
end

local function open(result, extra)
    return malleable.confirm(vim.tbl_extend("force", {
        title = " Test ",
        lines = { "Delete this?" },
        on_yes = function() result[#result + 1] = "yes" end,
        on_no = function() result[#result + 1] = "no" end,
    }, extra or {}))
end

return function(t)
    local origin = vim.api.nvim_get_current_win()

    do
        local result = {}
        local win = open(result)
        t.eq("takes focus", vim.api.nvim_get_current_win(), win)
        t.eq("shows the lines", vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), { "Delete this?" })
        t.eq("nothing runs yet", result, {})
        press("y")
        t.eq("y says yes", result, { "yes" })
        t.ok("y closes the float", not vim.api.nvim_win_is_valid(win))
        t.eq("focus returns", vim.api.nvim_get_current_win(), origin)
        vim.wait(20)
        t.eq("closing doesn't also say no", result, { "yes" })
    end

    for _, lhs in ipairs({ "n", "N", "q", "<Esc>", "<CR>" }) do
        local result = {}
        local win = open(result)
        press(lhs)
        vim.wait(20)
        t.eq(lhs .. " says no", result, { "no" })
        t.ok(lhs .. " closes the float", not vim.api.nvim_win_is_valid(win))
    end

    do
        local result = {}
        local win = open(result)
        vim.api.nvim_win_close(win, true)
        vim.wait(100, function() return #result > 0 end)
        t.eq("closing the float says no", result, { "no" })
    end

    do
        local result = {}
        local win = open(result)
        vim.api.nvim_set_current_win(origin)
        vim.wait(100, function() return #result > 0 end)
        t.eq("leaving the float says no", result, { "no" })
        t.ok("leaving closes the float", not vim.api.nvim_win_is_valid(win))
    end

    do
        local first, second = {}, {}
        local win = open(first)
        local next_win = open(second)
        t.eq("a new confirm says no to the old", first, { "no" })
        t.ok("a new confirm closes the old", not vim.api.nvim_win_is_valid(win))
        press("y")
        vim.wait(20)
        t.eq("the new confirm still answers", second, { "yes" })
        t.eq("the old one answers only once", first, { "no" })
        t.ok("the new float closes", not vim.api.nvim_win_is_valid(next_win))
    end

    do
        local win = malleable.confirm({ lines = { "No callbacks" } })
        press("n")
        vim.wait(20)
        t.ok("works without callbacks", not vim.api.nvim_win_is_valid(win))
    end

    do
        local reopened = false
        malleable.confirm({
            lines = { "First" },
            on_no = function()
                reopened = true
                malleable.confirm({ lines = { "Second" } })
            end,
        })
        press("n")
        vim.wait(20)
        t.ok("a callback can open another confirm", reopened)
        t.eq("the second confirm has focus", vim.bo.filetype, "malleable_confirm")
        press("n")
        vim.wait(20)
    end

    do
        local long = ("x"):rep(vim.o.columns * 2)
        local win = malleable.confirm({ lines = { long } })
        t.ok("a long line fits the screen", vim.api.nvim_win_get_width(win) <= vim.o.columns - 4)
        t.ok("a long line wraps", vim.api.nvim_win_get_height(win) >= 3)
        press("n")
        vim.wait(20)
    end
end
