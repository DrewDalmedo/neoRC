-- lua/neo/plugins/scope/files.lua
-- File picker: a breadth-first async filesystem scan streamed into the
-- generic picker, which handles fuzzy filtering against the prompt.
local picker = require("neo.plugins.picker")
local util = require("neo.plugins.picker.util")

local M = {}

local MAX_FILES = 50000
local MAX_DEPTH = 12
local ENTRIES_PER_TICK = 1000

local IGNORE_DIRS = {
    [".git"] = true, [".svn"] = true, [".hg"] = true,
    ["node_modules"] = true, ["__pycache__"] = true,
    [".cache"] = true, ["vendor"] = true, ["target"] = true,
    [".venv"] = true, ["env"] = true, [".tox"] = true,
    ["dist"] = true, ["build"] = true, [".next"] = true,
}

-- Walk `opts.cwd` breadth-first on the main loop, yielding between directory
-- batches so the UI stays responsive. Relative paths arrive in chunks via
-- on_chunk(list); on_done() fires once, including when the file cap is hit.
-- opts.cancelled() is polled between ticks to abandon a stale scan.
function M.scan_async(opts, on_chunk, on_done)
    local cancelled = opts.cancelled or function() return false end
    local queue = { { path = opts.cwd, rel = "", depth = 0 } }
    local idx = 1
    local count = 0

    local step
    step = function()
        if cancelled() then return end
        local chunk = {}
        local processed = 0

        while idx <= #queue do
            local dir = queue[idx]
            idx = idx + 1

            if dir.depth < MAX_DEPTH then
                -- pcall covers both unreadable dirs and errors raised mid-iteration
                pcall(function()
                    for name, type in vim.fs.dir(dir.path) do
                        processed = processed + 1
                        local rel = dir.rel == "" and name or (dir.rel .. "/" .. name)
                        if type == "directory" then
                            if not IGNORE_DIRS[name] then
                                table.insert(queue, {
                                    path = vim.fs.joinpath(dir.path, name),
                                    rel = rel, depth = dir.depth + 1,
                                })
                            end
                        elseif type == "file" or type == "link" then
                            count = count + 1
                            table.insert(chunk, rel)
                        end
                    end
                end)
                if count >= MAX_FILES then
                    on_chunk(chunk)
                    on_done()
                    return
                end
            end

            -- Yield only between directories: an interrupted iterator would drop entries
            if processed >= ENTRIES_PER_TICK then
                if #chunk > 0 then on_chunk(chunk) end
                vim.schedule(step)
                return
            end
        end

        if #chunk > 0 then on_chunk(chunk) end
        on_done()
    end
    step()
end

function M.open()
    local cwd = vim.fn.getcwd()
    local p = picker.open({
        title = " Find Files ",
        on_select = function(item)
            util.open_file(vim.fs.normalize(vim.fs.joinpath(cwd, item.display)))
        end,
    })

    M.scan_async({
        cwd = cwd,
        cancelled = function() return not p:valid() end,
    }, function(chunk)
        local items = {}
        for i, rel in ipairs(chunk) do
            items[i] = { display = rel }
        end
        p:add_items(items)
    end, function()
        p:refresh()
    end)

    return p
end

return M
