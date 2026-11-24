-- lua/neo/plugins/lc/stats.lua
-- :Lc stats: what you have solved, by difficulty and tag, as a view in the
-- bottom panel. <CR> on a row opens the problems board filtered by it.

local config = require("neo.plugins.lc.config")
local ui = require("neo.plugins.lc.ui")

local M = {}

local last_doc
-- The board filter of each line.
local filters = {}

local function render(doc)
    local lines, hls, at = {}, {}, {}
    local function add(text, hl, filter)
        lines[#lines + 1] = text
        if hl then
            hls[#hls + 1] = { #lines - 1, 0, #text, hl }
        end
        at[#lines] = filter
    end
    local s = ("Solved %d of %d problems"):format(doc.solved or 0, doc.total or 0)
    if (doc.attempted or 0) > 0 then
        s = s .. (", attempted %d more"):format(doc.attempted)
    end
    add(s, "LcTitle")
    local function table_of(title, rows, key)
        add("")
        add(("%-24s %6s %9s %6s"):format(title, "Solved", "Attempted", "Total"), "LcLabel")
        for _, r in ipairs(rows or {}) do
            local name, filter = r[key], nil
            if key == "difficulty" then
                filter = { difficulty = name }
                name = name:sub(1, 1):upper() .. name:sub(2)
            else
                filter = { tags = { name } }
            end
            add(("%-24s %6d %9d %6d"):format(name, r.solved or 0, r.attempted or 0, r.total or 0), nil, filter)
        end
    end
    table_of("Difficulty", doc.difficulties, "difficulty")
    table_of("Tag", doc.tags, "tag")
    return lines, hls, at
end

local function draw(view)
    if not last_doc then
        return
    end
    local lines, hls
    lines, hls, filters = render(last_doc)
    view:replace(lines)
    ui.paint(view, hls)
end

local function refresh(view)
    local doc = ui.json({ "stats" })
    if doc then
        last_doc = doc
        view:when_stable(draw)
    end
end

local function drill()
    local filter = filters[vim.api.nvim_win_get_cursor(0)[1]]
    if not filter then
        ui.notify("lc: put the cursor on a difficulty or a tag")
        return
    end
    require("neo.plugins.lc.board").open(filter)
end

--- Opens the view in the panel. Returns its buffer and window.
function M.open()
    local doc = ui.json({ "stats" })
    if not doc then
        return
    end
    last_doc = doc
    local view = ui.view("lc://stats", {
        filetype = "lcstats",
        on_reload = draw,
        keys = ui.keys({
            { "<CR>", drill, desc = "Show these problems" },
            { "gr", refresh, desc = "Refresh" },
        }),
    })
    view:when_stable(draw)
    local win, err = ui.panel(view.buf, config.get().result or "botright 15split")
    if not win then
        return ui.error("lc: " .. err)
    end
    return view.buf, win
end

return M
