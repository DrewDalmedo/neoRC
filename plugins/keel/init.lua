-- lua/neo/plugins/keel/init.lua
-- A focused Git interface: status with inline diffs; staging by file, hunk,
-- or line; commit and amend; branches; fetch, pull, and push; log.
-- :Keel or <leader>g opens it, and g? lists its keys.
--
-- Interactive rebase, conflict resolution, and the like are left to git:
-- during a merge or rebase Keel shows the state and the conflicted files.
local git = require("neo.plugins.keel.git")
local highlight = require("neo.plugins.keel.highlight")

local M = {}

local function current_repo()
    local repo = git.find(vim.fn.getcwd())
    if repo then return repo end
    local name = vim.api.nvim_buf_get_name(0)
    if name ~= "" and vim.bo.buftype == "" then
        return git.find(vim.fs.dirname(name))
    end
    return nil
end

--- Opens the status view for the working directory's repository, or the
--- current file's when the working directory isn't in one.
function M.open()
    if vim.fn.executable("git") ~= 1 then
        git.notify("git isn't installed", vim.log.levels.ERROR)
        return
    end
    local repo = current_repo()
    if not repo then
        git.notify("not in a git repository", vim.log.levels.WARN)
        return
    end
    return require("neo.plugins.keel.status").open(repo)
end

function M.setup()
    highlight.setup()
    vim.api.nvim_create_user_command("Keel", function() M.open() end, {
        desc = "Open Keel's Git status",
    })
end

return M
