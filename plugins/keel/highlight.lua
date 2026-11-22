-- lua/neo/plugins/keel/highlight.lua
-- Keel's highlight groups, applied as extmarks: `:syn` rules added from a
-- FileType autocmd get cleared by Neovim's syntax setup.
local M = {}

local LINKS = {
    KeelHead = "Identifier",
    KeelBanner = "WarningMsg",
    KeelSection = "Title",
    KeelFile = "Directory",
    KeelHunk = "Function",
    KeelAdd = "DiffAdd",
    KeelDelete = "DiffDelete",
    KeelNote = "Comment",
    KeelHash = "Number",
}

local function define()
    for name, link in pairs(LINKS) do
        vim.api.nvim_set_hl(0, name, { link = link, default = true })
    end
end

function M.setup()
    define()
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("neo.keel.highlight", { clear = true }),
        callback = define,
    })
end

--- The group for one line of a diff, or nil.
function M.diff_group(line)
    local c = line:sub(1, 1)
    if c == "+" then return "KeelAdd" end
    if c == "-" then return "KeelDelete" end
    if c == "\\" then return "KeelNote" end
    return nil
end

--- marks: list of { row (0-based), group }, for a whole line, or
--- { row, group, start_col, end_col } for part of one.
function M.apply(view, marks)
    for _, mark in ipairs(marks) do
        local opts = { line_hl_group = mark[2] }
        if mark[3] then
            opts = { hl_group = mark[2], end_col = mark[4] }
        end
        pcall(vim.api.nvim_buf_set_extmark, view.buf, view.ns, mark[1], mark[3] or 0, opts)
    end
end

return M
