-- lua/neo/plugins/syntax/init.lua
-- Syntax highlighting for languages Neovim ships no support for, defined
-- declaratively in Lua instead of vimscript syntax files. Each language is
-- one spec file in langs/ that returns a table; setup() scans the
-- directory, registers filetype detection, and applies the rules whenever
-- a buffer of that filetype opens:
--
--   -- langs/mylang.lua
--   return {
--       filetype = "mylang",
--       extensions = { "ml", "MLG" },          -- *.ml, *.MLG
--       filenames = { "Mfile" },               -- exact file names
--       patterns = { [[.*/mylang%.conf]] },    -- vim.filetype.add patterns
--       options = { commentstring = "# %s" },  -- buffer-local options
--       case = "match",                        -- or "ignore" for keywords
--       rules = {
--           { "mylangOperator", link = "Operator", match = [=[[-+*/=]]=] },
--           { "mylangKeyword",  link = "Keyword",  keywords = { "if", "fn" } },
--           { "mylangString",   link = "String",
--               region = { [["]], [["]], skip = [[\\"]] } },
--       },
--   }
--
-- A rule is [1] = syntax group name, link = highlight group it maps to,
-- and exactly one of:
--   keywords = { ... }   whole words, matched with the spec's case setting
--   match = [[pat]]      a vim regex (delimiters are added automatically)
--   region = { start, end }  with optional skip =; start/end may also be
--                            spelled start = / ["end"] =
-- opts = "..." appends raw :syn arguments (contained, contains=..., etc.)
-- for anything the shapes above don't cover.
--
-- Rules follow the syn engine's priority: when two rules match at the same
-- spot the one defined LAST wins, and keywords always beat matches and
-- regions. So list rules lowest priority first and keep comments and
-- strings at the bottom, where they swallow operators and keywords that
-- appear inside them.
--
-- The builtin :syntax machinery runs a "syn clear" for every buffer AFTER
-- user FileType autocmds fire, so rules are applied via vim.schedule to
-- land last. A real syntax plugin for the same filetype sets
-- b:current_syntax during that pass and wins; these rules only fill the
-- gap while no dedicated plugin is installed.
--
-- setup({ langs = { <spec>, ... } }) skips the scan and uses the given
-- specs; M.langs_dir may be repointed before setup() to scan elsewhere
-- (the tests do).

local M = {}

local config = { specs = {} }

-- langs/ lives next to this file, wherever the checkout is
local here = debug.getinfo(1, "S").source:sub(2):match("(.*)[/\\]")
M.langs_dir = vim.fs.joinpath(here, "langs")

local function fail(source, msg)
    vim.notify(("syntax: %s: %s"):format(source, msg), vim.log.levels.WARN)
end

-- Wrap a syn pattern in the first delimiter character that never occurs
-- inside it ('|' would end the command, so it is not a candidate).
local delimiters = { '"', "'", "/", "+", "@", "#", "!", "%", "&", ";", "=" }
local function delimit(pat)
    for _, d in ipairs(delimiters) do
        if not pat:find(d, 1, true) then return d .. pat .. d end
    end
    return nil, ("no delimiter character left for pattern %s"):format(pat)
end

-- Translate one rule into its ":syntax keyword/match/region" command.
local function compile_rule(rule)
    if type(rule) ~= "table" or type(rule[1]) ~= "string" or rule[1] == "" then
        return nil, "needs a syntax group name at [1]"
    end
    local group = rule[1]
    local forms = (rule.keywords ~= nil and 1 or 0) + (rule.match ~= nil and 1 or 0)
        + (rule.region ~= nil and 1 or 0)
    if forms ~= 1 then
        return nil, "needs exactly one of keywords / match / region"
    end
    local opts = rule.opts and (" " .. rule.opts) or ""
    if rule.keywords then
        if type(rule.keywords) ~= "table" or #rule.keywords == 0 then
            return nil, "keywords must be a non-empty list"
        end
        return ("syntax keyword %s%s %s"):format(group, opts, table.concat(rule.keywords, " "))
    end
    if rule.match then
        if type(rule.match) ~= "string" then return nil, "match must be a string" end
        local pat, err = delimit(rule.match)
        if not pat then return nil, err end
        return ("syntax match %s%s %s"):format(group, opts, pat)
    end
    local region = rule.region
    if type(region) ~= "table" then return nil, "region must be a table" end
    local ends = { start = region.start or region[1], skip = region.skip, ["end"] = region["end"] or region[2] }
    local parts = {}
    for _, name in ipairs({ "start", "skip", "end" }) do
        local pat = ends[name]
        if pat == nil and name ~= "skip" then
            return nil, "region needs start and end patterns"
        end
        if pat ~= nil then
            if type(pat) ~= "string" then return nil, "region " .. name .. " must be a string" end
            local wrapped, err = delimit(pat)
            if not wrapped then return nil, err end
            parts[#parts + 1] = name .. "=" .. wrapped
        end
    end
    return ("syntax region %s%s %s"):format(group, opts, table.concat(parts, " "))
end

-- Grab a detection list (extensions/filenames/patterns), complaining when
-- it is not a list of strings.
local function string_list(raw, source, what)
    if raw == nil then return {} end
    if type(raw) ~= "table" then
        fail(source, what .. " must be a list of strings")
        return {}
    end
    local out = {}
    for _, item in ipairs(raw) do
        if type(item) == "string" then
            out[#out + 1] = item
        else
            fail(source, ("%s entry %s is not a string"):format(what, vim.inspect(item)))
        end
    end
    return out
end

-- Validate one raw spec and precompile its syn commands and highlight
-- links. Broken rules are reported and dropped; the rest of the spec
-- stays usable.
local function compile_spec(raw, source)
    if type(raw) ~= "table" or type(raw.filetype) ~= "string" or raw.filetype == "" then
        fail(source, "spec must be a table with a filetype string")
        return nil
    end
    local case = raw.case or "match"
    if case ~= "match" and case ~= "ignore" then
        fail(source, ("case must be match or ignore, not %s"):format(vim.inspect(raw.case)))
        case = "match"
    end
    local spec = {
        filetype = raw.filetype,
        extensions = string_list(raw.extensions, source, "extensions"),
        filenames = string_list(raw.filenames, source, "filenames"),
        patterns = string_list(raw.patterns, source, "patterns"),
        options = type(raw.options) == "table" and raw.options or nil,
        case = case,
        commands = {},
        links = {},
    }
    for i, rule in ipairs(raw.rules or {}) do
        local cmd, err = compile_rule(rule)
        if not cmd then
            fail(source, ("rule %d: %s"):format(i, err))
        else
            spec.commands[#spec.commands + 1] = cmd
            if rule.link then spec.links[rule[1]] = rule.link end
        end
    end
    return spec
end

-- Load every *.lua spec file under dir (sorted, so priority between langs
-- is stable). Files that error or return nothing are reported.
function M.load_dir(dir)
    local names = {}
    pcall(function()
        for name, kind in vim.fs.dir(dir) do
            if kind == "file" and name:match("%.lua$") then names[#names + 1] = name end
        end
    end)
    table.sort(names)
    local entries = {}
    for _, name in ipairs(names) do
        local ok, spec = pcall(dofile, vim.fs.joinpath(dir, name))
        if not ok then
            fail(name, "failed to load: " .. tostring(spec))
        else
            entries[#entries + 1] = { source = name, spec = spec }
        end
    end
    return entries
end

-- Apply one compiled spec to the current buffer.
local function apply(spec)
    -- a dedicated syntax plugin got here first; let it win
    if vim.b.current_syntax then return end
    for name, value in pairs(spec.options or {}) do
        vim.opt_local[name] = value
    end
    vim.cmd("syntax case " .. spec.case)
    for _, cmd in ipairs(spec.commands) do
        vim.cmd(cmd)
    end
    for group, target in pairs(spec.links) do
        vim.api.nvim_set_hl(0, group, { link = target, default = true })
    end
    vim.b.current_syntax = spec.filetype
end

-- opts.langs replaces the scanned spec files for this setup call; without
-- it every langs/*.lua is loaded.
function M.setup(opts)
    opts = opts or {}
    local entries
    if opts.langs then
        entries = {}
        for i, spec in ipairs(opts.langs) do
            entries[i] = { source = ("langs[%d]"):format(i), spec = spec }
        end
    else
        entries = M.load_dir(M.langs_dir)
    end

    config.specs = {}
    local detect = { extension = {}, filename = {}, pattern = {} }
    for _, entry in ipairs(entries) do
        local spec = compile_spec(entry.spec, entry.source)
        if spec then
            config.specs[#config.specs + 1] = spec
            for _, ext in ipairs(spec.extensions) do detect.extension[ext] = spec.filetype end
            for _, name in ipairs(spec.filenames) do detect.filename[name] = spec.filetype end
            for _, pat in ipairs(spec.patterns) do detect.pattern[pat] = spec.filetype end
        end
    end
    vim.filetype.add(detect)

    local group = vim.api.nvim_create_augroup("NeoSyntax", { clear = true })
    for _, spec in ipairs(config.specs) do
        vim.api.nvim_create_autocmd("FileType", {
            group = group,
            pattern = spec.filetype,
            callback = function(ev)
                -- the builtin Syntax autocmd runs "syn clear" after this
                -- event; schedule past it so the rules land last
                vim.schedule(function()
                    if vim.api.nvim_buf_is_valid(ev.buf) then
                        vim.api.nvim_buf_call(ev.buf, function() apply(spec) end)
                    end
                end)
            end,
        })
    end
end

return M
