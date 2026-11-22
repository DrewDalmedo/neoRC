-- lua/neo/plugins/keel/parse.lua
-- Pure parsers for git's output. Nothing here runs git or touches Neovim's
-- state, so all of it can be tested from fixed strings.
local M = {}

--- A line of git's output as a buffer can hold it.
function M.clean(text)
    return (text:gsub("\r$", ""):gsub("[%z\n]", "?"))
end

local function split_nul(raw)
    local out = {}
    for record in raw:gmatch("([^%z]*)%z") do
        out[#out + 1] = record
    end
    return out
end

local function add_entry(out, xy, path, orig, sub)
    local x, y = xy:sub(1, 1), xy:sub(2, 2)
    local submodule = sub:sub(1, 1) == "S"
    if x ~= "." then
        out.staged[#out.staged + 1] = {
            path = path,
            orig = (x == "R" or x == "C") and orig or nil,
            status = x,
            submodule = submodule,
        }
    end
    if y ~= "." then
        out.unstaged[#out.unstaged + 1] = {
            path = path,
            orig = (y == "R" or y == "C") and orig or nil,
            status = y,
            submodule = submodule,
        }
    end
end

local function read_header(out, record)
    local key, value = record:match("^# branch%.(%S+) (.*)$")
    if key == "oid" then
        out.oid = value
        out.unborn = value == "(initial)"
    elseif key == "head" then
        out.detached = value == "(detached)"
        out.head = value
    elseif key == "upstream" then
        out.upstream = value
    elseif key == "ab" then
        local ahead, behind = value:match("^%+(%d+) %-(%d+)$")
        out.ahead, out.behind = tonumber(ahead) or 0, tonumber(behind) or 0
    end
end

--- `git status --porcelain=v2 --branch -z`
function M.status(raw)
    local out = {
        ahead = 0, behind = 0,
        staged = {}, unstaged = {}, untracked = {}, conflicted = {},
    }
    local records = split_nul(raw)
    local i = 1
    while i <= #records do
        local record = records[i]
        local kind = record:sub(1, 2)
        if kind == "# " then
            read_header(out, record)
        elseif kind == "1 " then
            local xy, sub, path = record:match("^1 (..) (%S+) %S+ %S+ %S+ %S+ %S+ (.*)$")
            if xy then add_entry(out, xy, path, nil, sub) end
        elseif kind == "2 " then
            local xy, sub, path = record:match("^2 (..) (%S+) %S+ %S+ %S+ %S+ %S+ %S+ (.*)$")
            i = i + 1 -- the original path is its own record
            if xy then add_entry(out, xy, path, records[i], sub) end
        elseif kind == "u " then
            local xy, path = record:match("^u (..) %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.*)$")
            if xy then
                out.conflicted[#out.conflicted + 1] = { path = path, status = xy }
            end
        elseif kind == "? " then
            out.untracked[#out.untracked + 1] = { path = record:sub(3), status = "?" }
        end
        i = i + 1
    end
    return out
end

--- A unified diff, as a list of files:
--- { header = {lines}, binary, line_count, hunks = { {
---     header, old_start, old_count, new_start, new_count, lines = {...} } } }
--- Lines keep their exact bytes, including a trailing \r.
function M.diff(raw)
    local files, file, hunk = {}, nil, nil
    if raw == "" then return files end
    if raw:sub(-1) ~= "\n" then raw = raw .. "\n" end

    for line in raw:gmatch("([^\n]*)\n") do
        if line:sub(1, 11) == "diff --git " then
            file = { header = { line }, hunks = {}, binary = false, line_count = 0 }
            files[#files + 1] = file
            hunk = nil
        elseif file then
            local old_start, old_count, new_start, new_count =
                line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
            if old_start then
                hunk = {
                    header = line,
                    old_start = tonumber(old_start),
                    old_count = tonumber(old_count) or 1,
                    new_start = tonumber(new_start),
                    new_count = tonumber(new_count) or 1,
                    lines = {},
                }
                file.hunks[#file.hunks + 1] = hunk
            elseif hunk then
                hunk.lines[#hunk.lines + 1] = line
                file.line_count = file.line_count + 1
            else
                file.header[#file.header + 1] = line
                if line:match("^Binary files ") or line == "GIT binary patch" then
                    file.binary = true
                end
            end
        end
    end
    return files
end

--- Records ended by 0x1E, with fields split on NUL, named by `fields`.
function M.records(raw, fields)
    local out = {}
    for record in raw:gmatch("([^\30]*)\30\n?") do
        local values, row = {}, {}
        for value in (record .. "\0"):gmatch("([^%z]*)%z") do
            values[#values + 1] = value
        end
        for i, name in ipairs(fields) do
            row[name] = values[i] or ""
        end
        out[#out + 1] = row
    end
    return out
end

M.COMMIT_FORMAT = "--format=%H%x00%h%x00%an%x00%ar%x00%D%x00%s%x1e"
M.COMMIT_FIELDS = { "hash", "short", "author", "date", "refs", "subject" }

function M.commits(raw)
    return M.records(raw, M.COMMIT_FIELDS)
end

M.STASH_FORMAT = "--format=%gd%x00%s%x1e"

function M.stashes(raw)
    return M.records(raw, { "ref", "subject" })
end

return M
