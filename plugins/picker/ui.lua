-- lua/neo/plugins/picker/ui.lua
-- Floating prompt + results windows for pickers. Pure window management:
-- no filtering, keymaps, or item semantics.
local M = {}

-- Open the two windows and return a handle:
--   { prompt_buf, prompt_win, results_buf, results_win }
-- The prompt window is entered; both buffers are wiped when their windows close.
function M.create(opts)
    opts = opts or {}
    local width = opts.width or math.min(80, vim.o.columns - 4)
    local total_h = opts.height or math.min(20, vim.o.lines - 4)
    local row = math.floor((vim.o.lines - total_h) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local base = { relative = "editor", style = "minimal", border = "rounded" }
    local h = {}

    local prompt_cfg = vim.tbl_extend("force", base, {
        row = row, col = col, width = width, height = 1, zindex = 50,
    })
    if opts.title then
        prompt_cfg.title = opts.title
        prompt_cfg.title_pos = "left"
    end
    h.prompt_buf = vim.api.nvim_create_buf(false, true)
    h.prompt_win = vim.api.nvim_open_win(h.prompt_buf, true, prompt_cfg)

    h.results_buf = vim.api.nvim_create_buf(false, true)
    h.results_win = vim.api.nvim_open_win(h.results_buf, false, vim.tbl_extend("force", base, {
        row = row + 3, col = col, width = width, height = math.max(5, total_h - 5),
        noautocmd = true, zindex = 51,
    }))

    vim.api.nvim_set_option_value("filetype", "picker_prompt", { buf = h.prompt_buf })
    vim.api.nvim_set_option_value("filetype", "picker_results", { buf = h.results_buf })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = h.prompt_buf })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = h.results_buf })
    vim.api.nvim_set_option_value("cursorline", true, { win = h.results_win })
    vim.api.nvim_set_option_value("wrap", false, { win = h.results_win })
    vim.api.nvim_set_option_value("scrolloff", 999, { win = h.results_win })
    return h
end

function M.is_valid(h)
    return h ~= nil
        and h.prompt_win ~= nil and vim.api.nvim_win_is_valid(h.prompt_win)
        and h.prompt_buf ~= nil and vim.api.nvim_buf_is_valid(h.prompt_buf)
end

-- Render `items` (tables with a .display field), marking `selected` (0 = none).
function M.render(h, items, selected)
    if not (h.results_buf and vim.api.nvim_buf_is_valid(h.results_buf)) then return end
    local lines = {}
    for i, item in ipairs(items) do
        lines[i] = (i == selected and "▸ " or "  ") .. item.display
    end
    vim.api.nvim_buf_set_lines(h.results_buf, 0, -1, false, lines)
    if items[selected]
        and h.results_win and vim.api.nvim_win_is_valid(h.results_win) then
        vim.api.nvim_win_set_cursor(h.results_win, { selected, 0 })
    end
end

function M.close(h)
    for _, win in ipairs({ h.prompt_win, h.results_win }) do
        if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end
    h.prompt_win, h.results_win = nil, nil
end

return M
