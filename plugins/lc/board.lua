-- lua/neo/plugins/lc/board.lua
-- :Lc problems: every problem as a malleable view, to browse, narrow and act
-- on. lc does the filtering (lc list's flags), so the board always shows
-- what lc would. The picker does the one-shot choices inside it: finding a
-- problem and choosing a tag.
--
-- Opening the board clears the screen as switching projects does (changed
-- files are saved, everything else closes). Starting a problem hands the
-- board's window to the solution; a statement opens beside the board.

local catalog = require("neo.plugins.lc.catalog")
local config = require("neo.plugins.lc.config")
local picker = require("neo.plugins.lc.picker")
local ui = require("neo.plugins.lc.ui")

local M = {}

local DIFFICULTIES = { "easy", "medium", "hard" }
local STATUSES = { "todo", "attempted", "solved" }
local DIFFICULTY_HL = { easy = "LcAccepted", medium = "LcLimit", hard = "LcFailed" }
local STATUS_HL = { solved = "LcAccepted", attempted = "LcLimit" }

-- The summary and the keys come first.
local FIRST_ROW = 3

local function fresh()
    return {
        filters = { tags = {} },
        problems = {},
        rows = {}, -- line -> problem
        at = {}, -- problem ID -> line
    }
end

local state = fresh()

local function list_args(f)
    local args = { "list" }
    if f.difficulty then
        vim.list_extend(args, { "--difficulty", f.difficulty })
    end
    if f.status then
        vim.list_extend(args, { "--status", f.status })
    end
    for _, tag in ipairs(f.tags) do
        vim.list_extend(args, { "--tag", tag })
    end
    return args
end

-- Asks lc for the problems that pass filters: the filters in full and the
-- problems, or nil after an error, which lc's message explains.
local function fetch(filters)
    filters = { difficulty = filters.difficulty, status = filters.status, tags = filters.tags or {} }
    local doc = ui.json(list_args(filters))
    if not doc then
        return nil
    end
    return filters, doc.problems or {}
end

-- After an error, the board keeps what it had.
local function load(filters)
    local wanted, problems = fetch(filters)
    if not wanted then
        return false
    end
    state.filters, state.problems = wanted, problems
    return true
end

local function summary()
    local f, shown = state.filters, #state.problems
    local all = catalog.problems()
    local parts = { all and ("Problems: %d of %d"):format(shown, #all) or ("Problems: %d"):format(shown) }
    if f.difficulty then
        parts[#parts + 1] = f.difficulty
    end
    if f.status then
        parts[#parts + 1] = f.status
    end
    for _, tag in ipairs(f.tags) do
        parts[#parts + 1] = "#" .. tag
    end
    return table.concat(parts, " · ")
end

local function hints()
    local parts = { "<CR> open", "s start", "p statement", "fd difficulty", "fs status", "ft tag", "fc clear", "F find" }
    local help = config.get().keys.help
    if help then
        parts[#parts + 1] = help .. " keys"
    end
    return table.concat(parts, " · ")
end

-- The columns are picker.format's: ID, difficulty, status, title, tags.
local function row_highlights(hls, row, line, p)
    local col = math.max(#tostring(p.id), 5) + 1
    if DIFFICULTY_HL[p.difficulty] then
        hls[#hls + 1] = { row, col, col + 6, DIFFICULTY_HL[p.difficulty] }
    end
    col = col + 7
    if STATUS_HL[p.status] then
        hls[#hls + 1] = { row, col, col + 6, STATUS_HL[p.status] }
    end
    if p.tags and #p.tags > 0 then
        local width = #table.concat(p.tags, ", ") + 2 -- the parentheses
        hls[#hls + 1] = { row, #line - width, #line, "LcDim" }
    end
end

local function draw(view)
    local top, keys = summary(), hints()
    local lines, rows, at = { top, keys }, {}, {}
    local hls = { { 0, 0, #top, "LcTitle" }, { 1, 0, #keys, "LcDim" } }
    for _, p in ipairs(state.problems) do
        local line = picker.format(p)
        lines[#lines + 1] = line
        rows[#lines], at[p.id] = p, #lines
        row_highlights(hls, #lines - 1, line, p)
    end
    if #state.problems == 0 then
        lines[#lines + 1] = "No problem matches these filters"
        hls[#hls + 1] = { #lines - 1, 0, #lines[#lines], "LcDim" }
    end
    local before = state.rows
    state.rows, state.at = rows, at
    view:replace(lines, {
        -- Stay on the same problem; failing that, on a row that has one.
        cursor = function(_, row)
            local p = before[row]
            return p and at[p.id] or math.max(row, FIRST_ROW)
        end,
    })
    ui.paint(view, hls)
end

local function apply(view, filters)
    if vim.api.nvim_buf_is_valid(view.buf) and load(filters) then
        view:when_stable(draw)
    end
end

-- A copy of the filters, with changes.
local function with(changes)
    local f = vim.deepcopy(state.filters)
    for k, v in pairs(changes) do
        f[k] = v or nil
    end
    return f
end

local function next_in(list, value)
    for i, v in ipairs(list) do
        if v == value then
            return list[i + 1] or false
        end
    end
    return list[1]
end

local function on_problem(fn)
    return function()
        local p = state.rows[vim.api.nvim_win_get_cursor(0)[1]]
        if p then
            fn(p)
        else
            ui.notify("lc: put the cursor on a problem")
        end
    end
end

local function lc()
    return require("neo.plugins.lc")
end

-- Chooses a tag among the problems shown. Choosing one in use removes it.
local function choose_tag(view)
    local counts, active = {}, {}
    for _, tag in ipairs(state.filters.tags) do
        counts[tag], active[tag] = 0, true
    end
    for _, p in ipairs(state.problems) do
        for _, tag in ipairs(p.tags or {}) do
            counts[tag] = (counts[tag] or 0) + 1
        end
    end
    local tags = vim.tbl_keys(counts)
    if #tags == 0 then
        ui.notify("lc: these problems have no tags")
        return
    end
    table.sort(tags)
    picker.choose(tags, {
        title = "Filter by tag",
        kind = "lc.tag",
        format = function(tag)
            return ("%s %s  %d"):format(active[tag] and "*" or " ", tag, counts[tag])
        end,
    }, function(tag)
        local chosen = vim.tbl_filter(function(t)
            return t ~= tag
        end, state.filters.tags)
        if not active[tag] then
            chosen[#chosen + 1] = tag
        end
        apply(view, with({ tags = chosen }))
    end)
end

-- Fuzzy-finds a problem on the board and puts the cursor on it.
local function find(view)
    if #state.problems == 0 then
        return
    end
    local win = vim.api.nvim_get_current_win()
    picker.pick(state.problems, { title = "Find a problem" }, function(p)
        local row = state.at[p.id]
        if row and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == view.buf then
            vim.api.nvim_set_current_win(win)
            vim.api.nvim_win_set_cursor(win, { row, 0 })
        end
    end)
end

local function board_view()
    local view = ui.view("lc://problems", {
        filetype = "lcproblems",
        on_reload = draw,
        on_wipe = function()
            state = fresh()
        end,
        keys = ui.keys({
            { "<CR>", on_problem(function(p) lc().open(p) end), desc = "Open the problem" },
            { "s", on_problem(function(p) lc().start(tostring(p.id)) end), desc = "Start it" },
            { "p", on_problem(function(p) lc().show(tostring(p.id)) end), desc = "Show its statement" },
            {
                "fd",
                function(view)
                    apply(view, with({ difficulty = next_in(DIFFICULTIES, state.filters.difficulty) }))
                end,
                desc = "Next difficulty",
            },
            {
                "fs",
                function(view)
                    apply(view, with({ status = next_in(STATUSES, state.filters.status) }))
                end,
                desc = "Next status",
            },
            { "ft", choose_tag, desc = "Add or remove a tag" },
            {
                "fc",
                function(view)
                    apply(view, { tags = {} })
                end,
                desc = "Clear the filters",
            },
            { "F", find, desc = "Find a problem" },
            {
                "gr",
                function(view)
                    apply(view, state.filters)
                end,
                desc = "Refresh",
            },
        }),
    })
    state.view = view
    return view
end

-- Clears the screen for the board. The window left may have been the
-- result panel's, so it stops being one.
local function take_screen(view)
    require("neo.plugins.projects").clear(view.buf)
    local win = vim.api.nvim_get_current_win()
    vim.w[win].lc_result, vim.w[win].lc_statement = nil, nil
    vim.wo[win].winfixheight = false
    ui.plain(win)
    return win
end

--- Opens the board and moves there. filters: difficulty, status and tags,
--- as lc list takes them; nil keeps the current ones. A board already on
--- screen just updates, so a statement beside it stays. Bad filters change
--- nothing, and neither does saying no to discarding a view's unsaved
--- edits. Returns the view and its window, unless it has to ask first.
function M.open(filters)
    local wanted, problems = fetch(filters or state.filters)
    if not wanted then
        return
    end
    local function show()
        state.filters, state.problems = wanted, problems
        local view = board_view()
        local win = ui.board_win()
        if win then
            vim.api.nvim_set_current_win(win)
        else
            win = take_screen(view)
        end
        view:when_stable(draw)
        return view, win
    end
    if ui.board_win() then
        return show()
    end
    return require("neo.plugins.projects").discarding("Discard unsaved edits and open the problems?", show)
end

-- lc list's filter flags, as --flag value or --flag=value.
local function parse(fargs)
    local filters, i = { tags = {} }, 1
    while i <= #fargs do
        local arg = fargs[i]
        local name, value = arg:match("^%-%-(%a+)=(.*)$")
        if not name then
            name = arg:match("^%-%-(%a+)$")
            i = i + 1
            value = fargs[i]
        end
        if name ~= "difficulty" and name ~= "status" and name ~= "tag" then
            return nil, ("unknown argument '%s': --difficulty, --tag or --status"):format(arg)
        elseif not value or value == "" then
            return nil, ("--%s needs a value"):format(name)
        elseif name == "tag" then
            filters.tags[#filters.tags + 1] = value
        else
            filters[name] = value
        end
        i = i + 1
    end
    return filters
end

--- :Lc problems [filters]. Without any, the board keeps the ones it has.
function M.run(fargs)
    if not fargs or #fargs == 0 then
        return M.open()
    end
    local filters, err = parse(fargs)
    if not filters then
        return ui.error("lc: " .. err)
    end
    return M.open(filters)
end

-- A submission changes statuses: keep a board on screen up to date.
vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("lc.board", { clear = true }),
    pattern = "LcRunDone",
    callback = function(ev)
        local view = state.view
        if view and ev.data and ev.data.kind == "submit" and #vim.fn.win_findbuf(view.buf) > 0 then
            apply(view, state.filters)
        end
    end,
})

return M
