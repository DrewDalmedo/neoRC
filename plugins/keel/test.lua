-- lua/neo/plugins/keel/test.lua
-- Run from anywhere: nvim -l path/to/plugins/keel/test.lua
-- Standalone: neo.* requires resolve relative to this file, and git runs
-- without your global config, in temporary repositories.
--
-- Runs every file in tests/. Each returns function(t), with:
--   t.eq(desc, got, want), t.ok(desc, cond)
--   t.repo(files)     a new repository with `files` committed; returns root
--   t.git(root, ...)  runs git, returns stdout (fails the test on error)
--   t.write(root, path, text), t.read(root, path), t.index(root, path)
--   t.child(fn)       a separate Neovim that takes real keystrokes:
--                     c.keys, c.lua, c.mode, c.settle, c.open(root),
--                     c.lines(), c.jump(text)
local here = debug.getinfo(1, "S").source:sub(2):match("(.*)[/\\]")
local root = vim.fn.fnamemodify(here .. "/../..", ":p")

local LOADER = [[
local root = ...
table.insert(package.loaders or package.searchers, 2, function(name)
    local rel = name:match("^neo%.(.+)$")
    if not rel then return end
    local base = root .. "/" .. rel:gsub("%.", "/")
    for _, cand in ipairs({ base .. ".lua", base .. "/init.lua" }) do
        local f = io.open(cand, "r")
        if f then
            f:close()
            return function() return dofile(cand) end
        end
    end
end)
]]
assert(loadstring(LOADER))(root)

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
tmp = vim.fs.normalize(vim.uv.fs_realpath(tmp))

-- Neither the user's git config nor the system's reaches the tests.
local empty_config = tmp .. "/gitconfig"
vim.fn.writefile({
    "[user]", "name = Keel Test", "email = keel@example.invalid",
    "[init]", "defaultBranch = main",
    "[commit]", "gpgsign = false",
    "[core]", "autocrlf = false",
}, empty_config)
vim.env.GIT_CONFIG_GLOBAL = empty_config
vim.env.GIT_CONFIG_NOSYSTEM = "1"

local passed, failures = 0, {}
local t = { tmp = tmp }

local function out(text)
    io.stdout:write(text .. "\n")
end

local function record(desc, good, detail)
    if good then
        passed = passed + 1
        out("ok   " .. desc)
    else
        failures[#failures + 1] = desc
        out("FAIL " .. desc .. (detail and (": " .. detail) or ""))
    end
end

function t.eq(desc, got, want)
    record(desc, vim.deep_equal(got, want),
        ("got=%s want=%s"):format(vim.inspect(got), vim.inspect(want)))
end

function t.ok(desc, cond)
    record(desc, not not cond)
end

function t.write(repo, path, text)
    local full = repo .. "/" .. path
    vim.fn.mkdir(vim.fs.dirname(full), "p")
    local f = assert(io.open(full, "wb"))
    f:write(text)
    f:close()
end

function t.read(repo, path)
    local f = io.open(repo .. "/" .. path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

function t.git(repo, ...)
    local result = vim.system({ "git", ... }, { cwd = repo, text = false }):wait()
    if result.code ~= 0 then
        error(("git %s: %s"):format(table.concat({ ... }, " "), result.stderr), 0)
    end
    return result.stdout
end

function t.index(repo, path)
    return t.git(repo, "show", ":" .. path)
end

local count = 0
function t.repo(files)
    count = count + 1
    local repo = tmp .. "/repo" .. count
    vim.fn.mkdir(repo, "p")
    t.git(repo, "init", "-q")
    if files then
        for path, text in pairs(files) do t.write(repo, path, text) end
        t.git(repo, "add", "-A")
        t.git(repo, "commit", "-qm", "base")
    end
    return repo
end

function t.child(fn)
    local chan = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "--clean", "-n" }, { rpc = true })
    local c = {}
    function c.lua(code, ...)
        return vim.rpcrequest(chan, "nvim_exec_lua", code, { ... })
    end
    -- A terminal can close during one of these requests. Neovim only leaves
    -- Terminal mode, and draws the render it held back, after the request
    -- returns and no other is queued, so the pause has to happen out here.
    function c.settle()
        for _ = 1, 200 do
            local settled = c.lua([[
                local status = require("neo.plugins.keel.status")
                vim.wait(30000, function() return status.idle() end, 5)
                vim.wait(20)
                local leaving_terminal = vim.fn.mode(1) == "t" and vim.bo.buftype ~= "terminal"
                return status.idle() and not leaving_terminal
            ]])
            if settled then return end
            vim.wait(10)
        end
    end
    function c.keys(keys)
        vim.rpcrequest(chan, "nvim_input", keys)
        c.lua("vim.wait(20)")
        c.settle()
    end
    function c.mode()
        return c.lua("return vim.fn.mode(1)")
    end
    function c.lines()
        return c.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)")
    end
    --- Puts the cursor on the first line containing text; returns its row.
    function c.jump(text)
        return c.lua([[
            local text = ...
            for row, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
                if line:find(text, 1, true) then
                    vim.api.nvim_win_set_cursor(0, { row, 0 })
                    return row
                end
            end
            return 0
        ]], text)
    end
    function c.has(text)
        for _, line in ipairs(c.lines()) do
            if line:find(text, 1, true) then return true end
        end
        return false
    end
    function c.open(repo)
        c.lua([[
            local repo = ...
            vim.cmd("cd " .. vim.fn.fnameescape(repo))
            _G.notes = {}
            local real = vim.notify
            vim.notify = function(message, level)
                table.insert(notes, message)
            end
            require("neo.plugins.keel").setup()
            require("neo.plugins.keel").open()
        ]], repo)
        c.settle()
    end
    c.lua(LOADER, root)
    local ok, err = xpcall(fn, debug.traceback, c)
    pcall(vim.fn.jobstop, chan)
    vim.fn.jobwait({ chan }, 2000)
    if not ok then error(err, 0) end
end

local files = vim.fn.glob(here .. "/tests/*.lua", true, true)
table.sort(files)
for _, file in ipairs(files) do
    local name = vim.fn.fnamemodify(file, ":t:r")
    out("-- " .. name)
    local ok, err = xpcall(function()
        dofile(file)(t)
    end, debug.traceback)
    record(name .. " finished", ok, not ok and err or nil)
end

vim.fn.delete(tmp, "rf")
out(("\n%d passed, %d failed"):format(passed, #failures))
for _, desc in ipairs(failures) do
    out("  failed: " .. desc)
end
-- (:cquit rather than os.exit, which skips Neovim's own cleanup; and as a
-- string, since vim.cmd.cquit(n) is an error before Neovim 0.12.)
vim.cmd("cquit " .. (#failures == 0 and 0 or 1))
