-- lua/neo/plugins/lc/ui.lua
-- Buffers, windows, highlights and messages.

local M = {}

M.ns = vim.api.nvim_create_namespace("lc")

local HIGHLIGHTS = {
    LcAccepted = "DiagnosticOk",
    LcFailed = "DiagnosticError",
    LcLimit = "DiagnosticWarn",
    LcRunning = "DiagnosticInfo",
    LcTitle = "Title",
    LcLabel = "Label",
    LcDim = "Comment",
}

function M.highlights()
    for name, link in pairs(HIGHLIGHTS) do
        vim.api.nvim_set_hl(0, name, { link = link, default = true })
    end
end

M.highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("lc.highlights", { clear = true }),
    callback = M.highlights,
})

--- Notifies with the "lc" title.
function M.notify(msg, level)
    vim.notify(msg, level or vim.log.levels.INFO, { title = "lc" })
end

function M.error(msg)
    M.notify(msg, vim.log.levels.ERROR)
end

function M.warn_doc(doc)
    if doc and doc.warnings and #doc.warnings > 0 then
        M.notify(table.concat(doc.warnings, "\n"), vim.log.levels.WARN)
    end
end

local function vim_error(err)
    err = tostring(err)
    return err:match("E%d+:.*") or err
end

local function make_scratch(buf, filetype)
    vim.b[buf].lc_scratch = true
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].buflisted = false
    vim.bo[buf].modifiable = false
    if filetype then
        vim.bo[buf].filetype = filetype
    end
end

--- A scratch buffer with this name, made the first time. A buffer of that
--- name that isn't the plugin's (a session brings them back as plain empty
--- buffers) is made one.
function M.scratch(name, filetype)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b) == name then
            if not vim.b[b].lc_scratch then
                make_scratch(b, filetype)
                -- Its windows, which a session doesn't mark either.
                local mark = name:match("^lc://problem/") and "lc_statement" or "lc_result"
                for _, win in ipairs(vim.fn.win_findbuf(b)) do
                    vim.w[win][mark] = true
                end
            end
            return b
        end
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
    make_scratch(buf, filetype)
    return buf
end

--- Replaces a scratch buffer's lines.
function M.set_lines(buf, lines)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
end

--- A window of this tab page that shows buf, or for which pred(win) holds.
function M.find_win(pred)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if pred(win) then
            return win
        end
    end
    return nil
end

function M.win_showing(buf)
    return M.find_win(function(win)
        return vim.api.nvim_win_get_buf(win) == buf
    end)
end

--- Whether win is the plugin's window of this kind (mark): marked so, and
--- still showing the plugin's buffer there: a scratch buffer, or for a
--- statement a problem's README.md. A window that went on to show another
--- buffer is yours again, and loses its mark.
function M.marked(win, mark)
    if not vim.w[win][mark] then
        return false
    end
    local buf = vim.api.nvim_win_get_buf(win)
    local ours = vim.b[buf].lc_scratch == true
    if not ours and mark == "lc_statement" then
        local name = vim.api.nvim_buf_get_name(buf)
        ours = vim.fs.basename(name) == "README.md" and require("neo.plugins.lc.problem").from_path(name) ~= nil
    end
    if not ours then
        vim.w[win][mark] = nil
        if mark == "lc_result" then
            vim.wo[win].winfixheight = false
        end
    end
    return ours
end

local function normal(win)
    local buf = vim.api.nvim_win_get_buf(win)
    return vim.bo[buf].buftype == ""
        and not M.marked(win, "lc_statement")
        and not M.marked(win, "lc_result")
        and not vim.wo[win].winfixbuf
        and vim.api.nvim_win_get_config(win).relative == ""
end

--- A window for editing files: the current one unless it is special (help,
--- quickfix, 'winfixbuf', a statement, the plugin's own), else the first
--- other one that isn't, else a new one.
function M.edit_win()
    local cur = vim.api.nvim_get_current_win()
    if normal(cur) then
        return cur
    end
    local win = M.find_win(normal)
    if win then
        return win
    end
    local ok = pcall(vim.cmd, M.marked(cur, "lc_statement") and "rightbelow vnew" or "topleft new")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(cur)
    return ok and win or cur
end

--- Shows buf in a window of this tab page: the one that shows it already,
--- else the plugin's window marked w:[mark], else a new one opened with the
--- Ex command `split` (a statement's from a window for editing, not from
--- the result panel). Returns the window, or nil and an error; the
--- cursor stays where it was.
function M.show(buf, split, mark)
    local win = M.win_showing(buf)
    if not win and mark then
        win = M.find_win(function(w)
            return M.marked(w, mark)
        end)
    end
    local from = vim.api.nvim_get_current_win()
    if not win then
        -- A statement goes beside a window for editing, rather than splitting
        -- the result panel; failing one, it splits the current window.
        if mark == "lc_statement" and not normal(from) then
            local base = M.find_win(normal)
            if base then
                vim.api.nvim_set_current_win(base)
            end
        end
        local ok, err = pcall(vim.cmd, split)
        win = vim.api.nvim_get_current_win()
        vim.api.nvim_set_current_win(from)
        if not ok then
            return nil, vim_error(err)
        end
    end
    local ok, err = pcall(vim.api.nvim_win_set_buf, win, buf)
    if not ok then
        return nil, vim_error(err)
    end
    if mark then
        vim.w[win][mark] = true
    end
    return win
end

--- Opens file in win and makes win current. When win shows the file
--- already, it is left alone: :edit would reload it, and refuse to over
--- unsaved changes. Returns true, or false and Vim's error.
function M.edit(win, file)
    vim.api.nvim_set_current_win(win)
    local buf = require("neo.plugins.lc.problem").find_buf(file)
    if buf and vim.api.nvim_win_get_buf(win) == buf then
        return true
    end
    local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(file))
    if not ok then
        return false, vim_error(err)
    end
    return true
end

--- Shows buf in the panel at the bottom that the result and :Lc stats
--- share, opened with the Ex command `split` the first time. Returns the
--- window, or nil and an error.
function M.panel(buf, split)
    local win, err = M.show(buf, split, "lc_result")
    if not win then
        return nil, err
    end
    -- Local to the window and this buffer, so that a file you open in the
    -- window, or a window split from it, has your settings.
    local wo = vim.wo[win][0]
    wo.number, wo.relativenumber, wo.spell, wo.list = false, false, false, false
    wo.signcolumn, wo.foldcolumn = "no", "0"
    vim.wo[win].winfixheight = true
    return win
end

return M
