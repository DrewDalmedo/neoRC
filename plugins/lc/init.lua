-- lua/neo/plugins/lc/init.lua
-- lc: lcclone, the offline LeetCode-style practice tool, from Neovim.
-- Ported from lc.nvim (github.com/DrewDalmedo/lc.nvim). It only runs
-- `lc ... --json` and reads what that prints (lcclone's docs/json.md), so
-- everything it shows comes from lc itself.
--
-- setup() loads nothing on native Windows (WSL counts as Linux) or when
-- the lc command isn't executable, and M.enabled says whether it loaded;
-- keybinds/lc.lua maps keys only then. Otherwise it defines :Lc, and the
-- other modules load when a command first runs.
--
-- :Lc {command} [args] (<Tab> completes; :Lc alone is :Lc list)
--   list [--difficulty L] [--tag T] [--status S]
--                          pick a problem; choosing one starts it
--   random [filters]       open one at random: :Lc random --status todo
--   show [problem]         its statement, in a markdown buffer
--   start [problem] [c|cpp]
--                          set it up (lc start) and open the solution,
--                          with the statement beside it
--   test [solution] [--std STD] [--sanitize] [--case FILE] [--lang LANG]
--                          build it and run the examples and your cases,
--                          in the background
--   submit [solution] [--std STD] [--sanitize] [--lang LANG]
--                          run every case, stopping at the first failure,
--                          and record the submission
--   cancel                 stop the run, as ^C; a second one kills lc
--   result                 open the last run's result window again
--   stats                  solved and attempted, by difficulty and tag
--   std [c|cpp] {std}      the standard for this session: c++17, c11, max,
--                          or default for lc's own; no argument shows them
-- A problem is its number (1), slug (two-sum) or directory (0001-two-sum).
-- Without one, a command uses the current buffer's: a solution, README.md
-- or cases.txt in a problem's directory, or one of lc's own buffers.
-- Starting a run while one is going on stops the first.
--
-- The result window (lc://result, at the bottom) shows the verdict, a line
-- per case, and each failure's input, output, expected output, stdout and
-- stderr. Its keys: a adds the case under the cursor to cases.txt, <CR>
-- goes to what the line is about, r runs again, <C-c> cancels, q closes.
-- Compile errors and sanitizer reports become vim.diagnostic entries on
-- the solution (source "lc"). They and the failed cases also fill the
-- quickfix list, replacing the last run's list but never one of yours.
--
-- Options, each layer over the one before: the defaults (config.lua), the
-- lc section of overrides.lua, vim.g.lc, then setup(opts):
--   return { lc = { cmd = "~/.local/bin/lc", open = "show" } }
-- cmd is a string, or a list for a command with arguments, and a leading
-- "~/" expands. picker is "neo" (neo.plugins.picker) or "select"
-- (vim.ui.select). The compilers, standards, workspace and the language
-- of new problems are lcclone's own settings, in ~/.config/lcclone/config.
--
-- For a statusline, M.status() is "" or something like "lc test: 3/16".
-- User autocmds LcRunStart and LcRunDone fire around each run. Their data
-- holds kind, target and problem, and for LcRunDone also verdict (lc's,
-- such as "accepted"; "none" when cancelled first; "error" when lc
-- failed), cancelled, error, passed, total and solution.
--
-- :checkhealth neo.plugins.lc checks lc, its problems and the picker. The
-- tests: nvim -l path/to/plugins/lc/test.lua (see there).

local M = {}

--- Whether setup() loaded lc: false on Windows or without lc.
M.enabled = false

local function cli()
    return require("neo.plugins.lc.cli")
end
local function config()
    return require("neo.plugins.lc.config")
end
local function ui()
    return require("neo.plugins.lc.ui")
end
local function problem()
    return require("neo.plugins.lc.problem")
end

local function fail(err)
    ui().error("lc: " .. err)
end

-- `lc <args> --json`, with its warnings shown; nil after an error, which
-- is shown too, with the warnings that can explain it (a skipped pack).
local function json(args)
    local doc, err, errdoc = cli().json(args)
    ui().warn_doc(doc or errdoc)
    if not doc then
        fail(err)
    end
    return doc
end

-- Native Windows only: WSL is Linux to Neovim (has("wsl"), not "win32").
local function on_windows()
    return vim.fn.has("win32") == 1
end

--- Sets the options and defines :Lc, unless lc can't run here: on native
--- Windows, or when the lc command (the cmd option) isn't executable.
--- Then :Lc is removed if an earlier call defined it. Returns whether lc
--- is loaded, which M.enabled keeps too.
function M.setup(opts)
    M.enabled = false
    if not on_windows() and vim.fn.has("nvim-0.10") == 1 then
        local ok, err = pcall(config().setup, opts)
        if not ok then
            -- A typo in overrides.lua mustn't stop the rest of the config.
            vim.notify(tostring(err), vim.log.levels.ERROR, { title = "lc" })
        elseif vim.fn.executable(cli().argv({})[1]) == 1 then
            M.enabled = true
        end
    end
    if not M.enabled then
        pcall(vim.api.nvim_del_user_command, "Lc")
        return false
    end
    vim.api.nvim_create_user_command("Lc", function(o)
        require("neo.plugins.lc.commands").run(o)
    end, {
        nargs = "*",
        bar = true,
        desc = "lcclone: list, show, start, test and submit problems",
        complete = function(lead, cmdline, pos)
            return require("neo.plugins.lc.commands").complete(lead, cmdline, pos)
        end,
    })
    return true
end

--- What choosing a problem in :Lc list or :Lc random does.
function M.open(p)
    if config().get().open == "show" then
        return M.show(tostring(p.id))
    end
    return M.start(tostring(p.id))
end

--- :Lc list: a picker over the problems that pass lc list's filters.
function M.list(fargs)
    local doc = json(vim.list_extend({ "list" }, fargs or {}))
    if not doc then
        return
    end
    if #(doc.problems or {}) == 0 then
        ui().notify("lc: no problem matches")
        return
    end
    require("neo.plugins.lc.picker").pick(doc.problems, { title = "Problems" }, M.open)
end

--- :Lc random: one of the problems that pass the filters, opened.
function M.random(fargs)
    local doc = json(vim.list_extend({ "random" }, fargs or {}))
    if not doc then
        return
    end
    return M.open(doc.problem)
end

local function current_problem(what)
    local info = problem().from_buf(0)
    if not info then
        fail(("this buffer isn't in a problem's directory: name a problem, as in :Lc %s 1"):format(what))
        return nil
    end
    return tostring(info.id), info
end

--- :Lc show: a problem's statement in a markdown buffer. Without spec, the
--- current buffer's problem. Returns the buffer and window.
function M.show(spec)
    if not spec or spec == "" then
        spec = current_problem("show")
        if not spec then
            return
        end
    end
    local doc = json({ "show", spec })
    if not doc then
        return
    end
    local p = doc.problem
    local buf = ui().scratch(("lc://problem/%04d-%s"):format(p.id, p.slug), "markdown")
    ui().set_lines(buf, require("neo.plugins.lc.statement").markdown(p))
    vim.b[buf].lc_problem = { id = p.id, slug = p.slug }
    local win, err = ui().show(buf, config().get().statement or "leftabove vsplit", "lc_statement")
    if not win then
        return fail(err)
    end
    return buf, win
end

--- :Lc start: sets up a problem's directory (lc start) and opens its
--- solution, with the statement beside it. Without spec, the current
--- buffer's problem. lang is "c" or "cpp", or nil to let lc choose.
function M.start(spec, lang)
    if not spec or spec == "" then
        spec = current_problem("start")
        if not spec then
            return
        end
    end
    local args = { "start", spec }
    if lang then
        vim.list_extend(args, { "--lang", lang })
    end
    local doc = json(args)
    if not doc then
        return
    end
    problem().remember(doc.dir, doc.problem.id)

    -- The window showing the solution already, else one for editing.
    local sol = problem().find_buf(doc.solution)
    local win = sol and ui().win_showing(sol) or ui().edit_win()
    local ok, e = ui().edit(win, doc.solution)
    if not ok then
        return fail(e)
    end

    local split = config().get().statement
    if split then
        local readme = vim.fn.bufadd(doc.readme)
        vim.bo[readme].buflisted = true
        local swin, serr = ui().show(readme, split, "lc_statement")
        if not swin then
            fail("couldn't open the statement: " .. serr)
        end
        -- lc start has just rewritten it. (With changes of your own, checktime
        -- would ask what to do.)
        if not vim.bo[readme].modified then
            pcall(vim.cmd, "checktime " .. readme)
        end
    end
    return doc
end

--- :Lc test and :Lc submit, with the arguments of lc test and lc submit.
function M.test(fargs)
    return require("neo.plugins.lc.run").start("test", fargs)
end

function M.submit(fargs)
    return require("neo.plugins.lc.run").start("submit", fargs)
end

--- :Lc cancel: stops the run going on.
function M.cancel()
    require("neo.plugins.lc.run").cancel()
end

--- :Lc result: opens the result window again.
function M.result()
    local run = require("neo.plugins.lc.run")
    if not run.last then
        ui().notify("lc: nothing has run yet")
        return
    end
    local win, err = run.open_result(true)
    if not win then
        return fail(err)
    end
    -- Its buffer may have been wiped or unloaded since.
    run.redraw()
    return win
end

--- Adds the case under the cursor in the result buffer to cases.txt.
function M.add_case()
    require("neo.plugins.lc.run").add_case()
end

--- :Lc stats: what you have solved, by difficulty and tag.
function M.stats()
    local doc = json({ "stats" })
    if not doc then
        return
    end
    local lines, hls = {}, {}
    local function add(text, hl)
        lines[#lines + 1] = text
        if hl then
            hls[#lines] = hl
        end
    end
    local s = ("Solved %d of %d problems"):format(doc.solved or 0, doc.total or 0)
    if (doc.attempted or 0) > 0 then
        s = s .. (", attempted %d more"):format(doc.attempted)
    end
    add(s, "LcTitle")
    local function table_of(title, rows, key)
        add("")
        add(("%-24s %6s %9s %6s"):format(title, "Solved", "Attempted", "Total"), "LcLabel")
        for _, r in ipairs(rows or {}) do
            local name = r[key]
            if key == "difficulty" then
                name = name:sub(1, 1):upper() .. name:sub(2)
            end
            add(("%-24s %6d %9d %6d"):format(name, r.solved or 0, r.attempted or 0, r.total or 0))
        end
    end
    table_of("Difficulty", doc.difficulties, "difficulty")
    table_of("Tag", doc.tags, "tag")

    local buf = ui().scratch("lc://stats", "lcstats")
    ui().set_lines(buf, lines)
    vim.api.nvim_buf_clear_namespace(buf, ui().ns, 0, -1)
    for lnum, hl in pairs(hls) do
        vim.api.nvim_buf_set_extmark(buf, ui().ns, lnum - 1, 0, { end_col = #lines[lnum], hl_group = hl })
    end
    if not vim.b[buf].lc_keys then
        local close = config().get().keys.close
        if close then
            vim.keymap.set("n", close, function()
                if not pcall(vim.api.nvim_win_close, 0, false) then
                    vim.cmd("enew")
                end
            end, { buffer = buf, nowait = true, desc = "lc: close the window" })
        end
        vim.b[buf].lc_keys = true
    end
    local win, perr = ui().panel(buf, config().get().result or "botright 15split")
    if not win then
        return fail(perr)
    end
    return buf, win
end

local STDS = {
    c = { "c99", "c11", "c17", "c23", "max" },
    cpp = { "c++11", "c++14", "c++17", "c++20", "c++23", "max" },
}
M.STDS = STDS

local function std_summary()
    local function one(lang, name)
        local v = cli().std[lang]
        return ("%s: %s"):format(name, v and (v .. " (this session)") or "lc's setting")
    end
    return one("cpp", "C++") .. " · " .. one("c", "C")
end

--- :Lc std: the language standard for this session's runs, passed to lc
--- as LC_CXXSTD and LC_CSTD. Arguments: [c|cpp] STD, where STD is a
--- standard, max, or default (back to lc's setting). Without arguments,
--- shows the standards in use.
function M.std(fargs)
    fargs = fargs or {}
    if #fargs == 0 then
        ui().notify("lc: " .. std_summary())
        return
    end
    local lang, value
    if #fargs >= 2 then
        lang, value = fargs[1], fargs[2]
        if lang == "c++" or lang == "cxx" then
            lang = "cpp"
        end
        if lang ~= "c" and lang ~= "cpp" then
            return fail(("unknown language '%s': c or cpp"):format(lang))
        end
    else
        value = fargs[1]
        if value:match("^c%+%+") then
            lang = "cpp"
        elseif value:match("^c%d") then
            lang = "c"
        elseif value == "max" or value == "default" then
            lang = nil -- both
        else
            return fail(("unknown standard '%s'"):format(value))
        end
    end
    for _, l in ipairs(lang and { lang } or { "c", "cpp" }) do
        if value ~= "default" and not vim.tbl_contains(STDS[l], value) then
            return fail(("unknown standard '%s': %s"):format(value, table.concat(STDS[l], ", ")))
        end
    end
    for _, l in ipairs(lang and { lang } or { "c", "cpp" }) do
        cli().std[l] = value ~= "default" and value or nil
    end
    ui().notify("lc: " .. std_summary() .. ". clangd follows on the next :Lc start.")
end

--- The run going on, for a statusline: "" when there is none, else
--- something like "lc test: 3/16".
function M.status()
    return require("neo.plugins.lc.run").status()
end

return M
