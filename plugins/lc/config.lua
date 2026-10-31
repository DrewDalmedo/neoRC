-- lua/neo/plugins/lc/config.lua
-- Options: the defaults, then the lc section of overrides.lua (a
-- gitignored, per-machine file, as graphical/ and projects use), then
-- vim.g.lc, then require("neo.plugins.lc").setup(opts).

local M = {}

M.defaults = {
    -- The lc command: a string, or a list for a command with arguments.
    -- A leading "~/" expands to the home directory.
    cmd = "lc",
    -- Which picker :Lc list uses: "neo" (neo.plugins.picker) or "select"
    -- (vim.ui.select).
    picker = "neo",
    -- What choosing a problem in :Lc list or :Lc random does: "start" (set it
    -- up and open it, like :Lc start) or "show" (its statement, like :Lc show).
    open = "start",
    -- How the statement opens beside the solution: an Ex command that splits
    -- the window, or false not to open it in :Lc start.
    statement = "leftabove vsplit",
    -- How the result window opens: an Ex command that splits the window, or
    -- false for no window (the verdict is still notified).
    result = "botright 15split",
    -- Write changed buffers of the problem's directory before a run.
    autowrite = true,
    -- Compile errors and sanitizer reports as vim.diagnostic entries.
    diagnostics = true,
    -- Compile errors, sanitizer reports and failed cases in the quickfix list.
    quickfix = true,
    -- vim.notify the verdict when a run ends.
    notify = true,
    -- Keys in the result buffer; false disables one.
    keys = {
        add_case = "a",
        jump = "<CR>",
        rerun = "r",
        cancel = "<C-c>",
        close = "q",
    },
}

M.options = nil

-- The lc section of overrides.lua, or {} when the file or the section is
-- absent. A broken file is reported, as projects does, rather than ignored.
local function overrides()
    local ok, cfg = pcall(require, "neo.overrides")
    if not ok then
        if not tostring(cfg):find("not found", 1, true) then
            vim.notify("lc: failed to load overrides.lua:\n" .. tostring(cfg), vim.log.levels.ERROR)
        end
        return {}
    end
    if type(cfg) ~= "table" or type(cfg.lc) ~= "table" then
        return {}
    end
    return cfg.lc
end

-- "~/x" to the home directory's x; anything else as it is.
local function expand(path)
    if type(path) == "string" and path:match("^~[/\\]") then
        return vim.fs.normalize(path)
    end
    return path
end

local function check(opts)
    local ok, err = pcall(function()
        local cmd = opts.cmd
        assert(type(cmd) == "string" or (type(cmd) == "table" and #cmd > 0),
            "cmd: a string or a non-empty list")
        assert(opts.picker == "neo" or opts.picker == "select", "picker: neo or select")
        assert(opts.open == "start" or opts.open == "show", "open: start or show")
        assert(opts.statement == false or type(opts.statement) == "string",
            "statement: an Ex command or false")
        assert(opts.result == false or type(opts.result) == "string",
            "result: an Ex command or false")
        assert(type(opts.keys) == "table", "keys: a table")
        for name, key in pairs(opts.keys) do
            assert(M.defaults.keys[name] ~= nil, ("keys.%s: no such key; the keys are %s"):format(
                tostring(name),
                table.concat(vim.tbl_keys(M.defaults.keys), ", ")
            ))
            assert(key == false or (type(key) == "string" and key ~= ""), ("keys.%s: a key, or false"):format(name))
        end
    end)
    if not ok then
        error("lc: bad option " .. tostring(err):gsub("^.-:%d+: ", ""), 0)
    end
end

--- Sets the options: the defaults, overrides.lua, vim.g.lc, then opts.
function M.setup(opts)
    local layers = { overrides(), vim.g.lc or {}, opts or {} }
    local merged = vim.deepcopy(M.defaults)
    for _, layer in ipairs(layers) do
        merged = vim.tbl_deep_extend("force", merged, layer)
        -- A list replaces the default list rather than being merged into it.
        if layer.cmd ~= nil then
            merged.cmd = vim.deepcopy(layer.cmd)
        end
    end
    if type(merged.cmd) == "table" then
        merged.cmd[1] = expand(merged.cmd[1])
    else
        merged.cmd = expand(merged.cmd)
    end
    check(merged)
    M.options = merged
    return merged
end

--- The options in effect. Without a setup() call, the defaults, overrides.lua
--- and vim.g.lc.
function M.get()
    return M.options or M.setup()
end

return M
