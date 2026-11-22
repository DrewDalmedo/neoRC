-- lua/neo/plugins/malleable/tests/keys.lua
local View = require("neo.plugins.malleable.view")
local keys = require("neo.plugins.malleable.keys")

local function make()
    local buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
    vim.api.nvim_set_current_buf(buf)
    return buf, View.new({ buf = buf })
end

local function press(lhs)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "mx", false)
end

local function float_lines(win)
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

return function(t)
    do
        local buf, view = make()
        local got, modes = {}, {}
        keys.apply(view, {
            { "zq", function(v) got[#got + 1] = v end, desc = "Act" },
            { "zw", function() modes[#modes + 1] = vim.fn.mode() end, desc = "Both", mode = { "n", "x" } },
        })
        press("zq")
        t.ok("a key calls fn with the view", got[1] == view)
        press("zw")
        press("Vzw")
        press("<Esc>")
        t.eq("a mode list maps each mode", modes, { "n", "V" })

        local map = vim.fn.maparg("zq", "n", false, true)
        t.eq("mapped on this buffer", map.buffer, 1)
        t.eq("mapped nowait", map.nowait, 1)
        t.eq("mapped with its desc", map.desc, "Act")
        t.eq("default mode is Normal only", vim.fn.maparg("zq", "x"), "")

        local other = vim.api.nvim_create_buf(true, true)
        vim.api.nvim_set_current_buf(other)
        t.eq("not mapped on other buffers", vim.fn.maparg("zq", "n"), "")
        vim.api.nvim_set_current_buf(buf)
    end

    do
        local _, view = make()
        local ok, err = pcall(keys.apply, view, {
            { "zg", function() end },
            { "zb", "not a function" },
        })
        t.eq("a bad key is refused", { ok, err }, { false, "malleable: key 2 needs an lhs and a function" })
        t.eq("a bad key maps nothing", vim.fn.maparg("zg", "n"), "")
    end

    do
        local _, view = make()
        local origin = vim.api.nvim_get_current_win()
        keys.apply(view, {
            { "s", function() end, desc = "Stage", mode = { "n", "x" } },
            { "<CR>", function() end, desc = "Open" },
            { "zh", function() end },
        })
        local win = view:help()
        t.eq("help lists described keys", float_lines(win), {
            " s     Stage  [n x] ",
            " <CR>  Open  ",
        })
        t.eq("help takes focus", vim.api.nvim_get_current_win(), win)

        local second = view:help()
        t.ok("reopening replaces the float", not vim.api.nvim_win_is_valid(win))
        press("q")
        t.ok("q closes help", not vim.api.nvim_win_is_valid(second))
        t.eq("focus returns", vim.api.nvim_get_current_win(), origin)

        local third = view:help()
        view:dispose()
        t.ok("dispose closes help", not vim.api.nvim_win_is_valid(third))
    end

    do
        local _, view = make()
        keys.apply(view, { { "zh", function() end } })
        local win = view:help()
        t.eq("help with nothing to show", float_lines(win), { " No keys " })
        vim.api.nvim_win_close(win, true)
    end

    t.child(function(c)
        c.lua([[
            local view = require("neo.plugins.malleable.view").new({
                buf = vim.api.nvim_get_current_buf(),
            })
            require("neo.plugins.malleable.keys").apply(view, {
                { "zh", function() end, desc = "Help" },
            })
            _G.help = view:help()
            vim.cmd("wincmd p")
        ]])
        c.lua("vim.wait(50)")
        t.eq("leaving help closes it", c.lua("return vim.api.nvim_win_is_valid(help)"), false)
    end)
end
