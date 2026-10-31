-- lua/neo/plugins/lc/tests/helpers.lua
-- Helpers for the tests: a fresh lc workspace for each test, assertions,
-- and waiting for runs.

local M = {}

M.n = 0
M.notes = {}

local orig = { notify = vim.notify, select = vim.ui.select }

local function write_file(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

--- Finds lc and its problems, before anything moves XDG_DATA_HOME: LC, else
--- lc on PATH; LC_PROBLEMS, else where lc looks for its own. Sets M.lc and
--- M.problems, or returns nil and why the tests that need lc can't run.
function M.find_lc()
    local name = (vim.env.LC or "") ~= "" and vim.env.LC or "lc"
    local lc = vim.fn.exepath(name)
    if lc == "" then
        return nil, ("%s isn't on PATH (set LC to lcclone's lc)"):format(name)
    end
    local candidates = {}
    if (vim.env.LC_PROBLEMS or "") ~= "" then
        candidates[1] = vim.env.LC_PROBLEMS
    else
        if (vim.env.XDG_DATA_HOME or "") ~= "" then
            candidates[#candidates + 1] = vim.env.XDG_DATA_HOME .. "/lcclone/problems"
        end
        candidates[#candidates + 1] = vim.fs.normalize("~/.local/share/lcclone/problems")
        -- the problems installed beside lc: <prefix>/bin/lc, <prefix>/share/lcclone
        candidates[#candidates + 1] = vim.fs.dirname(vim.fs.dirname(lc)) .. "/share/lcclone/problems"
    end
    for _, dir in ipairs(candidates) do
        if vim.fn.isdirectory(dir) == 1 then
            M.lc = vim.fn.fnamemodify(lc, ":p")
            M.problems = vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")
            vim.env.LC_PROBLEMS = M.problems
            return true
        end
    end
    return nil, "no problems for lc (set LC_PROBLEMS to lcclone's problems directory)"
end

--- root is plugins/lc in the checkout; rtp the runtimepath entry whose
--- lua/neo is the checkout (the subprocess test loads the plugin from it).
function M.init(root, rtp)
    M.root, M.rtp = root, rtp

    -- lc sees only what the tests set up: no config, data or cache of yours.
    M.tmp = vim.fn.fnamemodify(vim.fn.tempname(), ":p")
    vim.fn.mkdir(M.tmp, "p")
    write_file(M.tmp .. "/config", "")
    vim.env.LC_CONFIG = M.tmp .. "/config"
    vim.env.XDG_CACHE_HOME = M.tmp .. "/cache"
    vim.env.LC_CXXSTD = nil
    vim.env.LC_CSTD = nil
    vim.env.PAGER = "cat"
    -- Nor your overrides.lua: tests that need one set it.
    package.loaded["neo.overrides"] = {}

    M.cwd = vim.fn.getcwd()
end

--- Called before each test.
function M.reset()
    local run = require("neo.plugins.lc.run")
    if run.current and run.current.proc then
        run.current.superseded = true
        pcall(run.current.proc.kill, run.current.proc, 9)
    end
    run.current, run.last = nil, nil
    vim.cmd("cd " .. vim.fn.fnameescape(M.cwd))
    -- A picker a test left open may have started insert mode.
    local open = require("neo.plugins.picker").current()
    if open then
        open:close()
    end
    if vim.api.nvim_get_mode().mode ~= "n" then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true), "nx", false)
    end
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.fn.setqflist({}, "f")
    vim.diagnostic.reset()
    local cli = require("neo.plugins.lc.cli")
    cli.std.c, cli.std.cpp = nil, nil
    require("neo.plugins.lc.catalog").invalidate()
    package.loaded["neo.overrides"] = {}
    vim.g.lc = nil
    -- Without lc, a cmd that fails fast: the unit tests then see no
    -- catalog, as on a machine without lc.
    require("neo.plugins.lc").setup({ cmd = M.lc or (M.tmp .. "/no-lc"), picker = "select" })

    M.n = M.n + 1
    M.workspace = ("%s/ws-%d"):format(M.tmp, M.n)
    vim.env.LC_WORKSPACE = M.workspace
    vim.env.XDG_DATA_HOME = ("%s/data-%d"):format(M.tmp, M.n)

    M.notes = {}
    vim.notify = function(msg, level)
        M.notes[#M.notes + 1] = { msg = msg, level = level or vim.log.levels.INFO }
    end
    vim.ui.select = orig.select
end

function M.finish()
    vim.notify = orig.notify
    if M.tmp then
        vim.fn.delete(M.tmp, "rf")
    end
end

-- ------------------------------------------------------------------
-- Assertions

function M.skip(why)
    error({ skip = why }, 0)
end

function M.eq(got, want, what)
    if not vim.deep_equal(got, want) then
        error(("%s\n  want: %s\n   got: %s"):format(what or "not equal", vim.inspect(want), vim.inspect(got)), 2)
    end
end

function M.ok(v, what)
    if not v then
        error(what or "assertion failed", 2)
    end
    return v
end

--- Asserts that text (a string or a list of lines) contains s.
function M.has(text, s, what)
    if type(text) == "table" then
        text = table.concat(text, "\n")
    end
    if not text:find(s, 1, true) then
        error(("%s\n  want: %q\n    in: %s"):format(what or "text not found", s, text), 2)
    end
end

function M.hasnt(text, s, what)
    if type(text) == "table" then
        text = table.concat(text, "\n")
    end
    if text:find(s, 1, true) then
        error(("%s\n  don't want: %q\n          in: %s"):format(what or "text found", s, text), 2)
    end
end

--- Fails if any note is an error.
function M.no_errors()
    for _, n in ipairs(M.notes) do
        if n.level >= vim.log.levels.ERROR then
            error("an error was shown: " .. n.msg, 2)
        end
    end
end

--- The note (vim.notify message) that contains s, failing without one.
function M.note(s)
    for _, n in ipairs(M.notes) do
        if n.msg:find(s, 1, true) then
            return n
        end
    end
    local all = vim.tbl_map(function(n)
        return n.msg
    end, M.notes)
    error(("no message %q among %s"):format(s, vim.inspect(all)), 2)
end

-- ------------------------------------------------------------------
-- Buffers, files and runs

function M.lines(buf)
    return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end

function M.read(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local s = f:read("*a")
    f:close()
    return s
end

M.write = write_file

--- A stand-in for lc: a shell script with this body, as an executable
--- file. Returns its path.
function M.fake_lc(body)
    local path = ("%s/fake-lc-%d"):format(M.tmp, M.n)
    write_file(path, "#!/bin/sh\n" .. body .. "\n")
    vim.uv.fs_chmod(path, 493) -- 0755
    return path
end

function M.fixture(name)
    return assert(M.read(M.root .. "/tests/fixtures/" .. name), "no fixture " .. name)
end

--- :Lc start, then the solution's text replaced by a fixture's (written).
--- Returns the solution's path.
function M.start(spec, lang, fixture)
    vim.cmd(("Lc start %s %s"):format(spec, lang or ""))
    local path = vim.api.nvim_buf_get_name(0)
    M.ok(path:match("/solution%.c[p]*$"), "Lc start didn't open a solution: " .. path)
    if fixture then
        local text = fixture:find("\n") and fixture or M.fixture(fixture)
        vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(text:gsub("\n$", ""), "\n"))
        vim.cmd("silent write")
    end
    return path
end

function M.wait(cond, what, timeout)
    if not vim.wait(timeout or 60000, cond, 20) then
        error("timed out waiting for " .. (what or "a condition"), 2)
    end
end

--- Runs an Ex command that starts a run and waits for it to end. Returns
--- the LcRunDone event's data.
function M.run(cmd, timeout)
    local data
    local id = vim.api.nvim_create_autocmd("User", {
        pattern = "LcRunDone",
        once = true,
        callback = function(ev)
            data = ev.data
        end,
    })
    vim.cmd(cmd)
    if not vim.wait(timeout or 180000, function()
        return data ~= nil
    end, 20) then
        pcall(vim.api.nvim_del_autocmd, id)
        error("the run didn't finish: " .. cmd, 2)
    end
    return data
end

function M.result_buf()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b) == "lc://result" then
            return b
        end
    end
    error("no result buffer", 2)
end

function M.result_win()
    local buf = M.result_buf()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(w) == buf then
            return w
        end
    end
    error("no result window", 2)
end

--- Puts the cursor in the result window on the first line containing s.
function M.cursor_on(s)
    local win = M.result_win()
    vim.api.nvim_set_current_win(win)
    for i, l in ipairs(M.lines(M.result_buf())) do
        if l:find(s, 1, true) then
            vim.api.nvim_win_set_cursor(win, { i, 0 })
            return i
        end
    end
    error(("no line %q in the result buffer"):format(s), 2)
end

--- Presses keys in normal mode, as typed.
function M.keys(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
end

--- The diagnostics lc set on a file's buffer.
function M.diagnostics(path)
    local buf = require("neo.plugins.lc.problem").find_buf(path)
    return buf and vim.diagnostic.get(buf, { namespace = require("neo.plugins.lc.run").diag_ns }) or {}
end

return M
