-- lua/neo/plugins/harbor/diff.lua
-- Turns edited listings into changes, without touching the disk.
--
-- A listed line is "/<id> <text>", the id concealed; a directory's text ends
-- in "/". An entry is followed by its id, wherever the line ends up:
--
--   at its own path                 unchanged
--   anywhere else, and not at home  moved (or renamed)
--   at home and somewhere else      copied there
--   nowhere                         deleted
--
-- A line without an id is a new file ("name/" a directory, "a/b.txt" with
-- its parents). Blank lines are ignored.
--
-- Names a line can't carry (newlines, control characters, invalid UTF-8,
-- edge whitespace, backslashes) are listed escaped. Those entries can move
-- and be deleted, since the id says what they are, but not be renamed.
local fs = require("neo.plugins.harbor.fs")

local M = {}

local RESERVED = { CON = true, PRN = true, AUX = true, NUL = true }
for i = 1, 9 do
    RESERVED["COM" .. i] = true
    RESERVED["LPT" .. i] = true
end

--- The id and text of a line; no id for a line that isn't listed.
function M.parse_line(line)
    local id, text = line:match("^/(%d+) (.*)$")
    if id then
        return tonumber(id), text
    end
    return nil, line
end

function M.valid_utf8(text)
    local i, n = 1, #text
    while i <= n do
        local c = text:byte(i)
        local extra
        if c < 0x80 then
            extra = 0
        elseif c >= 0xC2 and c <= 0xDF then
            extra = 1
        elseif c >= 0xE0 and c <= 0xEF then
            extra = 2
        elseif c >= 0xF0 and c <= 0xF4 then
            extra = 3
        else
            return false
        end
        if i + extra > n then return false end
        for j = i + 1, i + extra do
            local b = text:byte(j)
            if b < 0x80 or b > 0xBF then return false end
        end
        local second = text:byte(i + 1)
        if (c == 0xE0 and second < 0xA0) or (c == 0xED and second > 0x9F)
            or (c == 0xF0 and second < 0x90) or (c == 0xF4 and second > 0x8F) then
            return false
        end
        i = i + extra + 1
    end
    return true
end

--- Whether a line can show name as it is.
function M.is_plain(name)
    return M.valid_utf8(name)
        and not name:find("[%c\\]")
        and not name:match("^%s")
        and not name:match("%s$")
end

--- name as listed: itself, or escaped when it isn't plain.
function M.display(name)
    if M.is_plain(name) then return name end
    local utf8 = M.valid_utf8(name)
    local shown = name:gsub(".", function(c)
        local b = c:byte()
        if c == "\\" then return "\\\\" end
        if c == "\n" then return "\\n" end
        if c == "\t" then return "\\t" end
        if b < 0x20 or b == 0x7F or (b >= 0x80 and not utf8) then
            return ("\\x%02X"):format(b)
        end
    end)
    shown = shown:gsub("^ ", "\\x20"):gsub(" $", "\\x20")
    return shown
end

local function bad_part(part, windows)
    if part == "" then return "a path can't have an empty part" end
    if part == "." or part == ".." then return "a name can't be " .. part end
    if part:find("%c") then return "a name can't contain control characters" end
    if windows then
        if part:find('[<>:"|?*]') then
            return ('%s: Windows names can\'t contain < > : " | ? *'):format(part)
        end
        if part:match("[%. ]$") then
            return part .. ": Windows names can't end in a dot or space"
        end
        local stem = part:match("^[^.]*"):upper()
        if RESERVED[stem] then
            return part .. ": reserved on Windows"
        end
    end
end

--- text as a path relative to its listing. Returns the relative path and
--- whether it names a directory, or nil, nil and what's wrong with it.
function M.parse_name(text, windows)
    if windows == nil then windows = fs.windows end
    if windows then
        text = text:gsub("\\", "/")
    elseif text:find("\\", 1, true) then
        return nil, nil, "a name can't be typed with a backslash"
    end
    if text:sub(1, 1) == "/" or (windows and text:match("^%a:")) then
        return nil, nil, "a name has to be relative to this directory: " .. text
    end
    local is_dir = text:sub(-1) == "/"
    local body = is_dir and text:sub(1, -2) or text
    if body == "" then
        return nil, nil, "a name can't be empty"
    end
    for part in (body .. "/"):gmatch("(.-)/") do
        local bad = bad_part(part, windows)
        if bad then return nil, nil, bad end
    end
    return body, is_dir
end

