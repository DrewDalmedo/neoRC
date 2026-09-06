-- lua/neo/plugins/picker/util.lua
-- Small shared helpers for picker-based plugins.
local M = {}

-- Debounced wrapper around fn: calling it (re)arms a timer and only the last
-- call within `ms` fires. The returned value is callable; use .cancel() to
-- drop a pending call and .close() to release the timer when done with it.
function M.debounce(ms, fn)
    local timer = vim.uv.new_timer()
    local function usable()
        return timer and not timer:is_closing()
    end
    return setmetatable({
        cancel = function()
            if usable() then timer:stop() end
        end,
        close = function()
            if usable() then
                timer:stop()
                timer:close()
            end
        end,
    }, {
        __call = function(_, ...)
            if not usable() then return end
            timer:stop()
            local args = { ... }
            timer:start(ms, 0, vim.schedule_wrap(function() fn(unpack(args)) end))
        end,
    })
end

-- Open a file in the current window, optionally jumping to line/col.
function M.open_file(path, line, col)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    if line and col then
        pcall(vim.api.nvim_win_set_cursor, 0, { line, math.max(col - 1, 0) })
    end
end

return M
