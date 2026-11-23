-- lua/neo/plugins/lc/picker.lua
-- Quick, one-shot choices: neo's own floating picker (neo.plugins.picker),
-- whose fuzzy prompt matches the whole line, or vim.ui.select. Anything you
-- stay in and act on is a malleable view instead (board.lua, stats.lua).

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

local function neo(list, opts, on_choice)
    local items = {}
    for i, value in ipairs(list) do
        items[i] = { display = opts.format(value), value = value }
    end
    -- The picker closes before on_select, so the choice acts from the
    -- window that was current when it opened.
    return require("neo.plugins.picker").open({
        title = (" %s "):format(opts.title),
        items = items,
        on_select = function(item)
            on_choice(item.value)
        end,
    })
end

local function select(list, opts, on_choice)
    vim.ui.select(list, { prompt = opts.title, format_item = opts.format, kind = opts.kind }, function(value)
        if value then
            on_choice(value)
        end
    end)
end

--- Lets you choose one of list, then calls on_choice(value).
--- opts: title, format(value) -> line, kind (for vim.ui.select).
function M.choose(list, opts, on_choice)
    local impl = M.which() == "select" and select or neo
    return impl(list, opts, on_choice)
end

--- Lets you choose one of problems (entries of `lc list --json`), then
--- calls on_choice(problem).
function M.pick(problems, opts, on_choice)
    opts = vim.tbl_extend("keep", opts or {}, { title = "Problems", format = M.format, kind = "lc.problem" })
    return M.choose(problems, opts, on_choice)
end

return M
