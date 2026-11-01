-- lua/neo/plugins/lc/run.lua
-- :Lc test and :Lc submit: lc runs in the background, its events stream
-- into the result buffer, and compile errors, sanitizer reports and failed
-- cases become diagnostics and quickfix entries.

local catalog = require("neo.plugins.lc.catalog")
local cli = require("neo.plugins.lc.cli")
local config = require("neo.plugins.lc.config")
local problem = require("neo.plugins.lc.problem")
local ui = require("neo.plugins.lc.ui")

local M = {}

M.diag_ns = vim.api.nvim_create_namespace("lc.diagnostics")

--- The run going on, if any, and the last one started.
M.current = nil
M.last = nil

local generation = 0

-- Values and output are cut in the result buffer, as `lc test` cuts them.
local SHOW_VALUE_MAX = 1000
local SHOW_LINES = 40

local VERDICTS = {
    accepted = "Accepted",
    wrong_answer = "Wrong Answer",
    compile_error = "Compile Error",
    runtime_error = "Runtime Error",
    time_limit_exceeded = "Time Limit Exceeded",
    memory_limit_exceeded = "Memory Limit Exceeded",
    output_limit_exceeded = "Output Limit Exceeded",
    none = "Cancelled",
}

function M.verdict_name(v)
    return VERDICTS[v] or tostring(v)
end

local function verdict_hl(v)
    if v == "accepted" then
        return "LcAccepted"
    elseif v == "time_limit_exceeded" or v == "memory_limit_exceeded" or v == "output_limit_exceeded" then
        return "LcLimit"
    end
    return "LcFailed"
end

local function severity(s)
    local S = vim.diagnostic.severity
    return ({ error = S.ERROR, warning = S.WARN, note = S.INFO })[s] or S.ERROR
end

local QF_TYPE = { [1] = "E", [2] = "W", [3] = "I", [4] = "N" }

-- Flags of lc test and lc submit that take a value.
local VALUE_FLAGS = { ["--lang"] = true, ["--std"] = true, ["--case"] = true, ["--color"] = true }

-- ------------------------------------------------------------------
-- Cases

-- File names, worked out once: a result is drawn many times, with the
-- same few paths on many lines.
local basenames = {}
local function basename(path)
    local b = basenames[path]
    if not b then
        b = vim.fs.basename(path)
        basenames[path] = b
    end
    return b
end

--- "Example 2", "Case 5" or "cases.txt:12", as `lc test` labels a case.
function M.case_label(run, c)
    if c.label then
        return c.label
    elseif c.custom then
        return ("%s:%d"):format(basename(c.file or "cases.txt"), c.line or 0)
    elseif run.kind == "test" and c.example then
        return ("Example %d"):format(c.index + 1)
    end
    return ("Case %d"):format(c.index + 1)
end

--- "on example 2", "on case 7 of 16" or "on your case at cases.txt:5",
--- and " with the sanitizers" for a case that failed in lc submit's check.
local function case_where(run, c)
    local s
    if c.custom then
        s = "on your case at " .. M.case_label(run, c)
    elseif run.kind == "test" and c.example then
        s = ("on example %d"):format(c.index + 1)
    else
        s = ("on case %d of %d"):format(c.index + 1, c.total or run.total or 0)
    end
    return c.sanitizer_check and s .. " with the sanitizers" or s
end

local function failed(c)
    return c.verdict ~= "accepted"
end

