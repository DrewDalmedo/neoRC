-- lua/neo/plugins/malleable/keys.lua
-- Buffer-local keys for a view, and a help float generated from them.
--
-- A key is { lhs, fn, desc = "...", mode = "n" }:
--   fn(view)   called when the key is pressed
--   desc       shown in the help float; a key without one is left out
--   mode       a mode or list of modes, e.g. { "n", "x" } (default "n")
local M = {}

local function normalize(entry, index)
    local lhs, fn = entry[1], entry[2]
    if type(lhs) ~= "string" or lhs == "" or type(fn) ~= "function" then
        error(("malleable: key %d needs an lhs and a function"):format(index), 0)
    end
    local mode = entry.mode or "n"
    return {
        lhs = lhs,
        fn = fn,
        desc = entry.desc or entry[3],
        modes = type(mode) == "table" and mode or { mode },
    }
end

--- Maps list on view's buffer and records it as view.keys. Every entry is
--- checked first, so a bad one maps nothing.
function M.apply(view, list)
    local keys = {}
    for i, entry in ipairs(list or {}) do
        keys[i] = normalize(entry, i)
    end
    for _, key in ipairs(keys) do
        vim.keymap.set(key.modes, key.lhs, function()
            key.fn(view)
        end, { buffer = view.buf, nowait = true, silent = true, desc = key.desc })
    end
    view.keys = keys
end

local function pad(text, width)
    return text .. (" "):rep(width - vim.fn.strdisplaywidth(text))
end

local function help_lines(view)
    local shown, lhs_width, desc_width = {}, 0, 0
    for _, key in ipairs(view.keys) do
        if key.desc then
            shown[#shown + 1] = key
            lhs_width = math.max(lhs_width, vim.fn.strdisplaywidth(key.lhs))
            desc_width = math.max(desc_width, vim.fn.strdisplaywidth(key.desc))
        end
    end
    if #shown == 0 then return { " No keys " } end

    local lines = {}
    for i, key in ipairs(shown) do
        local only_normal = #key.modes == 1 and key.modes[1] == "n"
        local suffix = only_normal and "" or ("  [" .. table.concat(key.modes, " ") .. "]")
        lines[i] = (" %s  %s%s "):format(pad(key.lhs, lhs_width), pad(key.desc, desc_width), suffix)
    end
    return lines
end

local function close(win)
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
    end
end

--- Opens the key list in a float, replacing one already open for this view.
--- q, <Esc>, or leaving the float closes it. Returns its window.
function M.help(view)
    close(view.help_win)

    local lines = help_lines(view)
    local width = 1
    for _, line in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    width = math.max(1, math.min(width, vim.o.columns - 4))
    local height = math.max(1, math.min(#lines, vim.o.lines - 4))

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "malleable_help"

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        style = "minimal",
        border = "rounded",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        title = " Keys ",
        title_pos = "left",
    })
    vim.wo[win].wrap = false
    view.help_win = win

    local function dismiss()
        close(win)
    end
    for _, lhs in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", lhs, dismiss, { buffer = buf, nowait = true, silent = true })
    end
    vim.api.nvim_create_autocmd("WinLeave", {
        buffer = buf,
        once = true,
        callback = function()
            -- (a window can't be closed while it's being left)
            vim.schedule(dismiss)
        end,
    })
    return win
end

return M
