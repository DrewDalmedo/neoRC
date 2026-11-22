-- lua/neo/plugins/malleable/view.lua
-- The rendering half of a malleable buffer: swapping its lines without
-- disturbing the windows that show it, and holding a refresh back until the
-- user isn't in the middle of something.
--
--   local view = require("neo.plugins.malleable.view").new({ buf = buf })
--   view:when_stable(function()
--       local lines, rows = render(model)
--       view:replace(lines, { cursor = function(win, old_row) ... end })
--       decorate(view.ns, rows)      -- same tick, so nothing flickers
--   end)
--
-- view:replace(lines, opts) -> true, or false when nothing was replaced
--   Replaces every line, clears view.ns (a full replace would otherwise pile
--   its extmarks onto one row), leaves the buffer unmodified, and restores
--   the cursor and scroll of every window showing it. The replace isn't
--   undoable, so `u` can't bring back stale state.
--   opts.force    overwrite a modified editable buffer (refused otherwise)
--   opts.cursor   fn(win, old_row) -> new_row, or nil to stay on old_row
--
-- view:when_stable(fn) -> true if fn ran now, false if held back or dead
--   Runs fn(view) unless the current window shows this buffer in any mode
--   but plain Normal: a row-changing refresh during Visual would move the
--   selection onto other items, and one during `:'<,'>` would change what
--   the range means. Only the latest held fn runs.
--
-- Don't combine replace with manual folds: they stay on their old row
-- numbers over the new text. Render collapsed content by leaving it out.
local M = {}

local View = {}
View.__index = View

-- One namespace for every view. Extmarks belong to a buffer, so clearing it
-- for one view leaves the others alone.
local NS = vim.api.nvim_create_namespace("neo.malleable")

--- opts: buf, editable. The caller creates the buffer and sets its options.
function M.new(opts)
    return setmetatable({
        buf = opts.buf,
        ns = NS,
        editable = opts.editable == true,
        keys = {},
    }, View)
end

local function alive(self)
    return not self.disposed and vim.api.nvim_buf_is_valid(self.buf)
end

local function write_lines(buf, lines)
    local bo = vim.bo[buf]
    local undolevels, modifiable = bo.undolevels, bo.modifiable
    bo.undolevels = -1
    bo.modifiable = true
    local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
    bo.modifiable = modifiable
    bo.undolevels = undolevels
    if not ok then error(err, 0) end
    bo.modified = false
end

local function save_views(buf)
    local saved = {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        saved[win] = vim.api.nvim_win_call(win, function()
            return vim.fn.winsaveview()
        end)
    end
    return saved
end

local function restore_view(win, saved, row, last)
    if not vim.api.nvim_win_is_valid(win) then return end
    saved.lnum = math.max(1, math.min(row, last))
    saved.topline = math.max(1, math.min(saved.topline, last))
    vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(saved)
    end)
end

function View:replace(lines, opts)
    opts = opts or {}
    if not alive(self) then return false end
    if self.editable and vim.bo[self.buf].modified and not opts.force then
        return false
    end

    local saved = save_views(self.buf)
    vim.api.nvim_buf_clear_namespace(self.buf, NS, 0, -1)
    write_lines(self.buf, lines)
    -- What :e! goes back to.
    self.rendered = vim.list_extend({}, lines)

    -- A failing cursor callback still leaves every window somewhere valid.
    local last, failure = vim.api.nvim_buf_line_count(self.buf), nil
    for win, view in pairs(saved) do
        local row = view.lnum
        if opts.cursor then
            local ok, mapped = pcall(opts.cursor, win, view.lnum)
            if ok then
                row = mapped or row
            else
                failure = failure or mapped
            end
        end
        restore_view(win, view, row, last)
    end
    if failure then error(failure, 0) end
    return true
end

local function stable(self)
    -- Buffers can't be redrawn safely from under the command-line window.
    if vim.fn.getcmdwintype() ~= "" then return false end
    if vim.api.nvim_get_current_buf() ~= self.buf then return true end
    return vim.fn.mode(1) == "n"
end

local function stop_watch(self)
    if self.watch then
        pcall(vim.api.nvim_del_augroup_by_id, self.watch)
        self.watch = nil
    end
end

local function flush(self)
    if not alive(self) then
        self.pending = nil
        stop_watch(self)
        return
    end
    if not self.pending or not stable(self) then return end
    local fn = self.pending
    self.pending = nil
    stop_watch(self)
    fn(self)
end

-- Checked on the next tick, never inside the autocommand: `:` from Visual
-- passes through plain Normal before the command line opens, and running
-- then would change the lines under the coming '<,'> range.
local function queue_flush(self)
    if self.flush_queued then return end
    self.flush_queued = true
    vim.schedule(function()
        self.flush_queued = false
        flush(self)
    end)
end

local function start_watch(self)
    if self.watch then return end
    local group = vim.api.nvim_create_augroup("neo.malleable.view." .. self.buf, { clear = true })
    self.watch = group
    -- WinEnter covers leaving the buffer while staying in Insert mode (a
    -- mouse click). CmdwinLeave is there because closing the command-line
    -- window runs no other autocommands.
    vim.api.nvim_create_autocmd({ "ModeChanged", "WinEnter", "BufEnter", "CmdwinLeave" }, {
        group = group,
        callback = function()
            queue_flush(self)
        end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        buffer = self.buf,
        callback = function()
            self.pending = nil
            stop_watch(self)
        end,
    })
end

function View:when_stable(fn)
    if not alive(self) then return false end
    if stable(self) then
        self.pending = nil
        stop_watch(self)
        fn(self)
        return true
    end
    self.pending = fn
    start_watch(self)
    return false
end

--- Opens the generated key list.
function View:help()
    return require("neo.plugins.malleable.keys").help(self)
end

--- Drops anything held back and closes the help float. Safe to call twice.
function View:dispose()
    if self.disposed then return end
    self.disposed = true
    self.pending = nil
    stop_watch(self)
    if self.help_win and vim.api.nvim_win_is_valid(self.help_win) then
        pcall(vim.api.nvim_win_close, self.help_win, true)
    end
    self.help_win = nil
end

return M
