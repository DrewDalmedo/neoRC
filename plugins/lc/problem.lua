-- lua/neo/plugins/lc/problem.lua
-- Which problem a buffer belongs to, and its solution.

local M = {}

local LANGS = { c = "c", cpp = "cpp", cc = "cpp", cxx = "cpp" }

--- The directories lc start gave this session (real paths), to their IDs.
M.started = {}

function M.remember(dir, id)
    M.started[M.realpath(dir)] = id
end

--- The language of a solution file from its extension, as lc decides it.
function M.lang_of(path)
    local ext = path:match("%.([%w]+)$")
    return ext and LANGS[ext] or nil
end

--- The ID and slug in a problem directory's name, such as 0001-two-sum.
function M.parse_dirname(name)
    local id, slug = name:match("^(%d%d%d%d+)%-([%w][%w%-]*)$")
    if not id then
        return nil
    end
    return tonumber(id), slug
end

--- The problem a directory is for, from its name, as lc decides it: the
--- name is looked up as a problem (0001-two-sum, but also two-sum or 1,
--- as a symbolic link's target may be named). Without lc's list of
--- problems, only names like 0001-two-sum count.
function M.dir_problem(name)
    local catalog = require("neo.plugins.lc.catalog")
    if catalog.problems() then
        local p = catalog.find(name)
        if p then
            return p.id, p.slug
        end
        return nil
    end
    return M.parse_dirname(name)
end

--- The problem a path is in, or that a problem directory is:
--- { id, slug, dir, solution?, lang? }, or nil.
function M.from_path(path)
    if not path or path == "" then
        return nil
    end
    -- (vim.fs.normalize would expand $VARS in the names.)
    path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"), { expand_env = false })
    if #path > 1 then
        path = path:gsub("/$", "")
    end
    local stat = vim.uv.fs_stat(path)
    if stat and stat.type == "directory" then
        local id, slug = M.dir_problem(vim.fs.basename(path))
        return id and { id = id, slug = slug, dir = path } or nil
    end
    local dir = vim.fs.dirname(path)
    local id, slug = M.dir_problem(vim.fs.basename(dir))
    if not id then
        return nil
    end
    local info = { id = id, slug = slug, dir = dir }
    local lang = M.lang_of(path)
    if lang then
        info.solution = path
        info.lang = lang
    end
    return info
end

--- The problem a buffer is about: a file in a problem's directory, or one of
--- the plugin's own buffers (statement, result), which set b:lc_problem.
function M.from_buf(buf)
    buf = buf or 0
    local info = vim.b[buf].lc_problem
    if type(info) == "table" and info.id then
        return vim.deepcopy(info)
    end
    if vim.bo[buf].buftype ~= "" then
        return nil
    end
    return M.from_path(vim.api.nvim_buf_get_name(buf))
end

--- What `lc test` and `lc submit` should be given for a buffer: its
--- solution file; for another file of a problem's directory (README.md,
--- cases.txt), the solution shown in a window of this tab page, else the
--- directory; for the plugin's own buffers, the solution they recorded or the
--- problem's ID. Returns the argument and the problem, or nil.
function M.target(buf)
    buf = buf or 0
    local info = M.from_buf(buf)
    if not info then
        return nil
    end
    if info.solution then
        return info.solution, info
    end
    if info.dir then
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            local other = M.from_path(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)))
            if other and other.solution and other.dir == info.dir then
                return other.solution, other
            end
        end
        return info.dir, info
    end
    return tostring(info.id), info
end

--- The real path of a file, or the path itself when it doesn't exist.
function M.realpath(path)
    return vim.uv.fs_realpath(path) or path
end

--- The buffer for a file, if one is loaded, matching through symbolic links
--- (lc gives real paths: /private/tmp rather than /tmp on macOS).
function M.find_buf(path)
    local real = M.realpath(path)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(b)
        if name ~= "" and vim.bo[b].buftype == "" and (name == path or M.realpath(name) == real) then
            return b
        end
    end
    return nil
end

return M
