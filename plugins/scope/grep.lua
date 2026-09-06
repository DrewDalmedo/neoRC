-- lua/neo/plugins/scope/grep.lua
-- Live grep: an external search process (rg/grep/findstr) streamed into the
-- generic picker. The prompt drives the search tool, so results arrive
-- pre-filtered and the picker just displays them in arrival order.
local picker = require("neo.plugins.picker")
local util = require("neo.plugins.picker.util")

local M = {}

local MAX_RESULTS = 1000
local MIN_QUERY_CHARS = 2

-- Pick the best available search tool. Returns the argv and whether the
-- tool's output includes a column field.
function M.build_cmd(query)
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
function M.parse_line(line, has_col)
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

-- Start a search job in opts.cwd; on_match(file, lnum, col, text) fires per
-- parsed hit. Returns a handle with .stop(); output after stop() is dropped.
function M.run(query, opts, on_match)
    local cmd, has_col = M.build_cmd(query)
    local line_buf = ""
    local handle = { stopped = false }

    function handle.stop()
        if handle.stopped then return end
        handle.stopped = true
        if handle.job_id then vim.fn.jobstop(handle.job_id) end
    end

    local function emit(line)
        line = line:gsub("\r$", "")
        if line == "" then return end
        local file, lnum, col, text = M.parse_line(line, has_col)
        if file then on_match(file, lnum, col, text) end
    end

    local job_id = vim.fn.jobstart(cmd, {
        cwd = opts.cwd,
        stdin = "null",
        stdout_buffered = false,
        -- on_stdout data is a list of line pieces; first/last may be partial (:h channel-lines)
        on_stdout = function(_, data)
            if handle.stopped then return end
            if not data or #data == 0 then return end
            data[1] = line_buf .. data[1]
            line_buf = table.remove(data) or ""
            for _, line in ipairs(data) do emit(line) end
        end,
        on_stderr = function(_, data)
            if handle.stopped then return end
            if data and data[1] and data[1] ~= "" then
                vim.notify("Scope grep stderr: " .. data[1], vim.log.levels.WARN)
            end
        end,
        on_exit = function(_, _)
            if handle.stopped then return end
            if line_buf ~= "" then emit(line_buf) end
            handle.stopped = true
        end,
    })

    if job_id <= 0 then
        vim.notify("Scope: Failed to start grep job. Check PATH.", vim.log.levels.ERROR)
        handle.stopped = true
        return handle
    end
    handle.job_id = job_id
    return handle
end

function M.open()
    local cwd = vim.fn.getcwd()
    local seen = {}
    local job = nil
    local p

    local function stop_job()
        if job then
            job.stop()
            job = nil
        end
    end

    local function add_match(file, lnum, col, text)
        if not p:valid() then return end
        if p:count() >= MAX_RESULTS then
            stop_job()
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
        p:add_items({ {
            display = string.format("%s:%d:%d  %s", file, lnum, col, text),
            path = full_path, lnum = lnum, col = col,
        } })
    end

    p = picker.open({
        title = " Grep ",
        filter = "none",
        on_select = function(item)
            util.open_file(item.path, item.lnum, item.col)
        end,
        on_close = stop_job,
        on_query = function(query)
            stop_job()
            seen = {}
            p:set_items({})
            if #query < MIN_QUERY_CHARS then return end
            job = M.run(query, { cwd = cwd }, add_match)
        end,
    })

    return p
end

return M
