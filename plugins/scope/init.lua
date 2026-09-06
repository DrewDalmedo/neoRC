-- lua/neo/plugins/scope/init.lua
local M = {}

local state = {
    prompt_buf = nil, prompt_win = nil,
    results_buf = nil, results_win = nil,
    items = {}, filtered = {},
    selected = 1, mode = "files",
    job_id = nil,
    gen = 0,
}

-- Create grep augroup once at require-time
local GREP_AUGROUP = vim.api.nvim_create_augroup("ScopeGrep", { clear = true })

local MAX_RESULTS_SHOWN = 500
local MAX_GREP_RESULTS = 1000
local MIN_GREP_CHARS = 2

-- Fuzzy Matcher
local SEGMENT_SEPS = {
    ["/"] = true, ["\\"] = true, ["_"] = true,
    ["-"] = true, ["."] = true, [" "] = true,
}

local function fuzzy_score(str, pattern)
    if not pattern or pattern == "" then return 1 end
    local s, p = str:lower(), pattern:lower()
    local p_idx, score, consec = 1, 0, 0

    for i = 1, #s do
        if s:sub(i, i) == p:sub(p_idx, p_idx) then
            p_idx = p_idx + 1
            consec = consec + 1
            score = score + 10 + consec
            if i == 1 or SEGMENT_SEPS[s:sub(i - 1, i - 1)] then
                score = score + 8
            end
            if p_idx > #p then break end
        else
            consec = 0
        end
    end

    if p_idx <= #p then return 0 end
    -- Length penalty breaks ties toward shorter paths; clamp so a match stays > 0
    return math.max(score - #s * 0.05, 1)
end

-- Debounce Helper (self-contained timer per instance)
local function debounce(ms, fn)
    local timer = vim.uv.new_timer()
    return function(...)
        timer:stop()
        local args = {...}
        timer:start(ms, 0, vim.schedule_wrap(function() fn(unpack(args)) end))
    end
end

-- UI Management
local function close_picker()
    state.gen = state.gen + 1
    if vim.api.nvim_get_mode().mode:match("i") then vim.cmd("stopinsert") end
    if state.job_id then
        vim.fn.jobstop(state.job_id)
        state.job_id = nil
    end
    for _, win in ipairs({ state.prompt_win, state.results_win }) do
        if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end
    state.prompt_win, state.results_win = nil, nil
    state.items, state.filtered, state.selected = {}, {}, 1
end

local function create_ui(title)
    close_picker()
    local width = math.min(80, vim.o.columns - 4)
    local total_h = math.min(20, vim.o.lines - 4)
    local row = math.floor((vim.o.lines - total_h) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local base = { relative = "editor", style = "minimal", border = "rounded" }

    state.prompt_buf = vim.api.nvim_create_buf(false, true)
    state.prompt_win = vim.api.nvim_open_win(state.prompt_buf, true, vim.tbl_extend("force", base, {
        row = row, col = col, width = width, height = 1,
        title = title, title_pos = "left", zindex = 50,
    }))

    state.results_buf = vim.api.nvim_create_buf(false, true)
    state.results_win = vim.api.nvim_open_win(state.results_buf, false, vim.tbl_extend("force", base, {
        row = row + 3, col = col, width = width, height = math.max(5, total_h - 5),
        noautocmd = true, zindex = 51,
    }))

    vim.api.nvim_set_option_value("filetype", "scope_prompt", { buf = state.prompt_buf })
    vim.api.nvim_set_option_value("filetype", "scope_results", { buf = state.results_buf })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = state.prompt_buf })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = state.results_buf })
    vim.api.nvim_set_option_value("cursorline", true, { win = state.results_win })
    vim.api.nvim_set_option_value("wrap", false, { win = state.results_win })
    vim.api.nvim_set_option_value("scrolloff", 999, { win = state.results_win })
    vim.cmd("startinsert")
end

-- Rendering
local function render_results()
    if not (state.results_buf and vim.api.nvim_buf_is_valid(state.results_buf)) then return end
    local lines = {}
    for i, item in ipairs(state.filtered) do
        lines[i] = (i == state.selected and "▸ " or "  ") .. item.display
    end
    vim.api.nvim_buf_set_lines(state.results_buf, 0, -1, false, lines)
    if state.filtered[state.selected]
        and state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
        vim.api.nvim_win_set_cursor(state.results_win, { state.selected, 0 })
    end
end

