-- .github/run-plugin-tests.lua
-- Run from anywhere: nvim --headless --clean -l .github/run-plugin-tests.lua
--
-- Runs each plugins/*/test.lua in its own Neovim and reports each plugin
-- separately, so one that fails, crashes, or hangs can't hide the others.
-- PLUGIN_TEST_TIMEOUT sets the seconds each plugin gets (default 300).
local uv = vim.uv
local windows = vim.fn.has("win32") == 1
local ci = vim.env.GITHUB_ACTIONS == "true"
local timeout_ms = (tonumber(vim.env.PLUGIN_TEST_TIMEOUT) or 300) * 1000

local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(script)))

local function out(text)
    io.stdout:write(text .. "\n")
    io.stdout:flush()
end

local function find_tests()
    local names = {}
    for name, kind in vim.fs.dir(root .. "/plugins") do
        if kind == "directory" and uv.fs_stat(root .. "/plugins/" .. name .. "/test.lua") then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

-- The whole tree, since a test may have child Neovims of its own.
local function kill_tree(pid)
    if windows then
        vim.system({ "taskkill", "/T", "/F", "/PID", tostring(pid) }):wait()
    else
        uv.kill(-pid, "sigkill")
    end
end

local function read_lines(path)
    local f = io.open(path, "rb")
    if not f then return {} end
    local text = f:read("*a")
    f:close()
    return vim.split((text:gsub("\r\n", "\n")), "\n", { plain = true, trimempty = true })
end

-- Messages can land mid-line in `nvim -l` output, so a check's FAIL marker
-- isn't always at the start of its line.
local function failed_checks(lines)
    local checks = {}
    for _, line in ipairs(lines) do
        local at = line:find("FAIL ", 1, true)
        if at then checks[#checks + 1] = line:sub(at + 5) end
    end
    return checks
end

local function run(name)
    local log = vim.fn.tempname()
    local fd = assert(uv.fs_open(log, "w", 420))
    local exited, code, signal = false, nil, nil
    local started = uv.hrtime()
    -- Output goes to a file: a pipe could stay open after a kill, through a
    -- child that outlived its parent, and block the run.
    local handle, pid = uv.spawn(vim.v.progpath, {
        args = { "--headless", "--clean", "-l", root .. "/plugins/" .. name .. "/test.lua" },
        cwd = root,
        stdio = { nil, fd, fd },
        detached = not windows, -- its own process group, for kill_tree
    }, function(c, s)
        code, signal, exited = c, s, true
    end)
    uv.fs_close(fd)

    local result = { name = name, checks = {}, lines = {} }
    if not handle then
        result.status = "failed"
        result.detail = "could not start: " .. tostring(pid)
        vim.fn.delete(log)
        return result
    end

    local finished = vim.wait(timeout_ms, function() return exited end, 50)
    if not finished then
        kill_tree(pid)
        vim.wait(5000, function() return exited end, 50)
    end
    handle:close()
    result.seconds = (uv.hrtime() - started) / 1e9
    result.lines = read_lines(log)
    result.checks = failed_checks(result.lines)
    vim.fn.delete(log)

    if not finished then
        result.status = "timed out"
        result.detail = ("no result after %d s"):format(timeout_ms / 1000)
    elseif signal and signal ~= 0 then
        result.status = "crashed"
        result.detail = "signal " .. signal
    elseif code ~= 0 then
        result.status = "failed"
        result.detail = "exit " .. code
    else
        -- A leading skip: note can cover the whole plugin or only part of it.
        local note = (result.lines[1] or ""):match("^skip:%s*(.*)")
        local ran = false
        for _, line in ipairs(result.lines) do
            ran = ran or line:find("^ok ") ~= nil
        end
        result.status = (note and not ran) and "skipped" or "passed"
        result.detail = note and (ran and "skipped " .. note or note) or nil
    end
    return result
end

local function is_bad(result)
    return result.status ~= "passed" and result.status ~= "skipped"
end

local function explain(result)
    if #result.checks > 0 then
        return ("%d failing check%s"):format(#result.checks, #result.checks == 1 and "" or "s")
    end
    return result.detail or ""
end

local function escape_data(s)
    return (s:gsub("%%", "%%25"):gsub("\r", "%%0D"):gsub("\n", "%%0A"))
end

local function escape_property(s)
    return (escape_data(s):gsub(":", "%%3A"):gsub(",", "%%2C"))
end

local function first_error(lines)
    for _, line in ipairs(lines) do
        if line:match("^E%d+:") then return line end
    end
    return lines[#lines]
end

local function annotate(result, where)
    local message = result.checks[1]
        or (result.status == "failed" and first_error(result.lines))
        or result.detail or ""
    if #result.checks > 1 then
        message = ("%s (and %d more)"):format(message, #result.checks - 1)
    end
    out(("::error title=%s::%s"):format(
        escape_property(("%s %s on %s"):format(result.name, result.status, where)),
        escape_data(message)))
end

local ICONS = { passed = "✅", skipped = "⏭️", failed = "❌", crashed = "💥", ["timed out"] = "⏱️" }

local function write_summary(results, where)
    if not vim.env.GITHUB_STEP_SUMMARY then return end
    local md = { "### " .. where, "", "| Plugin | Result | Detail | Time |", "| --- | --- | --- | ---: |" }
    for _, r in ipairs(results) do
        md[#md + 1] = ("| %s | %s %s | %s | %.1f s |"):format(
            r.name, ICONS[r.status], r.status, explain(r):gsub("|", "\\|"), r.seconds or 0)
    end
    for _, r in ipairs(results) do
        if #r.checks > 0 then
            md[#md + 1] = ""
            md[#md + 1] = ("**%s**"):format(r.name)
            for _, check in ipairs(r.checks) do
                md[#md + 1] = "- `` " .. check:sub(1, 300):gsub("`", "'") .. " ``"
            end
        end
    end
    md[#md + 1] = ""
    local f = assert(io.open(vim.env.GITHUB_STEP_SUMMARY, "ab"))
    f:write(table.concat(md, "\n") .. "\n")
    f:close()
end

local v = vim.version()
local os_name = vim.env.RUNNER_OS or uv.os_uname().sysname
local where = ("%s, Neovim %d.%d.%d"):format(os_name, v.major, v.minor, v.patch)

local names = find_tests()
if #names == 0 then
    out("no plugins/*/test.lua found under " .. root)
    vim.cmd("cquit 1")
end

local results = {}
for _, name in ipairs(names) do
    local result = run(name)
    results[#results + 1] = result
    local heading = ("%s: %s%s"):format(name, result.status,
        explain(result) ~= "" and " (" .. explain(result) .. ")" or "")
    out(ci and "::group::" .. heading or "--- " .. heading)
    for _, line in ipairs(result.lines) do out(line) end
    if ci then out("::endgroup::") end
end

local bad = 0
out("\nResults on " .. where)
for _, r in ipairs(results) do
    out(("  %-12s %-10s %6.1f s  %s"):format(r.name, r.status, r.seconds or 0, explain(r)))
    for _, check in ipairs(r.checks) do out("      FAIL " .. check) end
    if is_bad(r) then
        bad = bad + 1
        if ci then annotate(r, where) end
    end
end
write_summary(results, where)
out(("\n%d of %d plugins failed"):format(bad, #results))

-- (:cquit rather than os.exit, which skips Neovim's own cleanup; and as a
-- string, since vim.cmd.cquit(n) is an error before Neovim 0.12.)
vim.cmd("cquit " .. (bad == 0 and 0 or 1))
