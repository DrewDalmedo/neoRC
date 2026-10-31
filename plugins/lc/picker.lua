-- lua/neo/plugins/lc/picker.lua
-- Choosing a problem: neo's own floating picker (neo.plugins.picker), whose
-- fuzzy prompt matches the whole line (ID, difficulty, status, title and
-- tags), or vim.ui.select.

local config = require("neo.plugins.lc.config")

local M = {}

local STATUS = { solved = "solved", attempted = "tried", todo = "" }
local DIFFICULTY = { easy = "Easy", medium = "Medium", hard = "Hard" }

--- One line for a problem: ID, difficulty, status, title and tags.
function M.format(p)
    local tags = (p.tags and #p.tags > 0) and ("  (" .. table.concat(p.tags, ", ") .. ")") or ""
    return ("%-5d %-6s %-6s %s%s"):format(
        p.id,
        DIFFICULTY[p.difficulty] or p.difficulty or "",
        STATUS[p.status] or "",
        p.title,
        tags
    )
end

--- The picker in use: the picker option, "neo" or "select".
function M.which()
    return config.get().picker
end

local function neo(problems, opts, on_choice)
    local items = {}
    for i, p in ipairs(problems) do
        items[i] = { display = M.format(p), problem = p }
    end
    -- The picker closes before on_select, so the problem opens from the
    -- window that was current when :Lc list ran.
    return require("neo.plugins.picker").open({
        title = (" %s "):format(opts.title),
        items = items,
        on_select = function(item)
            on_choice(item.problem)
        end,
    })
end

local function select(problems, opts, on_choice)
    vim.ui.select(problems, { prompt = opts.title, format_item = M.format, kind = "lc.problem" }, function(p)
        if p then
            on_choice(p)
        end
    end)
end

--- Lets you choose one of problems (entries of `lc list --json`), then
--- calls on_choice(problem).
function M.pick(problems, opts, on_choice)
    opts = vim.tbl_extend("keep", opts or {}, { title = "Problems" })
    local impl = M.which() == "select" and select or neo
    return impl(problems, opts, on_choice)
end

return M
