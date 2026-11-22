-- lua/neo/plugins/malleable/write.lua
-- What :w does on an editable view. The plugin's on_write does the work,
-- possibly async, and reports through done:
--
--   on_write = function(view, done)
--       apply(function(ok) done(ok) end)
--   end
--
-- done(true)    saved: clears 'modified', unless the text changed since :w
--               (then it returns false and the edits stay marked unsaved)
-- done(false)   failed: text and 'modified' stay as they are
--
-- Only the first call to done counts, and an error from on_write counts as
-- done(false). While a write is running another :w doesn't call on_write.
-- :wq closes the window only if on_write finished saving before returning.
--
-- Focus returns to the view when :w ends, so open a confirm or other float
-- from vim.schedule. Opened directly, its keys land in the view instead.
--
-- :w other-file and :1,2w other-file write a plain copy and never call
-- on_write: saving a copy mustn't apply the buffer's changes.
local M = {}

local function report(message, level)
    vim.notify("malleable: " .. message, level or vim.log.levels.ERROR)
end

-- (Neovim has already refused an existing target without !, as E13.)
local function write_copy(buf, target, first, last)
    local lines = vim.api.nvim_buf_get_lines(buf, first, last, false)
    local ok, result = pcall(vim.fn.writefile, lines, target)
    if not ok or result ~= 0 then
        report(("can't write %s%s"):format(target, ok and "" or ": " .. tostring(result)))
    end
end

local function start(view, on_write)
    if view.writing then
        report("a write is still running", vim.log.levels.WARN)
        return
    end
    view.writing = true
    local tick = vim.api.nvim_buf_get_changedtick(view.buf)
    local settled = false

    local function done(ok)
        if settled then return false end
        settled = true
        view.writing = false
        if not ok or view.disposed or not vim.api.nvim_buf_is_valid(view.buf) then
            return false
        end
        if vim.api.nvim_buf_get_changedtick(view.buf) ~= tick then
            return false
        end
        vim.bo[view.buf].modified = false
        return true
    end

    local ok, err = pcall(on_write, view, done)
    if not ok then
        done(false)
        report("write failed: " .. tostring(err))
    end
end

--- Handles writes on view's buffer, in view.group.
function M.attach(view, on_write)
    local buf = view.buf
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        group = view.group,
        buffer = buf,
        callback = function(ev)
            if ev.match ~= vim.api.nvim_buf_get_name(buf) then
                write_copy(buf, ev.match, 0, -1)
                return
            end
            start(view, on_write)
        end,
    })
    -- Without a handler a range write to a file is E676 on an acwrite buffer.
    vim.api.nvim_create_autocmd("FileWriteCmd", {
        group = view.group,
        buffer = buf,
        callback = function(ev)
            write_copy(buf, ev.match, vim.fn.line("'[") - 1, vim.fn.line("']"))
        end,
    })
end

return M