local function cut(v)
    v = v or ""
    if #v <= SHOW_VALUE_MAX then
        return v
    end
    return ("%s... (%d bytes in all)"):format(v:sub(1, SHOW_VALUE_MAX), #v)
end

local function text_lines(s)
    local lines = vim.split(s, "\n", { plain = true })
    if lines[#lines] == "" then
        lines[#lines] = nil
    end
    return lines
end

--- Where a line of compiler or sanitizer output points in the solution:
--- line and column, or nil. With bare, the file's name alone counts too,
--- after a space: atos, which symbolizes sanitizer reports on macOS,
--- prints "solution.cpp:7" rather than the whole path.
local function location(line, src, bare)
    if not src then
        return nil
    end
    local at, len = line:find(src, 1, true), #src
    if not at and bare then
        local name = basename(src)
        at = line:find("%s" .. vim.pesc(name) .. ":%d")
        if at then
            at, len = at + 1, #name
        end
    end
    if not at then
        return nil
    end
    local rest = line:sub(at + len)
    local l, c = rest:match("^:(%d+):(%d+)")
    if not l then
        l = rest:match("^:(%d+)")
    end
    if not l then
        return nil
    end
    return tonumber(l), tonumber(c) or 0
end

--- The places in the solution that a sanitizer report (a case's stderr)
--- points at: { lnum, col, severity, message } with 1-based lnum and col.
function M.parse_sanitizer(text, src)
    local S = vim.diagnostic.severity
    local out = {}
    local headline, section, primary = nil, nil, false
    for line in vim.gsplit(text or "", "\n", { plain = true }) do
        local h = line:match("ERROR: (%a+Sanitizer: .-) on ") or line:match("ERROR: (%a+Sanitizer: .-)%s*$")
        if h then
            headline, section = h, nil
        elseif not line:find("^%s*#%d") then
            local s = line:match("^%s*(%S.-) here:%s*$")
            if s then
                section = s
            end
        end
        local lnum, col = location(line, src, true)
        if lnum and not line:find("SUMMARY:", 1, true) then
            local ub = line:match("runtime error: (.*)$")
            local d = { lnum = lnum, col = col }
            if ub then
                d.severity, d.message = S.ERROR, "runtime error: " .. ub
                primary = true
            elseif section then
                d.severity, d.message = S.INFO, ("%s: %s here"):format(headline or "sanitizer", section)
            elseif not primary then
                d.severity, d.message = S.ERROR, headline or "sanitizer report"
                primary = true
            else
                d.severity, d.message = S.INFO, ("%s: called from here"):format(headline or "sanitizer")
            end
            out[#out + 1] = d
        end
    end
    return out
end

-- ------------------------------------------------------------------
-- Diagnostics and quickfix

local function add_diag(run, d)
    local key = ("%d:%d:%s"):format(d.lnum, d.col, d.message)
    if run.diag_seen[key] then
        return
    end
    run.diag_seen[key] = true
    run.diags[#run.diags + 1] = d
end

local set_diagnostics
function set_diagnostics(run)
    if not config.get().diagnostics or not run.src then
        return
    end
    local buf = problem.find_buf(run.src)
    if not buf or not vim.api.nvim_buf_is_loaded(buf) then
        -- Set them when the solution is opened, if no run came since.
        if not run.diag_pending then
            run.diag_pending = true
            vim.api.nvim_create_autocmd("BufRead", {
                buffer = buf or vim.fn.bufadd(run.src),
                once = true,
                callback = function()
                    run.diag_pending = nil
                    vim.schedule(function()
                        if run == M.last then
                            set_diagnostics(run)
                        end
                    end)
                end,
            })
        end
        return
    end
    local list = {}
    for _, d in ipairs(run.diags) do
        list[#list + 1] = {
            lnum = math.max(d.lnum - 1, 0),
            col = math.max(d.col - 1, 0),
            severity = d.severity,
            message = d.message,
            source = "lc",
        }
    end
    vim.diagnostic.set(M.diag_ns, buf, list)
end

--- The place lc's error names ("<file>:<line>: ..."), when that file exists.
local function error_place(run)
    local first = run.error and run.error:match("^[^\n]*")
    local file, lnum, rest = (first or ""):match("^(.-):(%d+): (.*)$")
    if file and vim.uv.fs_stat(file) then
        return { file = file, lnum = tonumber(lnum), col = 0, text = rest }
    end
    return nil
end

local function qf_items(run)
    local items = {}
    local place = error_place(run)
    if place then
        items[#items + 1] = { filename = place.file, lnum = place.lnum, type = "E", text = place.text }
    end
    local build = run.build_done
    for _, d in ipairs(build and build.diagnostics or {}) do
        -- "error", "warning", "note": quickfix types E, W, N.
        local item = {
            lnum = d.line or 0,
            col = d.column or 0,
            type = (d.severity or "e"):sub(1, 1):upper(),
            text = d.message,
        }
        if d.in_solution or (d.file and d.file:sub(1, 1) == "/" and vim.uv.fs_stat(d.file)) then
            item.filename = d.file
        else
            item.text = ("%s:%d: %s"):format(d.file or "?", d.line or 0, d.message)
            item.valid = 0
        end
        items[#items + 1] = item
    end
    for _, d in ipairs(run.sanitizer) do
        items[#items + 1] = {
            filename = run.src, lnum = d.lnum, col = d.col, type = QF_TYPE[d.severity], text = d.message,
        }
    end
    for _, c in ipairs(run.cases) do
        if failed(c) then
            local text = ("%s %s"):format(M.verdict_name(c.verdict), case_where(run, c))
            if c.message then
                text = text .. (" (%s)"):format(c.message)
            end
            if c.custom then
                items[#items + 1] = { filename = c.file, lnum = c.line, type = "E", text = text }
            elseif run.src then
                items[#items + 1] = { filename = run.src, lnum = 1, type = "E", text = text }
            end
        end
    end
    return items
end

local function set_quickfix(run)
    if not config.get().quickfix then
        return
    end
    local items = qf_items(run)
    local cur = vim.fn.getqflist({ context = 0 })
    local ours = type(cur.context) == "table" and cur.context.lc_nvim == true
    if #items == 0 and not ours then
        return
    end
    vim.fn.setqflist({}, ours and "r" or " ", {
        title = ("lc %s: %s"):format(run.kind, run.title),
        items = items,
        context = { lc_nvim = true },
    })
end

-- ------------------------------------------------------------------
-- The result buffer

local function result_buf()
    local buf = ui.scratch("lc://result", "lcresult")
    if not vim.b[buf].lc_keys then
        local keys = config.get().keys
        local function map(key, fn, desc)
            if key then
                vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, desc = desc })
            end
        end
        map(keys.add_case, M.add_case, "lc: add the case under the cursor to cases.txt")
        map(keys.jump, M.jump, "lc: go to the case or the line under the cursor")
        map(keys.rerun, M.rerun, "lc: run again")
        map(keys.cancel, M.cancel, "lc: cancel the run")
        map(keys.close, function()
            if not pcall(vim.api.nvim_win_close, 0, false) then
                vim.cmd("enew")
            end
        end, "lc: close the window")
        vim.b[buf].lc_keys = true
    end
    return buf
end

--- Opens the result window, unless the result option is false and force
--- isn't set. Returns it, or nil and an error.
function M.open_result(force)
    local split = config.get().result
    if split == false then
        if not force then
            return nil
        end
        split = "botright 15split"
    end
    return ui.panel(result_buf(), split)
end

local function status_line(run)
    local done = run.done
    if run.error then
        -- The first line; render_lines shows the rest below.
        return "Error: " .. run.error:match("^[^\n]*"), "LcFailed"
    elseif run.killed and run.check_build then
        return "Cancelled while checking with the sanitizers", "LcLimit"
    elseif run.killed then
        return ("Cancelled after %d cases"):format(#run.cases), "LcLimit"
    elseif not run.finished and run.cancelling then
        return "Cancelling…", "LcRunning"
    elseif not run.finished then
        local r = run.running
        if r and r.sanitizer_check then
            return ("Checking with the sanitizers: case %d of %d…"):format(r.index + 1, r.total), "LcRunning"
        elseif r then
            return ("Running case %d of %d…"):format(r.index + 1, r.total), "LcRunning"
        elseif run.check_build then
            return "Checking with the sanitizers…", "LcRunning"
        elseif run.ref_build and not run.ref_done then
            return "Working out your cases' expected results with the reference solution…", "LcRunning"
        elseif run.build_done and run.build_done.ok then
            return "Running…", "LcRunning"
        end
        return "Building…", "LcRunning"
    elseif not done then
        return "lc stopped without a verdict", "LcFailed"
    elseif done.verdict == "compile_error" then
        return "Compile Error", "LcFailed"
    elseif done.cancelled and done.sanitizer_check == "cancelled" then
        return "Cancelled while checking with the sanitizers", "LcLimit"
    elseif done.cancelled then
        return ("Cancelled after %d of %d cases"):format(#run.cases, done.total or 0), "LcLimit"
    end
    local s = ("%s: %d/%d cases passed"):format(M.verdict_name(done.verdict), done.passed or 0, done.total or 0)
    if done.verdict == "accepted" then
        s = s .. (", slowest %d ms, peak memory %.1f MB")
            :format(done.max_time_ms or 0, (done.max_memory_kb or 0) / 1024)
    end
    if run.kind == "submit" then
        if done.first_solve then
            s = s .. " · solved for the first time"
        elseif done.status then
            s = s .. " · status: " .. done.status
        end
    end
    return s, verdict_hl(done.verdict)
end

--- The lines of the result buffer, their highlights, and what each line
--- is about (a case, or a place in a file).
function M.render_lines(run)
    local lines, hls, cases_at, locs = {}, {}, {}, {}
    -- A buffer line can't hold a newline: text with some becomes several.
    local function add(text, hl)
        for part in vim.gsplit(text, "\n", { plain = true }) do
            lines[#lines + 1] = part
            if hl then
                hls[#hls + 1] = { #lines - 1, 0, #part, hl }
            end
        end
    end
    local function hl(col, len, group)
        hls[#hls + 1] = { #lines - 1, col, col + len, group }
    end
    local src = run.src
    local shown = src and basename(src)
    local function shorten(s)
        if src and shown then
            local out = s:gsub(vim.pesc(src), (shown:gsub("%%", "%%%%")))
            return out
        end
        return s
    end
    -- A program's output, indented, with the middle left out when long.
    local function output(label, text, truncated, c)
        if not text or text == "" then
            return
        end
        add(("  %s:%s"):format(label, truncated and " (cut short)" or ""), "LcLabel")
        cases_at[#lines] = c
        local all = text_lines(text)
        local function put(i)
            local l, col = location(all[i], src, true)
            add("    " .. shorten(all[i]))
            cases_at[#lines] = c
            if l then
                locs[#lines] = { file = src, lnum = l, col = col }
            end
        end
        if #all <= SHOW_LINES then
            for i = 1, #all do
                put(i)
            end
        else
            local half = SHOW_LINES / 2
            for i = 1, half do
                put(i)
            end
            add(("    ... (%d lines left out)"):format(#all - 2 * half), "LcDim")
            cases_at[#lines] = c
            for i = #all - half + 1, #all do
                put(i)
            end
        end
    end

    -- Header and status.
    local head = ("lc %s · %s"):format(run.kind, run.title)
    local b = run.build
    if b then
        local lang = b.lang == "c" and "C" or "C++"
        head = head .. (" · %s (%s, %s%s)"):format(shown, lang, b.std, b.sanitize and ", sanitizers" or "")
    end
    add(head, "LcTitle")
    local status, status_hl = status_line(run)
    add(status, status_hl)
    local place = error_place(run)
    if place then
        locs[#lines] = place
    end
    -- lc submit couldn't check an accepted solution with the sanitizers.
    local done = run.done
    if done and done.sanitizer_check == "skipped" then
        add("Not checked with the sanitizers: " .. (done.sanitizer_check_note or "lc didn't say why"), "LcLimit")
    end
    -- The rest of a long error, unless it is the reference solution's
    -- compiler output, which comes below anyway.
    local more = run.error and run.error:match("\n(.*)$")
    if run.ref_done and not run.ref_done.ok then
        more = nil
    end
    if more and more ~= "" then
        add("")
        add(more)
    end

    -- The compiler's output.
    local function compiler_output(label, text)
        add("")
        add(label, "LcLabel")
        for _, l in ipairs(text_lines(text)) do
            local lnum, col = location(l, src)
            add("  " .. shorten(l))
            if lnum then
                locs[#lines] = { file = src, lnum = lnum, col = col }
            end
        end
    end
    local bd = run.build_done
    if bd and bd.output and bd.output ~= "" then
        compiler_output(bd.ok and "Compiler warnings:" or "Compiler output:", bd.output)
        if not bd.ok then
            local harness, mine = false, false
            for _, d in ipairs(bd.diagnostics or {}) do
                if d.severity == "error" then
                    if d.file == "lc_harness" then
                        harness = true
                    else
                        mine = true
                    end
                end
            end
            if harness then
                add("")
                add("Errors in lc_harness, the code that calls your solution, mean your function", "LcDim")
                add("doesn't match the problem's. Compare it with the stub that :Lc start wrote.", "LcDim")
            elseif mine and b and b.lang == "cpp" and b.std == "c++11" then
                add("")
                add("This was built as C++11. If your code needs a newer standard, use", "LcDim")
                add(":Lc std c++17 (or max) for this session, or :Lc " .. run.kind .. " --std c++17.", "LcDim")
            end
        end
    end
    -- The sanitizer check's build says again what the first one said,
    -- unless it failed (and the check was skipped).
    local cd = run.check_done
    if cd and not cd.ok and cd.output and cd.output ~= "" then
        compiler_output("Compiler output with the sanitizers:", cd.output)
    end
    local rd = run.ref_done
    if rd and not rd.ok then
        add("")
        add("The reference solution didn't build:", "LcFailed")
        for _, l in ipairs(text_lines(rd.output or "")) do
            add("  " .. l)
        end
    end

    -- The cases, one line each (lc test only, as on the command line).
    if run.kind == "test" and #run.cases > 0 then
        add("")
        local width = 0
        for _, c in ipairs(run.cases) do
            width = math.max(width, #M.case_label(run, c))
        end
        for _, c in ipairs(run.cases) do
            local v = M.verdict_name(c.verdict)
            local label = M.case_label(run, c)
            add(("  %s%s  %-22s %5d ms"):format(label, (" "):rep(width - #label), v, c.time_ms or 0))
            hl(2 + width + 2, #v, verdict_hl(c.verdict))
            cases_at[#lines] = c
        end
    end

    -- The failures, in detail.
    for _, c in ipairs(run.cases) do
        if failed(c) then
            add("")
            local v = M.verdict_name(c.verdict)
            local where = case_where(run, c)
            add(("%s %s%s"):format(v, where, c.message and (" (" .. c.message .. ")") or ""))
            hl(0, #v, verdict_hl(c.verdict))
            cases_at[#lines] = c
            local inputs = c.inputs or {}
            local named = #inputs > 0
            for _, input in ipairs(inputs) do
                named = named and input.name ~= nil
            end
            if named then
                local parts = {}
                for _, input in ipairs(inputs) do
                    parts[#parts + 1] = ("%s = %s"):format(input.name, cut(input.value))
                end
                add("  Input:    " .. table.concat(parts, ", "))
                hl(2, 6, "LcLabel")
                cases_at[#lines] = c
            elseif #inputs == 0 then
                add("  Input:    ()")
                hl(2, 6, "LcLabel")
                cases_at[#lines] = c
            else
                add("  Input:", "LcLabel")
                cases_at[#lines] = c
                for _, input in ipairs(inputs) do
                    add("    " .. cut(input.value))
                    cases_at[#lines] = c
                end
            end
            if c.output then
                add("  Output:   " .. cut(c.output))
                hl(2, 7, "LcLabel")
                cases_at[#lines] = c
            end
            add("  Expected: " .. cut(c.expected))
            hl(2, 9, "LcLabel")
            cases_at[#lines] = c
            output("Stdout", c.stdout, c.stdout_truncated, c)
            output("Stderr", c.stderr, c.stderr_truncated, c)
        end
    end

    if run.stderr_shown then
        add("")
        for _, l in ipairs(text_lines(run.stderr_shown)) do
            add(l, "LcFailed")
        end
    end

    -- What the keys do.
    local keys = config.get().keys
    local help = {}
    if not run.finished then
        if keys.cancel then
            help[#help + 1] = keys.cancel .. " cancel"
        end
    else
        if keys.add_case and #run.cases > 0 then
            help[#help + 1] = keys.add_case .. " add the case to cases.txt"
        end
        if keys.jump and (next(locs) or next(cases_at) or #run.diags > 0) then
            help[#help + 1] = keys.jump .. " go to it"
        end
        if keys.rerun then
            help[#help + 1] = keys.rerun .. " run again"
        end
    end
    if keys.close then
        help[#help + 1] = keys.close .. " close"
    end
    if #help > 0 then
        add("")
        add(table.concat(help, " · "), "LcDim")
    end
    return lines, hls, cases_at, locs
end

-- Where a window's cursor is, as a case: which block of lines about it (a
-- case has a line in the table and a block of details), and how far in.
local function anchor(win, cases_at)
    local cursor = vim.api.nvim_win_get_cursor(win)
    local c = cases_at and cases_at[cursor[1]]
    if not c then
        return nil
    end
    local start = cursor[1]
    while start > 1 and cases_at[start - 1] == c do
        start = start - 1
    end
    local block = 0
    for l = 1, start do
        if cases_at[l] == c and cases_at[l - 1] ~= c then
            block = block + 1
        end
    end
    return { case = c, block = block, offset = cursor[1] - start, col = cursor[2] }
end

local function restore(win, a, cases_at, count)
    local block = 0
    for l = 1, count do
        if cases_at[l] == a.case and cases_at[l - 1] ~= a.case then
            block = block + 1
            if block == a.block then
                local target = cases_at[l + a.offset] == a.case and l + a.offset or l
                pcall(vim.api.nvim_win_set_cursor, win, { target, a.col })
                return
            end
        end
    end
end

local function render(run)
    if run ~= M.last then
        return
    end
    local buf = result_buf()
    local lines, hls, cases_at, locs = M.render_lines(run)
    -- New lines go in above the details, so keep each cursor on its case.
    local anchors = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
            anchors[win] = anchor(win, run.cases_at)
        end
    end
    run.cases_at, run.locs = cases_at, locs
    run.rendered_at = vim.uv.now()
    ui.set_lines(buf, lines)
    for win, a in pairs(anchors) do
        restore(win, a, cases_at, #lines)
    end
    vim.api.nvim_buf_clear_namespace(buf, ui.ns, 0, -1)
    for _, h in ipairs(hls) do
        pcall(vim.api.nvim_buf_set_extmark, buf, ui.ns, h[1], h[2], { end_row = h[1], end_col = h[3], hl_group = h[4] })
    end
    vim.b[buf].lc_problem = run.info
    -- Every window's statusline: status() may be in all of them.
    vim.cmd("redrawstatus!")
end

-- Renders without letting an error stop the caller: a run's state must
-- still be finished off (M.current, LcRunDone) when drawing fails.
local function safe_render(run)
    local ok, err = pcall(render, run)
    if not ok then
        ui.error("lc: couldn't draw the result: " .. tostring(err))
    end
end

-- Events can come by the hundred: draw at most every RENDER_MS.
local RENDER_MS = 50
local function request_render(run)
    if run.render_queued then
        return
    end
    run.render_queued = true
    local wait = math.max(0, RENDER_MS - (vim.uv.now() - (run.rendered_at or 0)))
    vim.defer_fn(function()
        run.render_queued = false
        safe_render(run)
    end, wait)
end

--- Draws the last run's result again (after its buffer was wiped, say).
function M.redraw()
    if M.last then
        safe_render(M.last)
    end
end

-- ------------------------------------------------------------------
-- Running

local function fire(pattern, data)
    vim.api.nvim_exec_autocmds("User", { pattern = pattern, data = data, modeline = false })
end

local function finish_message(run)
    local done = run.done
    local name = run.title
    if run.error then
        return ("%s: %s"):format(name, run.error:match("^[^\n]*")), vim.log.levels.ERROR
    elseif run.killed or (done and done.cancelled) then
        return ("%s: cancelled"):format(name), vim.log.levels.WARN
    elseif not done then
        return ("%s: lc stopped without a verdict"):format(name), vim.log.levels.ERROR
    elseif done.cancelled then
        return ("%s: cancelled"):format(name), vim.log.levels.WARN
    elseif done.verdict == "compile_error" then
        return ("%s: Compile Error"):format(name), vim.log.levels.ERROR
    elseif done.verdict == "accepted" then
        local s = ("%s: Accepted, %d/%d cases"):format(name, done.passed or 0, done.total or 0)
        if run.kind == "submit" and done.first_solve then
            s = s .. ". Solved!"
        end
        return s, vim.log.levels.INFO
    end
    local s = ("%s: %s"):format(name, M.verdict_name(done.verdict))
    for _, c in ipairs(run.cases) do
        if failed(c) then
            s = s .. " " .. case_where(run, c)
            break
        end
    end
    return s .. (", %d/%d cases passed"):format(done.passed or 0, done.total or 0), vim.log.levels.WARN
end

local function on_doc(run, doc)
    if run.superseded then
        return
    end
    local err = cli.doc_error(doc)
    if err then
        run.error = err
        run.error_doc = doc
    elseif doc.event == "build_start" then
        if doc.reference then
            run.ref_build = doc
        elseif doc.sanitizer_check then
            -- lc submit checks an accepted solution again, built with the
            -- sanitizers: the run's build is still the first one.
            run.check_build = doc
        else
            run.build = doc
            run.src = doc.source
            -- What lc builds settles which problem this is, whatever was
            -- guessed from the arguments.
            local info = problem.from_path(doc.source)
            if info then
                run.info = info
                run.title = catalog.title(info) or run.title
                run.cases_file = run.case_flag or (info.dir .. "/cases.txt")
            end
        end
    elseif doc.event == "build_done" then
        if doc.reference then
            run.ref_done = doc
        elseif doc.sanitizer_check then
            -- Its diagnostics aren't added: they are the first build's again,
            -- or, when it fails, the check is skipped and the verdict stands.
            run.check_done = doc
        else
            run.build_done = doc
            for _, d in ipairs(doc.diagnostics or {}) do
                if d.in_solution then
                    add_diag(run, {
                        lnum = d.line or 1,
                        col = d.column or 0,
                        severity = severity(d.severity),
                        message = d.message,
                    })
                end
            end
            set_diagnostics(run)
        end
    elseif doc.event == "case_start" then
        run.running = doc
        run.total = doc.total
    elseif doc.event == "case_done" then
        run.running = nil
        run.total = doc.total
        doc.label = M.case_label(run, doc)
        if not doc.sanitizer_check then
            run.cases[#run.cases + 1] = doc
        elseif doc.verdict ~= "accepted" and doc.verdict ~= "time_limit_exceeded" then
            -- The case that failed in the sanitizer check takes the place of
            -- its first run, as in lc's verdict. The others passed already, and
            -- running out of time there doesn't count.
            local at = #run.cases + 1
            for i, c in ipairs(run.cases) do
                if c.index == doc.index then
                    at = i
                    break
                end
            end
            run.cases[at] = doc
        end
        if doc.verdict == "runtime_error" and doc.stderr then
            -- A place that several cases' reports point at is shown once, for
            -- the first (their messages differ only in the values).
            local label = M.case_label(run, doc)
            for _, d in ipairs(M.parse_sanitizer(doc.stderr, run.src)) do
                local key = ("%d:%d:%d"):format(d.lnum, d.col, d.severity)
                if not run.sanitizer_seen[key] then
                    run.sanitizer_seen[key] = true
                    d.message = ("%s (%s)"):format(d.message, label)
                    run.sanitizer[#run.sanitizer + 1] = d
                    add_diag(run, d)
                end
            end
            set_diagnostics(run)
        end
    elseif doc.event == "done" then
        run.done = doc
    end
    request_render(run)
end

local function on_exit(run, code, stderr, signal)
    run.finished = true
    run.code = code
    if M.current == run then
        M.current = nil
    end
    if run.superseded then
        return
    end
    if not run.done and not run.error then
        local msg = vim.trim(stderr or "")
        if code == 130 or run.cancelling then
            -- Stopped before lc could say so (a second :Lc cancel kills it).
            run.killed = true
        elseif signal and signal ~= 0 then
            run.error = ("lc was killed by signal %d"):format(signal)
            -- An assertion or a sanitizer's report says why.
            if msg ~= "" then
                run.stderr_shown = msg
            end
        elseif msg ~= "" then
            run.stderr_shown = msg
            run.error = (text_lines(msg)[1] or ""):gsub("^lc: ", "")
        else
            run.error = ("lc exited with status %d"):format(code or -1)
        end
    end
    if run.kind == "submit" then
        catalog.invalidate()
    end
    pcall(set_quickfix, run)
    safe_render(run)
    ui.warn_doc(run.done or run.error_doc)
    if config.get().notify then
        ui.notify(finish_message(run))
    end
    local done = run.done or {}
    fire("LcRunDone", {
        kind = run.kind,
        target = run.target,
        cancelled = run.killed or done.cancelled or false,
        verdict = run.error and "error" or done.verdict or (run.killed and "none") or "error",
        passed = done.passed,
        total = done.total,
        sanitizer_check = done.sanitizer_check,
        error = run.error,
        solution = run.src,
        problem = run.info,
    })
end

local function expand(arg)
    if arg:match("^[%%#<]") or arg:match("^~") then
        local e = vim.fn.expand(arg)
        if e ~= "" then
            return e
        end
    end
    return arg
end

--- Splits the arguments of :Lc test and :Lc submit into the problem or
--- solution (or nil) and lc's options.
function M.parse_args(fargs)
    local target, flags = nil, {}
    local i = 1
    while i <= #fargs do
        local a = fargs[i]
        if a == "--case" and fargs[i + 1] then
            -- lc gets no shell to expand ~ or %, and a rerun after :cd must
            -- find the same file.
            vim.list_extend(flags, { a, vim.fn.fnamemodify(expand(fargs[i + 1]), ":p") })
            i = i + 2
        elseif a:match("^%-%-case=") then
            flags[#flags + 1] = "--case=" .. vim.fn.fnamemodify(expand(a:sub(8)), ":p")
            i = i + 1
        elseif VALUE_FLAGS[a] and fargs[i + 1] then
            vim.list_extend(flags, { a, fargs[i + 1] })
            i = i + 2
        else
            if a:sub(1, 1) == "-" or target then
                flags[#flags + 1] = a
            else
                target = expand(a)
            end
            i = i + 1
        end
    end
    return target, flags
end

local function option_value(flags, name)
    for i, f in ipairs(flags) do
        if f == name then
            return flags[i + 1]
        end
        local v = f:match("^" .. vim.pesc(name) .. "=(.*)$")
        if v then
            return v
        end
    end
    return nil
end

-- The files of a problem's directory that lc test reads.
local LC_READS = { ["solution.c"] = true, ["solution.cpp"] = true, ["cases.txt"] = true }

-- Writes the changed buffers of a problem's directory: info.dir, or when
-- it isn't known yet (the problem was named by its ID), the files lc
-- reads in any directory of that problem.
local function autowrite(info)
    if not info or not config.get().autowrite then
        return
    end
    local real = info.dir and problem.realpath(info.dir)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified and vim.bo[b].buftype == "" then
            local name = vim.api.nvim_buf_get_name(b)
            local parent = name ~= "" and vim.fs.dirname(name)
            local mine
            if parent and real then
                mine = parent == info.dir or problem.realpath(parent) == real
            elseif parent and info.id and LC_READS[vim.fs.basename(name)] then
                -- Only a directory lc would use for that problem: named like
                -- 0001-two-sum, or one lc start gave this session (a link's target).
                local id, slug = problem.parse_dirname(vim.fs.basename(parent))
                mine = (id == info.id and (info.slug == nil or slug == info.slug))
                    or problem.started[problem.realpath(parent)] == info.id
            end
            if mine then
                local ok, err = pcall(vim.api.nvim_buf_call, b, function()
                    vim.cmd("silent update")
                end)
                if not ok then
                    ui.error(("lc: couldn't write %s: %s"):format(vim.fn.fnamemodify(name, ":~:."), err))
                end
            end
        end
    end
end

--- Starts `lc test` or `lc submit` (kind) with the arguments of :Lc test.
--- Without a problem or solution among them, it is the current buffer's.
function M.start(kind, fargs, opts)
    opts = opts or {}
    local target, flags = M.parse_args(fargs or {})
    local info
    if target then
        -- A path when there is such a file or it looks like one; else lc
        -- takes it as a problem's ID or slug ("9" is not ./9).
        if vim.uv.fs_stat(target) or target:find("/", 1, true) then
            info = problem.from_path(target)
        else
            local p = catalog.find(target)
            info = p and { id = p.id, slug = p.slug } or nil
        end
    else
        target, info = problem.target(opts.buf or 0)
        if not target then
            ui.error(("lc: this buffer isn't a solution or in a problem's directory: "
                .. "name a problem, as in :Lc %s 1"):format(kind))
            return nil
        end
    end
    autowrite(info)

    local old = M.current
    if old then
        old.superseded = true
        if old.proc then
            pcall(old.proc.kill, old.proc, 2)
        end
        M.current = nil
    end

    generation = generation + 1
    local case_flag = option_value(flags, "--case")
    case_flag = case_flag and vim.fn.fnamemodify(case_flag, ":p")
    local run = {
        id = generation,
        kind = kind,
        fargs = fargs or {},
        target = target,
        flags = flags,
        info = info,
        title = catalog.title(info) or target,
        case_flag = case_flag,
        cases_file = case_flag or (info and info.dir and info.dir .. "/cases.txt"),
        src = info and info.solution,
        cases = {},
        diags = {},
        diag_seen = {},
        sanitizer = {},
        sanitizer_seen = {},
    }
    M.last = run
    vim.diagnostic.reset(M.diag_ns)
    -- A bad `result` option (or no room for the window) mustn't stop the run.
    local ok, win, err = pcall(M.open_result)
    if not ok or (not win and err) then
        ui.error("lc: couldn't open the result window: " .. tostring(ok and err or win))
    end
    safe_render(run)

    local args = vim.list_extend({ kind, target }, flags)
    local proc
    proc, err = cli.stream(args, function(doc)
        on_doc(run, doc)
    end, function(code, stderr, signal)
        on_exit(run, code, stderr, signal)
    end)
    local started = { kind = kind, target = target, problem = info }
    if not proc then
        -- Every LcRunDone has its LcRunStart, even when lc couldn't start.
        run.error = err
        fire("LcRunStart", started)
        on_exit(run, -1, "")
        return run
    end
    run.proc = proc
    M.current = run
    fire("LcRunStart", started)
    return run
end

--- Stops the run: ^C for lc, then SIGKILL if asked again.
function M.cancel()
    local run = M.current
    if not run or not run.proc then
        ui.notify("lc: nothing is running")
        return
    end
    if run.cancelling then
        pcall(run.proc.kill, run.proc, 9)
    else
        run.cancelling = true
        pcall(run.proc.kill, run.proc, 2)
    end
    safe_render(run)
end

--- Runs the last run again.
function M.rerun()
    local run = M.last
    if not run then
        ui.notify("lc: nothing has run yet")
        return
    end
    local fargs = { run.src or run.target }
    vim.list_extend(fargs, run.flags)
    return M.start(run.kind, fargs)
end

--- The status of the run going on, for a statusline: "" when none.
function M.status()
    local run = M.current
    if not run then
        return ""
    elseif run.cancelling then
        return "lc: cancelling"
    elseif run.running then
        local r = run.running
        return ("lc %s: %s%d/%d"):format(run.kind, r.sanitizer_check and "sanitizers " or "", r.index + 1, r.total)
    elseif run.check_build then
        return ("lc %s: sanitizers"):format(run.kind)
    elseif not run.build_done then
        return ("lc %s: building"):format(run.kind)
    end
    return "lc " .. run.kind
end

-- ------------------------------------------------------------------
-- The keys of the result buffer

local function in_result()
    return vim.api.nvim_buf_get_name(0) == "lc://result" and vim.b.lc_scratch == true
end

local function cursor_case(run)
    local lnum = in_result() and vim.api.nvim_win_get_cursor(0)[1]
    local c = lnum and run.cases_at and run.cases_at[lnum]
    if c then
        return c
    end
    -- Anywhere else, the only failure if there is just one.
    local only
    for _, x in ipairs(run.cases) do
        if failed(x) then
            if only then
                return nil
            end
            only = x
        end
    end
    return only
end

local function open_at(file, lnum, col)
    local buf = problem.find_buf(file)
    local win = (buf and ui.win_showing(buf)) or ui.edit_win()
    local ok, err = ui.edit(win, file)
    if not ok then
        ui.error("lc: " .. err)
        return
    end
    local last = vim.api.nvim_buf_line_count(0)
    pcall(vim.api.nvim_win_set_cursor, 0, { math.min(math.max(lnum, 1), last), math.max((col or 1) - 1, 0) })
end

--- Goes to what the line under the cursor is about: a place in the
--- solution, or the case in its tests file.
function M.jump()
    local run = M.last
    if not run then
        return
    end
    local lnum = in_result() and vim.api.nvim_win_get_cursor(0)[1] or 0
    local loc = run.locs and run.locs[lnum]
    if loc then
        return open_at(loc.file, loc.lnum, loc.col)
    end
    local c = run.cases_at and run.cases_at[lnum]
    if c and c.file then
        return open_at(c.file, c.line or 1, 1)
    end
    local d = run.diags[1]
    if d and run.src then
        return open_at(run.src, d.lnum, d.col)
    end
end

local function short_error(err)
    err = tostring(err)
    return err:match("E%d+:.*") or err
end

-- Appends lines to a file, through its buffer when it is loaded. Returns
-- true (and "unsaved" when the buffer had changes of yours, so it wasn't
-- written), or nil and why not.
local function append(file, lines)
    local buf = problem.find_buf(file)
    if buf and vim.api.nvim_buf_is_loaded(buf) then
        if not vim.bo[buf].modifiable or vim.bo[buf].readonly then
            return nil, "its buffer is read-only"
        end
        local modified = vim.bo[buf].modified
        if not modified then
            -- A change made to the file outside: 'autoread' takes it in now,
            -- rather than :write asking about it.
            pcall(vim.cmd, "checktime " .. buf)
        end
        local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local empty = #cur == 1 and cur[1] == ""
        if not empty and cur[#cur] ~= "" then
            table.insert(lines, 1, "")
        end
        local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, empty and 0 or -1, -1, false, lines)
        if not ok then
            return nil, short_error(err)
        end
        if modified then
            return true, "unsaved"
        end
        ok, err = pcall(vim.api.nvim_buf_call, buf, function()
            vim.cmd("silent write")
        end)
        if not ok then
            return nil, "it is in the buffer, but writing it failed: " .. short_error(err)
        end
        return true
    end
    local text = ""
    local f = io.open(file, "rb")
    if f then
        text = f:read("*a") or ""
        f:close()
    end
    local prefix = ""
    if text ~= "" then
        if text:sub(-1) ~= "\n" then
            prefix = "\n"
        end
        if not text:match("\n\n$") and not text:match("^\n$") then
            prefix = prefix .. "\n"
        end
    end
    local out, err = io.open(file, "ab")
    if not out then
        return nil, err
    end
    out:write(prefix .. table.concat(lines, "\n") .. "\n")
    out:close()
    return true
end

--- Adds the case under the cursor in the result buffer (or the only one
--- that failed) to cases.txt, with its expected result.
function M.add_case()
    local run = M.last
    if not run then
        ui.notify("lc: nothing has run yet")
        return
    end
    local c = cursor_case(run)
    if not c then
        ui.notify("lc: put the cursor on a case")
        return
    end
    local file = run.cases_file
    if not file then
        ui.error("lc: don't know where this problem's cases.txt is")
        return
    end
    local label = M.case_label(run, c)
    if c.custom then
        ui.notify(("lc: %s is one of your cases already"):format(label))
        return
    end
    local verdict = M.verdict_name(c.verdict) .. (c.sanitizer_check and " with the sanitizers" or "")
    local lines = { ("# From lc %s: %s, %s"):format(run.kind, label:lower(), verdict) }
    for _, input in ipairs(c.inputs or {}) do
        lines[#lines + 1] = input.value
    end
    -- A case of a function without parameters is written "()".
    if #(c.inputs or {}) == 0 then
        lines[#lines + 1] = "()"
    end
    lines[#lines + 1] = "=> " .. (c.expected or "")
    local ok, how = append(file, lines)
    local shown = vim.fn.fnamemodify(file, ":~:.")
    if not ok then
        ui.error(("lc: couldn't add the case to %s: %s"):format(shown, how))
    elseif how == "unsaved" then
        ui.notify(("lc: added %s to %s's buffer, which has unsaved changes"):format(label:lower(), shown))
    else
        ui.notify(("lc: added %s to %s"):format(label:lower(), shown))
    end
end

-- Stop a run when Neovim exits, so lc cleans up after itself.
vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("lc.run", { clear = true }),
    callback = function()
        local run = M.current
        if run and run.proc then
            -- Quietly: no result or LcRunDone while Neovim exits. lc gets ^C,
            -- and a moment to clean up, before Neovim stops its jobs.
            run.superseded = true
            run.proc:kill(2)
            pcall(vim.fn.jobwait, { run.proc.id }, 2000)
        end
    end,
})

return M
