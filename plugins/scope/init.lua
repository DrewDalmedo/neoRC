-- lua/neo/plugins/scope/init.lua
-- Scope: file finding and live grep, built on the generic picker framework
-- (neo.plugins.picker). Each mode lives in its own module:
--   files.lua     - async filesystem scan feeding the fuzzy file picker
--   grep.lua      - external search tool streaming into the picker
--   gitignore.lua - .gitignore parsing/matching shared by both modes
local M = {}

function M.find_files()
    return require("neo.plugins.scope.files").open()
end

function M.live_grep()
    return require("neo.plugins.scope.grep").open()
end

function M.setup()
    vim.api.nvim_create_user_command("ScopeFiles", M.find_files, { desc = "Scope: Find Files" })
    vim.api.nvim_create_user_command("ScopeGrep", M.live_grep, { desc = "Scope: Live Grep" })
end

return M