--- opts: buffers = { { dir, lines, shown = { id, ... } } } (the modified
--- listings), entry = fn(id) -> entry, windows (default: this platform).
--- Returns a list of changes, or nil and a list of errors. A change is
--- { kind = "create" | "move" | "copy" | "delete", from, to, is_dir, entry }.
function M.compute(opts)
    local windows = opts.windows
    if windows == nil then windows = fs.windows end

    local errors, creates = {}, {}
    local spots, taken, order, noted, at_home = {}, {}, {}, {}, {}

    local function note(id)
        if not noted[id] then
            noted[id] = true
            order[#order + 1] = id
        end
    end
    local function complain(b, lnum, message)
        errors[#errors + 1] = ("%s, line %d: %s"):format(fs.short(b.dir), lnum, message)
    end
    local function claim(b, lnum, path)
        local key = fs.key(path, windows)
        if taken[key] then
            complain(b, lnum, fs.short(path) .. " is listed twice")
            return false
        end
        taken[key] = true
        return true
    end
    -- J on two listed lines leaves the second's id inside the first's name.
    -- Its text has to follow, so "notes/5 plan.txt" is still a fine name.
    local function joined(text)
        for after, id in text:gmatch("/()(%d+) ") do
            local other = opts.entry(tonumber(id))
            if other then
                local from = after + #id + 1
                if text:sub(from, from + #other.text - 1) == other.text then
                    return true
                end
            end
        end
        return false
    end

    for _, b in ipairs(opts.buffers) do
        for _, id in ipairs(b.shown or {}) do
            at_home[id] = true
            note(id)
        end
    end

    for _, b in ipairs(opts.buffers) do
        for lnum, line in ipairs(b.lines) do
            if vim.trim(line) ~= "" then
                local id, text = M.parse_line(line)
                local entry = id and opts.entry(id)
                if id and not entry then
                    complain(b, lnum, "unknown entry (gR refreshes the listing)")
                elseif joined(text) then
                    complain(b, lnum, "this looks like two lines joined")
                elseif entry then
                    local name, is_dir, bad
                    if text == entry.text then
                        name, is_dir = entry.name, entry.type == "directory"
                    elseif entry.escaped then
                        bad = entry.text .. " has an unusual name, so it can't be renamed here"
                    else
                        name, is_dir, bad = M.parse_name(text, windows)
                        if name and is_dir ~= (entry.type == "directory") then
                            bad = ("%s can't change between a file and a directory"):format(entry.text)
                        end
                    end
                    if bad then
                        complain(b, lnum, bad)
                    else
                        local path = fs.join(b.dir, name)
                        if claim(b, lnum, path) then
                            spots[id] = spots[id] or {}
                            table.insert(spots[id], path)
                            note(id)
                        end
                    end
                else
                    local name, is_dir, bad = M.parse_name(vim.trim(text), windows)
                    if bad then
                        complain(b, lnum, bad)
                    else
                        local path = fs.join(b.dir, name)
                        if claim(b, lnum, path) then
                            creates[#creates + 1] = { kind = "create", to = path, is_dir = is_dir }
                        end
                    end
                end
            end
        end
    end
    if #errors > 0 then
        return nil, errors
    end

    local moves, copies, deletes = {}, {}, {}
    for _, id in ipairs(order) do
        local entry = opts.entry(id)
        if entry then
            local list = spots[id] or {}
            local is_dir = entry.type == "directory"
            -- An entry its own listing doesn't show (a dotfile while they're
            -- hidden, or a listing that isn't being saved) stays where it is.
            local kept = not at_home[id]
            for _, path in ipairs(list) do
                if path == entry.path then kept = true end
            end
            local moved_to
            if not kept then
                if #list == 0 then
                    deletes[#deletes + 1] = { kind = "delete", from = entry.path, is_dir = is_dir, entry = entry }
                else
                    -- A rename in place beats a paste elsewhere.
                    moved_to = list[1]
                    for _, path in ipairs(list) do
                        if vim.fs.dirname(path) == entry.dir then
                            moved_to = path
                            break
                        end
                    end
                    moves[#moves + 1] = { kind = "move", from = entry.path, to = moved_to, is_dir = is_dir, entry = entry }
                end
            end
            for _, path in ipairs(list) do
                if path ~= entry.path and path ~= moved_to then
                    copies[#copies + 1] = { kind = "copy", from = entry.path, to = path, is_dir = is_dir, entry = entry }
                end
            end
        end
    end

    local changes = {}
    for _, group in ipairs({ creates, moves, copies, deletes }) do
        vim.list_extend(changes, group)
    end
    return changes
end

return M
