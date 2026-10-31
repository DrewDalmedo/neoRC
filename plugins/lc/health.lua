-- lua/neo/plugins/lc/health.lua
-- :checkhealth neo.plugins.lc

local M = {}

function M.check()
    local health = vim.health
    local cli = require("neo.plugins.lc.cli")
    local config = require("neo.plugins.lc.config")

    health.start("lc")
    if vim.fn.has("win32") == 1 then
        health.info("lc is off on native Windows (WSL is fine)")
        return
    end
    if vim.fn.has("nvim-0.10") == 1 then
        health.ok("Neovim " .. tostring(vim.version()))
    else
        health.error("Neovim 0.10 or later is needed")
    end

    local ok, err = pcall(config.get)
    if not ok then
        health.error(tostring(err))
        return
    end

    -- lc is optional: without it the plugin stays out of the way.
    local argv = cli.argv({})
    if vim.fn.executable(argv[1]) ~= 1 then
        health.warn(("%s isn't an executable, so :Lc isn't defined"):format(argv[1]), {
            "Install lcclone (make install), or set cmd in the lc section of overrides.lua",
        })
        return
    end
    if not require("neo.plugins.lc").enabled then
        health.warn("lc is there, but setup() didn't load: :Lc appears after a restart")
    end
    local doc, verr = cli.json({ "version" })
    if not doc then
        health.error("lc version: " .. tostring(verr))
        return
    end
    health.ok(("lc %s (%s), JSON schema %d"):format(doc.version or "?", vim.fn.exepath(argv[1]), doc.schema))

    local list, lerr = cli.json({ "list" })
    if not list then
        health.error("lc list: " .. tostring(lerr), { "Point LC_PROBLEMS at a directory of problem packs" })
    elseif #(list.problems or {}) == 0 then
        health.warn("lc finds no problems", { "Point LC_PROBLEMS at a directory of problem packs" })
    else
        health.ok(("%d problems"):format(#list.problems))
    end
    for _, w in ipairs(list and list.warnings or {}) do
        health.warn(w)
    end

    health.ok(("Picker: %s"):format(require("neo.plugins.lc.picker").which()))
    for lang, value in pairs(cli.std) do
        health.info(("%s standard for this session: %s"):format(lang == "c" and "C" or "C++", value))
    end
end

return M
