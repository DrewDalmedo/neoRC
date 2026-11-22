-- lua/neo/plugins/malleable/test.lua
-- Run from anywhere: nvim -l path/to/plugins/malleable/test.lua
-- Standalone: neo.* requires resolve relative to this file, so no rtp setup
-- is needed and an installed copy of the config never shadows this checkout.
--
-- Runs every file in tests/. Each returns function(t), with:
--   t.eq(desc, got, want)   deep comparison
--   t.ok(desc, cond)
--   t.child(fn)             runs fn(c) against a separate Neovim that takes
--                           real keystrokes, which `nvim -l` itself can't:
--                           c.keys(str), c.lua(code, ...), c.mode(),
--                           c.settle()
local here = debug.getinfo(1, "S").source:sub(2):match("(.*)[/\\]")
local root = vim.fn.fnamemodify(here .. "/../..", ":p")

-- Also sent to each child, so it has to stand alone.
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

local passed, failures = 0, {}
local t = {}

-- (print goes through the message area, which feedkeys can leave mid-line)
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

function t.child(fn)
    local chan = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "--clean", "-n" }, { rpc = true })
    local c = {}
    function c.lua(code, ...)
        return vim.rpcrequest(chan, "nvim_exec_lua", code, { ... })
    end
    -- Lets the child's main loop take its input and scheduled callbacks.
    function c.settle()
        vim.rpcrequest(chan, "nvim_exec_lua", "vim.wait(20)", {})
    end
    function c.keys(keys)
        vim.rpcrequest(chan, "nvim_input", keys)
        c.settle()
    end
    function c.mode()
        return c.lua("return vim.fn.mode(1)")
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
    if name ~= "helpers" then
        out("-- " .. name)
        local ok, err = xpcall(function()
            dofile(file)(t)
        end, debug.traceback)
        record(name .. " finished", ok, not ok and err or nil)
    end
end

out(("\n%d passed, %d failed"):format(passed, #failures))
for _, desc in ipairs(failures) do
    out("  failed: " .. desc)
end
-- (:cquit rather than os.exit, which skips Neovim's own cleanup; and as a
-- string, since vim.cmd.cquit(n) is an error before Neovim 0.12.)
vim.cmd("cquit " .. (#failures == 0 and 0 or 1))
