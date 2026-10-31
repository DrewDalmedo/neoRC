-- lua/neo/plugins/lc/commands.lua
-- The :Lc command: subcommands and completion.

local M = {}

local function lc()
    return require("neo.plugins.lc")
end

local DIFFICULTIES = { "easy", "medium", "hard" }
local STATUSES = { "todo", "attempted", "solved" }
local LANGS = { "c", "cpp" }

-- The items of list that start with lead, each once.
local function matching(list, lead)
    local out, seen = {}, {}
    for _, item in ipairs(list) do
        if item:sub(1, #lead) == lead and not seen[item] then
            seen[item] = true
            out[#out + 1] = item
        end
    end
    return out
end

-- Completes the last item of a comma-separated list, leaving out those
-- already in it.
local function matching_list(list, lead)
    local done, last = lead:match("^(.*,)([^,]*)$")
    if not done then
        done, last = "", lead
    end
    local chosen = {}
    for item in done:gmatch("[^,]+") do
        chosen[item] = true
    end
    local out = {}
    for _, item in ipairs(matching(list, last)) do
        if not chosen[item] then
            out[#out + 1] = done .. item
        end
    end
    return out
end

--- Problems a lead can name, as lc takes them: slugs; IDs, zero-padded or
--- not; and directory names like 0001-two-sum.
local function problems(lead)
    local list = require("neo.plugins.lc.catalog").problems() or {}
    local out = {}
    local digits = lead:match("^%d+$")
    local dirname = lead:match("^%d+%-")
    for _, p in ipairs(list) do
        if digits then
            local plain, padded = tostring(p.id), ("%04d"):format(p.id)
            if plain:sub(1, #lead) == lead then
                out[#out + 1] = plain
            elseif padded:sub(1, #lead) == lead then
                out[#out + 1] = padded
            end
        elseif dirname then
            local name = ("%04d-%s"):format(p.id, p.slug)
            if name:sub(1, #lead) == lead then
                out[#out + 1] = name
            end
        end
        -- (A slug can start with digits too: 1-bit-and-2-bit-characters.)
        if p.slug:sub(1, #lead) == lead then
            out[#out + 1] = p.slug
        end
    end
    return out
end

local function tags()
    local seen, out = {}, {}
    for _, p in ipairs(require("neo.plugins.lc.catalog").problems() or {}) do
        for _, t in ipairs(p.tags or {}) do
            if not seen[t] then
                seen[t] = true
                out[#out + 1] = t
            end
        end
    end
    table.sort(out)
    return out
end

local function stds()
    return vim.list_extend(vim.deepcopy(lc().STDS.cpp), lc().STDS.c)
end

-- File names for an argument: :Lc's arguments are split at spaces that
-- have no backslash before them, and | ends the command and " starts a
-- comment, so those need one.
local function files(lead)
    local out = {}
    for _, f in ipairs(vim.fn.getcompletion((lead:gsub("\\(.)", "%1")), "file")) do
        out[#out + 1] = (f:gsub('[ \t\\|"]', "\\%0"))
    end
    return out
end

-- Completes "--flag value" and "--flag=value": values(flag, lead) gives
-- a flag's values, or nil for a flag without any.
local function with_values(values, flags)
    return function(lead, words)
        local flag, value = lead:match("^(%-%-[%w-]+)=(.*)$")
        if flag then
            local out = {}
            for _, v in ipairs(values(flag, value) or {}) do
                out[#out + 1] = flag .. "=" .. v
            end
            return out
        end
        local list = values(words[#words] or "", lead)
        if list then
            return list
        elseif lead:sub(1, 1) == "-" then
            return matching(flags, lead)
        end
        return nil
    end
end

local complete_filters = (function()
    local complete = with_values(function(flag, lead)
        if flag == "--difficulty" then
            return matching_list(DIFFICULTIES, lead)
        elseif flag == "--status" then
            return matching_list(STATUSES, lead)
        elseif flag == "--tag" then
            return matching(tags(), lead)
        end
    end, { "--difficulty", "--status", "--tag" })
    return function(lead, words)
        return complete(lead, words) or {}
    end
end)()

local function complete_run(flags)
    local complete = with_values(function(flag, lead)
        if flag == "--lang" then
            return matching(LANGS, lead)
        elseif flag == "--std" then
            return matching(stds(), lead)
        elseif flag == "--case" then
            return files(lead)
        end
    end, flags)
    return function(lead, words)
        return complete(lead, words) or problems(lead)
    end
end

M.subcommands = {
    list = {
        run = function(args)
            lc().list(args)
        end,
        complete = complete_filters,
    },
    random = {
        run = function(args)
            lc().random(args)
        end,
        complete = complete_filters,
    },
    show = {
        run = function(args)
            lc().show(args[1])
        end,
        complete = function(lead, words)
            return #words == 0 and problems(lead) or {}
        end,
    },
    start = {
        run = function(args)
            local spec, lang
            local i = 1
            while i <= #args do
                local a = args[i]
                if a == "--lang" then
                    lang = args[i + 1]
                    i = i + 1
                elseif a:match("^%-%-lang=") then
                    lang = a:sub(8)
                elseif a == "c" or a == "cpp" then
                    lang = a
                else
                    spec = a
                end
                i = i + 1
            end
            lc().start(spec, lang)
        end,
        complete = function(lead, words)
            if words[#words] == "--lang" then
                return matching(LANGS, lead)
            elseif lead:match("^%-%-lang=") then
                local out = {}
                for _, l in ipairs(matching(LANGS, lead:sub(8))) do
                    out[#out + 1] = "--lang=" .. l
                end
                return out
            elseif lead:sub(1, 1) == "-" then
                return matching({ "--lang" }, lead)
            end
            local out = matching(LANGS, lead)
            if lead ~= "" then
                vim.list_extend(out, problems(lead))
            end
            return out
        end,
    },
    test = {
        run = function(args)
            lc().test(args)
        end,
        complete = complete_run({ "--lang", "--std", "--sanitize", "--case" }),
    },
    submit = {
        run = function(args)
            lc().submit(args)
        end,
        complete = complete_run({ "--lang", "--std", "--sanitize" }),
    },
    cancel = {
        run = function()
            lc().cancel()
        end,
    },
    result = {
        run = function()
            lc().result()
        end,
    },
    stats = {
        run = function()
            lc().stats()
        end,
    },
    std = {
        run = function(args)
            lc().std(args)
        end,
        complete = function(lead, words)
            local STDS = lc().STDS
            local lang = ({ c = "c", cpp = "cpp", ["c++"] = "cpp", cxx = "cpp" })[words[1] or ""]
            if #words == 0 then
                local all = { "c", "cpp", "default" }
                vim.list_extend(all, stds())
                return matching(all, lead)
            elseif #words == 1 and lang then
                local list = vim.deepcopy(STDS[lang])
                list[#list + 1] = "default"
                return matching(list, lead)
            end
            return {}
        end,
    },
}

function M.names()
    local names = vim.tbl_keys(M.subcommands)
    table.sort(names)
    return names
end

--- Runs :Lc with the arguments of a user command (:help nvim_create_user_command).
function M.run(o)
    local args = vim.deepcopy(o.fargs)
    local name = table.remove(args, 1) or "list"
    local sub = M.subcommands[name]
    if not sub then
        require("neo.plugins.lc.ui").error(("lc: unknown command '%s'; the commands are %s"):format(
            name,
            table.concat(M.names(), ", ")
        ))
        return
    end
    sub.run(args)
end

--- Splits a command line's arguments as :Lc gets them: at spaces with no
--- backslash before them.
function M.split_args(s)
    local words, cur, i = {}, {}, 1
    while i <= #s do
        local ch = s:sub(i, i)
        if ch == "\\" and i < #s then
            cur[#cur + 1] = s:sub(i, i + 1)
            i = i + 2
        else
            if ch:match("%s") then
                if #cur > 0 then
                    words[#words + 1] = table.concat(cur)
                    cur = {}
                end
            else
                cur[#cur + 1] = ch
            end
            i = i + 1
        end
    end
    if #cur > 0 then
        words[#words + 1] = table.concat(cur)
    end
    return words
end

--- Completes :Lc's arguments.
function M.complete(lead, cmdline, pos)
    -- The arguments after :Lc, past any modifiers or range before it
    -- (:tab Lc show ..., :silent Lc ...).
    -- (After a |, the command being typed starts after the last one.)
    local before = cmdline:sub(1, pos)
    local bar = 0
    for i = 1, #before do
        if before:sub(i, i) == "|" and before:sub(i - 1, i - 1) ~= "\\" then
            bar = i
        end
    end
    local args = before:sub(bar + 1):match("%f[%w]Lc!?%s+(.*)$")
    if not args then
        return {}
    end
    local words = M.split_args(args)
    if lead ~= "" then
        table.remove(words)
    end
    if #words == 0 then
        return matching(M.names(), lead)
    end
    local sub = M.subcommands[table.remove(words, 1)]
    if not sub or not sub.complete then
        return {}
    end
    return sub.complete(lead, words)
end

return M
