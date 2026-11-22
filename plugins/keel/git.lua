-- lua/neo/plugins/keel/git.lua
-- Running git. Every call is an argv list through jobstart: on Neovim 0.10
-- vim.system can lose the end of a process's output.
--
--   git.run(root, args, { stdin = text }, function(result) ... end)
--   git.mutate(...)   the same, but one at a time per repository
--   git.all(root, list_of_args, function(results) ... end)
--
-- result = { code, stdout, stderr }, with stdout and stderr as raw bytes.
local M = {}

-- Background commands must never block on a prompt or take the index lock
-- for an optional refresh, and a path like `*.c` or `:x` is only ever a path.
local ENV = {
    GIT_OPTIONAL_LOCKS = "0",
    GIT_TERMINAL_PROMPT = "0",
    GIT_LITERAL_PATHSPECS = "1",
}

-- For commands that run the repository's hooks: a hook's own git commands
-- may use pathspec magic, which the literal setting would silently change.
local HOOK_ENV = { GIT_TERMINAL_PROMPT = "0" }

local BASE = { "git", "-c", "core.quotePath=false", "-c", "color.ui=false" }

local running = 0
local queues = {}

-- A job's output arrives split on newlines, with each NUL turned into "\n".
local function raw(data)
    local parts = {}
    for i, part in ipairs(data or {}) do
        parts[i] = part:gsub("\n", "\0")
    end
    return table.concat(parts, "\n")
end

function M.run(root, args, opts, callback)
    opts = opts or {}
    local argv = vim.list_extend(vim.deepcopy(BASE), args)
    local out, err = {}, {}
    running = running + 1
    local ok, id = pcall(vim.fn.jobstart, argv, {
        cwd = root,
        env = opts.hooks and HOOK_ENV or ENV,
        stdin = opts.stdin and "pipe" or "null",
        stdout_buffered = true,
        stderr_buffered = true,
        on_stdout = function(_, data) out = data end,
        on_stderr = function(_, data) err = data end,
        on_exit = function(_, code)
            running = running - 1
            callback({ code = code, stdout = raw(out), stderr = raw(err) })
        end,
    })
    if not ok or type(id) ~= "number" or id <= 0 then
        running = running - 1
        local message = ok and "can't run git" or tostring(id)
        vim.schedule(function()
            callback({ code = -1, stdout = "", stderr = message })
        end)
        return
    end
    if opts.stdin then
        vim.fn.chansend(id, opts.stdin)
        vim.fn.chanclose(id, "stdin")
    end
end

--- Runs git and waits. Only for quick lookups.
function M.run_sync(cwd, args, timeout)
    local result
    M.run(cwd, args, {}, function(r) result = r end)
    vim.wait(timeout or 5000, function() return result ~= nil end, 5)
    return result or { code = -1, stdout = "", stderr = "git took too long" }
end

--- Queues a command that changes the repository, so two never overlap.
function M.mutate(root, args, opts, callback)
    local queue = queues[root] or {}
    queues[root] = queue
    queue[#queue + 1] = function()
        M.run(root, args, opts, function(result)
            local ok, err = pcall(callback, result)
            table.remove(queue, 1)
            if queue[1] then queue[1]() end
            if not ok then error(err, 0) end
        end)
    end
    if #queue == 1 then queue[1]() end
end

--- Runs several commands at once. results[i] belongs to list[i].
function M.all(root, list, callback)
    if #list == 0 then
        callback({})
        return
    end
    local results, left = {}, #list
    for i, args in ipairs(list) do
        M.run(root, args, {}, function(result)
            results[i] = result
            left = left - 1
            if left == 0 then callback(results) end
        end)
    end
end

--- Counts work that isn't a M.run job (a terminal) toward M.idle.
function M.hold()
    running = running + 1
end

function M.release()
    running = running - 1
end

function M.idle()
    if running > 0 then return false end
    for _, queue in pairs(queues) do
        if #queue > 0 then return false end
    end
    return true
end

--- The repository containing dir: { root, gitdir }, or nil.
function M.find(dir)
    if vim.fn.isdirectory(dir) ~= 1 then return nil end
    local result = M.run_sync(dir, { "rev-parse", "--show-toplevel", "--absolute-git-dir" })
    if result.code ~= 0 then return nil end
    local lines = vim.split(vim.trim(result.stdout), "\n", { plain = true })
    if not lines[1] or lines[1] == "" or not lines[2] then return nil end
    return {
        root = vim.fs.normalize((lines[1]:gsub("\r$", ""))),
        gitdir = vim.fs.normalize((lines[2]:gsub("\r$", ""))),
    }
end

--- Picks up files git just rewrote. Each buffer is checked by number: a bare
--- :checktime can put the check off and leave hidden buffers stale. Buffers
--- with unsaved edits are left for Neovim's usual warning.
function M.reload_buffers()
    vim.schedule(function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == ""
                and not vim.bo[buf].modified and vim.api.nvim_buf_get_name(buf) ~= "" then
                pcall(vim.cmd, "silent! checktime " .. buf)
            end
        end
    end)
end

function M.notify(message, level)
    vim.notify("keel: " .. message, level or vim.log.levels.INFO)
end

--- Reports a failed command with git's own explanation.
function M.fail(what, result)
    local detail = vim.trim(result.stderr or "")
    if detail == "" then detail = vim.trim(result.stdout or "") end
    M.notify(what .. " failed" .. (detail ~= "" and (":\n" .. detail) or ""), vim.log.levels.ERROR)
end

return M
