-- lua/neo/plugins/picker/fuzzy.lua
-- Subsequence fuzzy matcher, independent of any UI. Pure Lua, so it loads
-- standalone (tests) and from any plugin that needs matching without a picker.
local M = {}

local SEGMENT_SEPS = {
    ["/"] = true, ["\\"] = true, ["_"] = true,
    ["-"] = true, ["."] = true, [" "] = true,
}

-- Score `pattern` as a subsequence of `str`: 0 means no match, higher is
-- better. Consecutive hits and hits at segment starts are rewarded; an empty
-- pattern matches everything with score 1.
function M.score(str, pattern)
    if not pattern or pattern == "" then return 1 end
    local s, p = str:lower(), pattern:lower()
    local p_idx, score, consec = 1, 0, 0

    for i = 1, #s do
        if s:sub(i, i) == p:sub(p_idx, p_idx) then
            p_idx = p_idx + 1
            consec = consec + 1
            score = score + 10 + consec
            if i == 1 or SEGMENT_SEPS[s:sub(i - 1, i - 1)] then
                score = score + 8
            end
            if p_idx > #p then break end
        else
            consec = 0
        end
    end

    if p_idx <= #p then return 0 end
    -- Length penalty breaks ties toward shorter paths; clamp so a match stays > 0
    return math.max(score - #s * 0.05, 1)
end

-- Filter and rank `items` against `query`. `opts.key` extracts the string to
-- match from an item (default: item.display). Returns a new list, best match
-- first with original order breaking ties, truncated to `opts.limit`. An
-- empty query keeps the original order.
function M.filter(items, query, opts)
    opts = opts or {}
    local key = opts.key or function(item) return item.display end
    local limit = opts.limit or math.huge
    local out = {}

    if not query or query == "" then
        for i = 1, math.min(#items, limit) do
            out[i] = items[i]
        end
        return out
    end

    local scored = {}
    for idx, item in ipairs(items) do
        local s = M.score(key(item), query)
        if s > 0 then
            scored[#scored + 1] = { score = s, idx = idx, item = item }
        end
    end
    table.sort(scored, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.idx < b.idx
    end)
    for i = 1, math.min(#scored, limit) do
        out[i] = scored[i].item
    end
    return out
end

return M
