-- lua/neo/plugins/keel/patch.lua
-- Builds the patches behind hunk and line staging, from keel.parse's files.
-- Apply them with `git apply --recount`, adding -R when `reverse` is set, so
-- hunk headers don't need their counts fixed here.
local M = {}

local function join(file, hunk_header, body)
    local out = vim.list_extend({}, file.header)
    out[#out + 1] = hunk_header
    vim.list_extend(out, body)
    return table.concat(out, "\n") .. "\n"
end

--- The patch for one whole hunk.
function M.hunk(file, hunk)
    return join(file, hunk.header, hunk.lines)
end

-- "\ No newline at end of file" says its line is the last on its side of
-- the diff: both sides for context, one for - or +. A kept line after it on
-- that side is a patch git accepts and applies wrongly, gluing two lines
-- together, so it has to be caught here.
local function newline_markers_hold(body)
    for i, line in ipairs(body) do
        if line:sub(1, 1) == "\\" then
            local marked = (body[i - 1] or " "):sub(1, 1)
            for j = i + 1, #body do
                local c = body[j]:sub(1, 1)
                if c ~= "\\" and (marked == " " or c == " " or c == marked) then
                    return false
                end
            end
        end
    end
    return true
end

--- The patch for hunk.lines[first..last] only, or nil and why not.
--- Outside the selection, a change that isn't applied has to stay what it
--- is in the target: forward, a "-" line is still there (context) and a "+"
--- line isn't; applied in reverse, those two swap.
function M.lines(file, hunk, first, last, reverse)
    local body, changed, kept = {}, false, false
    for i, line in ipairs(hunk.lines) do
        local c = line:sub(1, 1)
        if c == "\\" then
            if kept then body[#body + 1] = line end
        elseif c == " " then
            body[#body + 1] = line
            kept = true
        elseif i >= first and i <= last then
            body[#body + 1] = line
            changed, kept = true, true
        elseif (c == "-" and not reverse) or (c == "+" and reverse) then
            body[#body + 1] = " " .. line:sub(2)
            kept = true
        else
            kept = false
        end
    end
    if not changed then
        return nil, "no changed lines selected"
    end
    if not newline_markers_hold(body) then
        return nil, "this selection touches a missing final newline: use the whole hunk"
    end
    return join(file, hunk.header, body)
end

return M