local debounced_filter = debounce(30, function()
    if not (state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf)) then return end
    local prompt = vim.api.nvim_buf_get_lines(state.prompt_buf, 0, 1, false)[1] or ""
    prompt = prompt:match("^%s*(.-)%s*$")

    state.selected = 1

    if state.mode == "grep" or prompt == "" then
        -- Grep results are pre-filtered by the search tool; empty prompts keep scan order
        state.filtered = {}
        for i = 1, math.min(#state.items, MAX_RESULTS_SHOWN) do
            state.filtered[i] = state.items[i]
        end
    else
        local scored = {}
        for idx, item in ipairs(state.items) do
            local s = fuzzy_score(item.display, prompt)
            if s > 0 then table.insert(scored, { score = s, idx = idx, item = item }) end
        end
        table.sort(scored, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            return a.idx < b.idx
        end)
        state.filtered = {}
        for i = 1, math.min(#scored, MAX_RESULTS_SHOWN) do
            state.filtered[i] = scored[i].item
        end
    end

    if #state.filtered == 0 then state.selected = 0 end
    render_results()
end)

-- Input & Keymaps
local function setup_keymaps()
    local opts = { buffer = state.prompt_buf, silent = true, nowait = true }

    vim.keymap.set({"i", "n"}, "<CR>", function()
        local sel = state.filtered[state.selected]
        close_picker()
        if sel then sel.action(sel) end
    end, opts)

    vim.keymap.set("n", "<Esc>", close_picker, opts)

    -- navigation
    vim.keymap.set({"i", "n"}, "<Up>", function()
        state.selected = math.max(1, state.selected - 1)
        render_results()
    end, opts)

    vim.keymap.set("n", "k", function()
        state.selected = math.max(1, state.selected - 1)
        render_results()
    end, opts)

    vim.keymap.set({"i", "n"}, "<Down>", function()
        state.selected = math.min(#state.filtered, state.selected + 1)
        render_results()
    end, opts)

    vim.keymap.set("n", "j", function()
        state.selected = math.min(#state.filtered, state.selected + 1)
        render_results()
    end, opts)

    vim.keymap.set("n", "go", function()
        state.selected = 1
        render_results()
    end, opts)

    vim.keymap.set("n", "gg", function()
        state.selected = 1
        render_results()
    end, opts)

    vim.keymap.set("n", "G", function()
        state.selected = #state.filtered
        render_results()
    end, opts)

    -- autocmds for handling picker keymap events
    vim.api.nvim_create_autocmd("TextChangedI", {
        buffer = state.prompt_buf,
        callback = debounced_filter,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(state.prompt_win),
        once = true,
        callback = close_picker,
    })
end

-- File Finder
local function scan_files_async(gen, on_chunk, on_done)
    local cwd = vim.fn.getcwd()
    local queue = { { path = cwd, rel = "", depth = 0 } }
    local idx = 1
    local count = 0
    local max_files = 50000
    local max_depth = 12
    local entries_per_tick = 1000

    local ignore = {
        [".git"] = true, [".svn"] = true, [".hg"] = true,
        ["node_modules"] = true, ["__pycache__"] = true,
        [".cache"] = true, ["vendor"] = true, ["target"] = true,
        [".venv"] = true, ["env"] = true, [".tox"] = true,
        ["dist"] = true, ["build"] = true, [".next"] = true,
    }

    local step
    step = function()
        if gen ~= state.gen then return end
        local chunk = {}
        local processed = 0

        while idx <= #queue do
            local dir = queue[idx]
            idx = idx + 1

            if dir.depth < max_depth then
                -- pcall covers both unreadable dirs and errors raised mid-iteration
                pcall(function()
                    for name, type in vim.fs.dir(dir.path) do
                        processed = processed + 1
                        local rel = dir.rel == "" and name or (dir.rel .. "/" .. name)
                        if type == "directory" then
                            if not ignore[name] then
                                table.insert(queue, {
                                    path = vim.fs.joinpath(dir.path, name),
                                    rel = rel, depth = dir.depth + 1,
                                })
                            end
                        elseif type == "file" or type == "link" then
                            count = count + 1
                            table.insert(chunk, rel)
                        end
                    end
                end)
                if count >= max_files then
                    on_chunk(chunk)
                    on_done()
                    return
                end
            end

            -- Yield only between directories: an interrupted iterator would drop entries
            if processed >= entries_per_tick then
                if #chunk > 0 then on_chunk(chunk) end
                vim.schedule(step)
                return
            end
        end

        if #chunk > 0 then on_chunk(chunk) end
        on_done()
    end
    step()
end

-- Live Grep
local function build_grep_cmd(query)
    if vim.fn.executable("rg") == 1 then
        -- The explicit "." matters: without a path, rg searches stdin when it isn't a tty
        return { "rg", "--vimgrep", "--no-heading", "--color=never", "--", query, "." }, true
    elseif vim.fn.has("win32") == 1 and vim.fn.executable("findstr") == 1 then
        return { "findstr", "/s", "/n", "/c:" .. query, "*" }, false
    else
        return { "grep", "-rn", "--exclude-dir=.git", "--color=never", "--", query, "." }, false
    end
end

-- rg emits file:line:col:text; grep/findstr emit file:line:text (column defaults to 1)
local function parse_grep_line(line, has_col)
    -- Split a leading Windows drive off first so its colon can't confuse the field split
    local drive, rest = line:match("^(%a:)([\\/].*)$")
    if not drive then drive, rest = "", line end
    local file, lnum, col, text
    if has_col then
        file, lnum, col, text = rest:match("^(.-):(%d+):(%d+):(.*)$")
    else
        file, lnum, text = rest:match("^(.-):(%d+):(.*)$")
    end
    if not file or file == "" then return nil end
    file = file:gsub("^%.[/\\]", "")
    if file == "" then return nil end
    return drive .. file, tonumber(lnum), tonumber(col) or 1, text
end

local function run_grep_async(gen, query, on_match)
    local cmd, has_col = build_grep_cmd(query)
    local line_buf = ""
    local job_id

    local function emit(line)
        line = line:gsub("\r$", "")
        if line == "" then return end
        local file, lnum, col, text = parse_grep_line(line, has_col)
        if file then on_match(file, lnum, col, text) end
    end

    job_id = vim.fn.jobstart(cmd, {
        cwd = vim.fn.getcwd(),
        stdin = "null",
        stdout_buffered = false,
        -- on_stdout data is a list of line pieces; first/last may be partial (:h channel-lines)
        on_stdout = function(_, data)
            if gen ~= state.gen or state.job_id ~= job_id then return end
            if not data or #data == 0 then return end
            data[1] = line_buf .. data[1]
            line_buf = table.remove(data) or ""
            for _, line in ipairs(data) do emit(line) end
        end,
        on_stderr = function(_, data)
            if gen ~= state.gen or state.job_id ~= job_id then return end
            if data and data[1] and data[1] ~= "" then
                vim.notify("Scope grep stderr: " .. data[1], vim.log.levels.WARN)
            end
        end,
        on_exit = function(_, _)
            if gen ~= state.gen or state.job_id ~= job_id then return end
            if line_buf ~= "" then emit(line_buf) end
            state.job_id = nil
        end,
    })

    if job_id <= 0 then
        vim.notify("Scope: Failed to start grep job. Check PATH.", vim.log.levels.ERROR)
        return
    end
    state.job_id = job_id
end

-- Actions
local function open_file(path, line, col)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    if line and col then
        pcall(vim.api.nvim_win_set_cursor, 0, { line, math.max(col - 1, 0) })
    end
end

-- Public API
function M.find_files()
    state.mode = "files"
    state.items = {}
    create_ui(" Find Files ")
    setup_keymaps()
    vim.cmd("startinsert!")

    local cwd = vim.fn.getcwd()
    local gen = state.gen
    scan_files_async(gen, function(chunk)
        for _, rel in ipairs(chunk) do
            local full = vim.fs.normalize(vim.fs.joinpath(cwd, rel))
            table.insert(state.items, {
                display = rel,
                action = function() open_file(full) end,
            })
        end
        debounced_filter()
    end, debounced_filter)
end

local do_grep_restart = nil
local debounced_grep = debounce(120, function()
    if do_grep_restart then do_grep_restart() end
end)

function M.live_grep()
    state.mode = "grep"
    state.items = {}
    create_ui(" Grep ")
    setup_keymaps()
    vim.cmd("startinsert!")

    local cwd = vim.fn.getcwd()
    local gen = state.gen
    local prompt_buf = state.prompt_buf
    local seen = {}

    local add_match = function(file, lnum, col, text)
        if #state.items >= MAX_GREP_RESULTS then
            if state.job_id then
                vim.fn.jobstop(state.job_id)
                state.job_id = nil
            end
            return
        end
        local key = file .. ":" .. lnum .. ":" .. col
        if seen[key] then return end
        seen[key] = true
        local full_path
        if file:match("^[\\/]") or file:match("^%a:[\\/]") then
            full_path = vim.fs.normalize(file)
        else
            full_path = vim.fs.normalize(vim.fs.joinpath(cwd, file))
        end
        table.insert(state.items, {
            display = string.format("%s:%d:%d  %s", file, lnum, col, text),
            action = function() open_file(full_path, lnum, col) end,
        })
        debounced_filter()
    end

    do_grep_restart = function()
        if gen ~= state.gen or state.mode ~= "grep" then return end
        if not vim.api.nvim_buf_is_valid(prompt_buf) then return end
        local query = vim.api.nvim_buf_get_lines(prompt_buf, 0, 1, false)[1] or ""
        query = query:match("^%s*(.-)%s*$")
        if state.job_id then
            vim.fn.jobstop(state.job_id)
            state.job_id = nil
        end
        state.items, seen = {}, {}
        if #query < MIN_GREP_CHARS then
            debounced_filter()
            return
        end
        run_grep_async(gen, query, add_match)
    end

    vim.api.nvim_clear_autocmds({ group = GREP_AUGROUP, buffer = prompt_buf })
    vim.api.nvim_create_autocmd("TextChangedI", {
        group = GREP_AUGROUP,
        buffer = prompt_buf,
        callback = debounced_grep,
    })
end

function M.setup()
    vim.api.nvim_create_user_command("ScopeFiles", M.find_files, { desc = "Scope: Find Files" })
    vim.api.nvim_create_user_command("ScopeGrep", M.live_grep, { desc = "Scope: Live Grep" })
end

-- exposed for tests
M._fuzzy_score = fuzzy_score
M._parse_grep_line = parse_grep_line
M._state = state

return M
