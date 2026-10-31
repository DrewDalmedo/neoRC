-- lua/neo/plugins/lc/test.lua
-- Run from anywhere: nvim -l path/to/plugins/lc/test.lua [PATTERN...]
--
-- tests/unit.lua needs no lc and always runs. tests/commands.lua, start.lua
-- and run.lua drive :Lc against lcclone's real lc, and run when it is
-- there: LC names the binary (else lc on PATH), LC_PROBLEMS its problems
-- (else where lc keeps them: $XDG_DATA_HOME/lcclone/problems,
-- ~/.local/share/lcclone/problems, or beside lc's install prefix). They
-- also need a C and C++ compiler, as lc does. PATTERNs (Lua patterns) keep
-- the tests whose "file: name" matches one of them, e.g. "run: submit".
--
-- Every test gets a fresh workspace, data dir and empty lc config in a
-- temporary directory, so your own progress and settings are never seen
-- or touched; overrides.lua is left out too.
--
-- Standalone: the checkout is linked as lua/neo into a temporary
-- runtimepath entry, so neo.* requires and :checkhealth neo.plugins.lc
-- resolve to this checkout whatever its directory is called, and an
-- installed copy of the config never shadows it.

local function out(s)
    io.stdout:write(s)
    io.stdout:flush()
end

if vim.fn.has("win32") == 1 then
    out("skip: lc is off on native Windows\n")
    return
end

local here = vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
local root = vim.fs.dirname(vim.fs.dirname(here))

local rtp = vim.fn.tempname()
vim.fn.mkdir(rtp .. "/lua", "p")
assert(vim.uv.fs_symlink(root, rtp .. "/lua/neo"))
vim.opt.rtp:prepend(rtp)
-- Plain nvim -l (unlike --clean -l) detects no filetypes, which the
-- tests check; and it sets 'verbose', which echoes every message, while
-- the runner prints its own.
vim.cmd("filetype plugin indent on")
vim.o.verbose = 0
vim.o.shortmess = vim.o.shortmess .. "F"

local H = require("neo.plugins.lc.tests.helpers")
local have_lc, why = H.find_lc()
H.init(here, rtp)

local suites = { "unit" }
if have_lc then
    vim.list_extend(suites, { "commands", "start", "run" })
    out(("lc: %s, problems in %s\n"):format(H.lc, H.problems))
else
    out(("skip: the tests against lc (commands, start, run): %s\n"):format(why))
end

local patterns = {}
for _, a in ipairs(arg) do
    if a ~= "" then
        patterns[#patterns + 1] = a
    end
end
local function wanted(name)
    if #patterns == 0 then
        return true
    end
    for _, p in ipairs(patterns) do
        if name:match(p) then
            return true
        end
    end
    return false
end

local passed, failures, skipped = 0, {}, 0
for _, suite in ipairs(suites) do
    for _, t in ipairs(require("neo.plugins.lc.tests." .. suite)) do
        local full = ("%s: %s"):format(suite, t[1])
        if wanted(full) then
            H.reset()
            local t0 = vim.uv.hrtime()
            local good, err = xpcall(t[2], function(e)
                if type(e) == "table" and e.skip then
                    return e
                end
                return debug.traceback(tostring(e), 2)
            end)
            local ms = (vim.uv.hrtime() - t0) / 1e6
            if good then
                passed = passed + 1
                out(("ok   %s (%d ms)\n"):format(full, ms))
            elseif type(err) == "table" and err.skip then
                skipped = skipped + 1
                out(("skip %s: %s\n"):format(full, err.skip))
            else
                failures[#failures + 1] = full
                out(("FAIL %s\n%s\n"):format(full, err))
            end
        end
    end
end

H.finish()
-- The link goes first, so that deleting the directory can't reach the
-- checkout through it.
if vim.uv.fs_unlink(rtp .. "/lua/neo") then
    vim.fn.delete(rtp, "rf")
end
out(("\n%d passed, %d failed, %d skipped\n"):format(passed, #failures, skipped))
for _, f in ipairs(failures) do
    out("  failed: " .. f .. "\n")
end
-- (:cquit rather than os.exit, which skips Neovim's own cleanup; and as a
-- string, since vim.cmd.cquit(n) is an error before Neovim 0.12.)
vim.cmd("cquit " .. (#failures == 0 and 0 or 1))
