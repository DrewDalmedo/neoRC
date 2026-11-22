-- lua/neo/plugins/keel/log.lua
-- The commit log, and a detail view for one commit or stash.
local git = require("neo.plugins.keel.git")
local parse = require("neo.plugins.keel.parse")
local highlight = require("neo.plugins.keel.highlight")
local malleable = require("neo.plugins.malleable")

local M = {}

local PAGE = 200

local logs, shows = {}, {}

local WINDOW_OPTIONS = {
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldenable = false,
    wrap = false,
}

local function enter(state)
    local current = vim.api.nvim_get_current_buf()
    if current ~= state.view.buf then
        state.previous = current
        vim.api.nvim_win_set_buf(0, state.view.buf)
    end
    local win = vim.api.nvim_get_current_win()
    for name, value in pairs(WINDOW_OPTIONS) do
        vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
    end
end

local function leave(state)
    local previous = state.previous
    if previous and previous ~= state.view.buf and vim.api.nvim_buf_is_valid(previous) then
        vim.api.nvim_win_set_buf(0, previous)
    else
        vim.cmd("enew")
    end
end

local function render_log(state, commits)
    local lines, marks = {}, {}
    for i, commit in ipairs(commits) do
        local refs = commit.refs ~= "" and (" (" .. commit.refs .. ")") or ""
        lines[i] = parse.clean(("%s  %-14s  %-16s  %s%s"):format(
            commit.short, commit.date, commit.author, commit.subject, refs))
        marks[i] = { i - 1, "KeelHash", 0, #commit.short }
    end
    if #lines == 0 then lines = { "No commits yet" } end
    state.view:when_stable(function(view)
        view:replace(lines)
        state.commits = commits
        highlight.apply(view, marks)
    end)
end

local function load_log(state)
    git.run(state.repo.root, { "log", "-n", tostring(state.limit), parse.COMMIT_FORMAT }, {}, function(result)
        if state.view.disposed then return end
        -- (a branch with no commits is an error to `git log`, not a failure)
        render_log(state, result.code == 0 and parse.commits(result.stdout) or {})
    end)
end

--- Shows repo's log in the current window.
function M.open(repo)
    local state = logs[repo.root]
    if not state then
        state = { repo = repo, limit = PAGE, commits = {} }
        state.view = malleable.open({
            name = "keel://log/" .. repo.root,
            filetype = "keellog",
            on_reload = function() load_log(state) end,
            on_wipe = function() logs[repo.root] = nil end,
            keys = {
                { "<CR>", function()
                    local commit = state.commits[vim.fn.line(".")]
                    if commit then M.show(repo, { commit = commit.hash }) end
                end, desc = "Show commit" },
                { "+", function()
                    state.limit = state.limit + PAGE
                    load_log(state)
                end, desc = "Load more" },
                { "gr", function() load_log(state) end, desc = "Refresh" },
                { "g?", function() state.view:help() end, desc = "Help" },
                { "q", function() leave(state) end, desc = "Close" },
            },
        })
        logs[repo.root] = state
    end
    enter(state)
    load_log(state)
    return state
end

local function render_show(state, text)
    local lines, marks, in_diff = {}, {}, false
    for line in (text .. (text:sub(-1) == "\n" and "" or "\n")):gmatch("([^\n]*)\n") do
        local row = #lines
        lines[row + 1] = parse.clean(line)
        if line:sub(1, 11) == "diff --git " then
            in_diff = true
            marks[#marks + 1] = { row, "KeelFile" }
        elseif in_diff then
            local group = line:sub(1, 2) == "@@" and "KeelHunk" or nil
            if line:match("^%-%-%- ") or line:match("^%+%+%+ ") then
                group = "KeelNote"
            elseif not group then
                group = highlight.diff_group(line)
            end
            if group then marks[#marks + 1] = { row, group } end
        end
    end
    state.view:when_stable(function(view)
        view:replace(lines, { cursor = function() return 1 end })
        highlight.apply(view, marks)
    end)
end

--- Shows one commit ({ commit = hash }) or stash ({ stash = ref }).
function M.show(repo, target)
    local state = shows[repo.root]
    if not state then
        state = { repo = repo }
        state.view = malleable.open({
            name = "keel://show/" .. repo.root,
            filetype = "keelshow",
            on_reload = function()
                if state.args then M.load_show(state) end
            end,
            on_wipe = function() shows[repo.root] = nil end,
            keys = {
                { "g?", function() state.view:help() end, desc = "Help" },
                { "q", function() leave(state) end, desc = "Close" },
            },
        })
        shows[repo.root] = state
    end
    if target.stash then
        state.args = { "stash", "show", "--stat", "-p", "--no-ext-diff", "--no-color", target.stash }
    else
        state.args = { "show", "--format=fuller", "--stat", "-p", "--no-ext-diff", "--no-color", target.commit }
    end
    enter(state)
    M.load_show(state)
    return state
end

function M.load_show(state)
    local args = state.args
    git.run(state.repo.root, args, {}, function(result)
        if state.view.disposed or state.args ~= args then return end
        if result.code ~= 0 then return git.fail("show", result) end
        render_show(state, result.stdout)
    end)
end

return M
