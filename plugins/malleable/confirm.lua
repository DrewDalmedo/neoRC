-- lua/neo/plugins/malleable/confirm.lua
-- A yes/no float for destructive actions. Only y says yes: <CR>, n, q,
-- <Esc>, closing the float, leaving it, or opening another confirm all say
-- no. Exactly one of on_yes and on_no runs, after the float has closed.
--
--   malleable.confirm({
--       title = " Discard ",
--       lines = { "Discard changes to init.lua?" },
--       on_yes = function() discard() end,
--       on_no = function() done(false) end,
--   })
local M = {}

local FOOTER = " y yes · n no "

local active = nil

local function size(lines, title)
    local max_width = math.max(1, vim.o.columns - 4)
    local width = math.max(vim.fn.strdisplaywidth(title), vim.fn.strdisplaywidth(FOOTER))
    for _, line in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    width = math.min(width, max_width)

    -- Lines wrap, so a long path is never cut off in what's being confirmed.
    local height = 0
    for _, line in ipairs(lines) do
        height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
    end
    return width, math.max(1, math.min(height, vim.o.lines - 6))
end

--- opts: title, lines, on_yes, on_no. Returns the float's window.
function M.confirm(opts)
    if active then active(false) end

    local title = opts.title or " Confirm "
    local lines = opts.lines or { "Are you sure?" }
    local width, height = size(lines, title)
    local settled, win = false, nil

    local function settle(yes)
        if settled then return end
        settled = true
        active = nil
        if win and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, true)
        end
        local callback = opts.on_no
        if yes then callback = opts.on_yes end
        if callback then callback() end
    end
    active = settle

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "malleable_confirm"

    win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        style = "minimal",
        border = "rounded",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        title = title,
        title_pos = "left",
        footer = FOOTER,
        footer_pos = "right",
    })
    vim.wo[win].wrap = true

    local map = { buffer = buf, nowait = true, silent = true }
    for _, lhs in ipairs({ "y", "Y" }) do
        vim.keymap.set("n", lhs, function() settle(true) end, map)
    end
    for _, lhs in ipairs({ "n", "N", "q", "<Esc>", "<CR>" }) do
        vim.keymap.set("n", lhs, function() settle(false) end, map)
    end

    -- Scheduled: a callback may open windows, which can't happen while one
    -- is being left or closed.
    local function dismiss()
        vim.schedule(function() settle(false) end)
    end
    vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = dismiss })
    vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(win), once = true, callback = dismiss })
    return win
end

return M
