-- lua/neo/plugins/lc/catalog.lua
-- The problems lc knows (`lc list --json`), cached for completion and
-- titles. Statuses in the cache can be stale; commands that show them ask
-- lc again.

local cli = require("neo.plugins.lc.cli")

local M = {}

local cache, cached_at

--- Every problem, or nil and an error message.
function M.problems(refresh)
    if refresh or not cache then
        local doc, err = cli.json({ "list" })
        if not doc then
            return nil, err
        end
        cache, cached_at = doc.problems or {}, vim.uv.now()
    end
    return cache
end

function M.invalidate()
    cache = nil
end

local function lookup(list, spec)
    for _, p in ipairs(list) do
        if p.slug == spec then
            return p
        end
    end
    local id, slug = spec:match("^(%d+)$"), nil
    if not id then
        id, slug = spec:match("^(%d+)%-(.+)$")
    end
    id = tonumber(id)
    if not id then
        return nil
    end
    for _, p in ipairs(list) do
        if p.id == id and (slug == nil or p.slug == slug) then
            return p
        end
    end
    return nil
end

--- The problem an ID (1, "1", "0001"), slug or directory name names, by
--- lc's own rules (lc_problem_find): a slug first, then an ID, then a
--- directory name whose ID and slug both match.
--- A name that isn't found asks lc again, at most every few seconds, in
--- case a pack was added since.
function M.find(spec)
    local list = M.problems()
    if not list or spec == nil then
        return nil
    end
    spec = tostring(spec)
    local p = lookup(list, spec)
    if not p and vim.uv.now() - (cached_at or 0) > 3000 then
        list = M.problems(true)
        p = list and lookup(list, spec)
    end
    return p
end

--- "1. Two Sum" for a problem, or what is known of it.
function M.title(info)
    local p = info and (M.find(info.id) or M.find(info.slug))
    if p then
        return ("%d. %s"):format(p.id, p.title)
    end
    if info and info.id then
        return ("%d. %s"):format(info.id, info.slug or "?")
    end
    return nil
end

return M
