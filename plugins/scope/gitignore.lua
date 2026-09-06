-- lua/neo/plugins/scope/gitignore.lua
-- Shared .gitignore support for scope's file picker and live grep fallbacks.
-- Implements the usual pattern language: comments and blanks, `!` negation,
-- trailing-`/` directory-only rules, anchoring on a leading or inner `/`,
-- `*`, `?`, `[...]` classes, and `**` spanning path segments. Rules match
-- relative to the directory holding their .gitignore; a deeper .gitignore
-- overrides a shallower one and the last matching line in a file wins, as
-- in git. Only .gitignore files are read (no core.excludesFile or
-- .git/info/exclude) and matching is case-sensitive.
local M = {}

local function split_path(rel)
    return vim.split(rel, "/", { plain = true, trimempty = true })
end

local function escape_char(c)
    return c:match("%w") and c or ("%" .. c)
end

-- Translate one glob segment (contains no "/") into an anchored Lua pattern.
local function translate_segment(seg)
    local out = { "^" }
    local i, n = 1, #seg
    while i <= n do
        local c = seg:sub(i, i)
        if c == "*" then
            out[#out + 1] = ".*"
            while seg:sub(i + 1, i + 1) == "*" do i = i + 1 end
        elseif c == "?" then
            out[#out + 1] = "."
        elseif c == "\\" and i < n then
            i = i + 1
            out[#out + 1] = escape_char(seg:sub(i, i))
        elseif c == "[" then
            local j = i + 1
            local neg = seg:sub(j, j) == "!" or seg:sub(j, j) == "^"
            if neg then j = j + 1 end
            if seg:sub(j, j) == "]" then j = j + 1 end -- leading ] is literal
            local close = seg:find("]", j, true)
            if close then
                local inner = seg:sub(neg and i + 2 or i + 1, close - 1)
                inner = inner:gsub("[%%%]]", "%%%0")
                out[#out + 1] = "[" .. (neg and "^" or "") .. inner .. "]"
                i = close
            else
                out[#out + 1] = "%[" -- unclosed class: literal bracket
            end
        else
            out[#out + 1] = escape_char(c)
        end
        i = i + 1
    end
    out[#out + 1] = "$"
    return table.concat(out)
end

-- Parse one .gitignore line into a rule table, or nil for blanks/comments.
local function parse_rule(line)
    if line == "" or line:sub(1, 1) == "#" then return nil end
    while line:sub(-1) == " " and line:sub(-2, -2) ~= "\\" do
        line = line:sub(1, -2)
    end
    local neg = false
    if line:sub(1, 1) == "!" then
        neg = true
        line = line:sub(2)
    end
    local dir_only = false
    if line:sub(-1) == "/" then
        dir_only = true
        line = line:sub(1, -2)
    end
    if line == "" then return nil end
    if not line:find("/", 1, true) then
        line = "**/" .. line -- no slash: the name matches at any depth
    elseif line:sub(1, 1) == "/" then
        line = line:sub(2)
    end
    local segs = {}
    for _, s in ipairs(split_path(line)) do
        segs[#segs + 1] = s == "**" and s or translate_segment(s)
    end
    if #segs == 0 then return nil end
    return { neg = neg, dir_only = dir_only, segs = segs }
end

-- Match pattern segments pats[pi..] against path segments segs[si..last].
local function match_segs(pats, pi, segs, si, last)
    local np = #pats
    while pi <= np do
        local p = pats[pi]
        if p == "**" then
            if pi == np then return si <= last end -- trailing ** wants >=1 segment
            for k = si, last + 1 do
                if match_segs(pats, pi + 1, segs, k, last) then return true end
            end
            return false
        end
        if si > last or not segs[si]:find(p) then return false end
        pi, si = pi + 1, si + 1
    end
    return si > last
end

-- One rule list's opinion on segs[start..last]: true = ignore, false =
-- re-include (negated), nil = no rule matched. The last matching rule wins.
local function decide(rules, segs, start, last, is_dir)
    local res = nil
    for _, r in ipairs(rules) do
        if (is_dir or not r.dir_only) and match_segs(r.segs, 1, segs, start, last) then
            res = not r.neg
        end
    end
    return res
end

-- Walk a context chain innermost-first: the deepest .gitignore with an
-- opinion decides, matching git's precedence. A ctx node is
-- { parent = ctx|nil, depth = <segments between scan root and its dir>,
--   rules = <parsed rule list> }.
local function chain_ignored(ctx, segs, last, is_dir)
    local node = ctx
    while node do
        local d = decide(node.rules, segs, node.depth + 1, last, is_dir)
        if d ~= nil then return d end
        node = node.parent
    end
    return false
end

-- Parse .gitignore text into a rule list (possibly empty).
function M.parse(text)
    local rules = {}
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        rules[#rules + 1] = parse_rule(line)
    end
    return rules
end

-- Read and parse dir/.gitignore; nil when absent or without rules.
function M.load(dir)
    local f = io.open(dir .. "/.gitignore", "r")
    if not f then return nil end
    local text = f:read("*a") or ""
    f:close()
    local rules = M.parse(text)
    return #rules > 0 and rules or nil
end

-- Extend a context chain with the .gitignore of `dir`, a directory `depth`
-- path segments below the scan root. Returns ctx unchanged when the
-- directory contributes no rules, so chains stay short.
function M.extend(ctx, dir, depth)
    local rules = M.load(dir)
    if not rules then return ctx end
    return { parent = ctx, depth = depth, rules = rules }
end

-- One rule list's verdict on a path relative to its .gitignore's directory.
function M.match(rules, rel, is_dir)
    local segs = split_path(rel)
    return decide(rules, segs, 1, #segs, is_dir)
end

-- Is `rel` ("/"-separated, relative to the scan root) ignored under the
-- accumulated context chain? ctx may be nil when no .gitignore was seen.
function M.ignored(ctx, rel, is_dir)
    if not ctx then return false end
    local segs = split_path(rel)
    return chain_ignored(ctx, segs, #segs, is_dir)
end

-- Build an ignore test for paths relative to `root`, loading and caching
-- .gitignore chains lazily per directory (cached for the checker's
-- lifetime, so create one per picker session). Ancestor directories are
-- checked first: content of an ignored directory stays ignored even when a
-- deeper rule re-includes it, like git.
function M.checker(root)
    local cache = {} -- rel dir ("" = root) -> ctx chain, false = no rules

    local function dir_ctx(rel, depth)
        local hit = cache[rel]
        if hit ~= nil then return hit or nil end
        local parent_ctx = nil
        if rel ~= "" then
            parent_ctx = dir_ctx(rel:match("^(.*)/[^/]*$") or "", depth - 1)
        end
        local ctx = M.extend(parent_ctx, rel == "" and root or (root .. "/" .. rel), depth)
        cache[rel] = ctx or false
        return ctx
    end

    return function(file)
        file = file:gsub("\\", "/")
        -- Absolute paths can't be mapped onto the tree of .gitignore files
        -- under root; our search commands only emit relative paths anyway.
        if file:sub(1, 1) == "/" or file:match("^%a:") then return false end
        local segs = split_path(file)
        local prefix = ""
        for i = 1, #segs do
            local ctx = dir_ctx(prefix, i - 1)
            if ctx and chain_ignored(ctx, segs, i, i < #segs) then return true end
            prefix = prefix == "" and segs[i] or (prefix .. "/" .. segs[i])
        end
        return false
    end
end

return M
