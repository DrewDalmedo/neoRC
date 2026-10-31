-- lua/neo/plugins/lc/statement.lua
-- A problem's statement as markdown, from `lc show --json`: the text of
-- the README.md that `lc start` writes, without its closing note, and with
-- a Status line, as `lc show` has, once you have submitted.

local M = {}

local DIFFICULTY = { easy = "Easy", medium = "Medium", hard = "Hard" }
local STATUS = { attempted = "Attempted", solved = "Solved" }

local function split(text)
    local lines = vim.split(text, "\n", { plain = true })
    if lines[#lines] == "" then
        lines[#lines] = nil
    end
    return lines
end

--- The examples as markdown lines, as README.md has them.
function M.examples(p)
    local out = {}
    for n, ex in ipairs(p.examples or {}) do
        if n > 1 then
            out[#out + 1] = ""
        end
        vim.list_extend(out, { ("**Example %d:**"):format(n), "", "```" })
        local inputs = ex.inputs or {}
        local named = #inputs > 0
        for _, input in ipairs(inputs) do
            named = named and input.name ~= nil
        end
        if named then
            local parts = {}
            for _, input in ipairs(inputs) do
                parts[#parts + 1] = ("%s = %s"):format(input.name, input.value)
            end
            out[#out + 1] = "Input: " .. table.concat(parts, ", ")
        else
            out[#out + 1] = "Input:"
            for _, input in ipairs(inputs) do
                out[#out + 1] = input.value
            end
        end
        vim.list_extend(out, { "Output: " .. (ex.output or ""), "```" })
        if ex.explanation then
            vim.list_extend(out, { "", "**Explanation:** " .. ex.explanation })
        end
    end
    return out
end

--- The statement of a problem (the "problem" member of `lc show --json`)
--- as a list of markdown lines.
function M.markdown(p)
    local meta = "**Difficulty:** " .. (DIFFICULTY[p.difficulty] or "Unknown")
    if p.tags and #p.tags > 0 then
        meta = meta .. " · **Tags:** " .. table.concat(p.tags, ", ")
    end
    if STATUS[p.status] then
        meta = meta .. " · **Status:** " .. STATUS[p.status]
    end
    local out = { ("# %d. %s"):format(p.id, p.title), "", meta, "" }

    -- The examples go where the statement's first @examples line is, else
    -- after it.
    local at
    for _, block in ipairs(p.blocks or {}) do
        if block.type == "examples" then
            at = block.line
            break
        end
    end
    local lines = split(p.statement or "")
    if at and at <= #lines then
        for i, line in ipairs(lines) do
            if i == at then
                vim.list_extend(out, M.examples(p))
            else
                out[#out + 1] = line
            end
        end
    else
        vim.list_extend(out, lines)
        if p.examples and #p.examples > 0 then
            out[#out + 1] = ""
            vim.list_extend(out, M.examples(p))
        end
    end
    return out
end

return M
