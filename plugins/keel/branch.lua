-- lua/neo/plugins/keel/branch.lua
-- Switching and creating branches through the shared picker, and fetch,
-- pull, and push. Network commands run in a real terminal split, so git,
-- SSH, and credential helpers can ask for whatever they need.
local git = require("neo.plugins.keel.git")
local parse = require("neo.plugins.keel.parse")
local malleable = require("neo.plugins.malleable")

local M = {}

local REF_FORMAT = "--format=%(refname)%00%(refname:short)%00%(HEAD)%00%(objectname:short)%00%(symref)%00%(subject)%1e"
local REF_FIELDS = { "ref", "name", "head", "short", "symref", "subject" }

local function refresh(state)
    require("neo.plugins.keel.status").refresh(state.repo.root)
end

local function after_switch(state, what)
    return function(result)
        if result.code ~= 0 then
            git.fail(what, result)
        else
            git.reload_buffers()
        end
        refresh(state)
    end
end

local function switch(state, item, branches)
    if item.head == "*" then return end
    local args = { "switch", item.name }
    if item.remote then
        local short = item.name:gsub("^[^/]+/", "")
        if branches[short] then
            args = { "switch", short }
        else
            args = { "switch", "--track", item.name }
        end
    end
    git.mutate(state.repo.root, args, { hooks = true }, after_switch(state, "switch"))
end

local function create(state, name)
    if name == "" then
        git.notify("type a name for the new branch", vim.log.levels.WARN)
        return
    end
    git.mutate(state.repo.root, { "switch", "-c", name }, { hooks = true }, after_switch(state, "create branch"))
end

--- Opens the branch picker: <CR> switches, <C-n> creates from the query.
function M.pick(state)
    git.run(state.repo.root, { "for-each-ref", "--sort=-committerdate", REF_FORMAT, "refs/heads", "refs/remotes" }, {},
        function(result)
            if result.code ~= 0 then return git.fail("list branches", result) end
            local locals, remotes, branches = {}, {}, {}
            for _, ref in ipairs(parse.records(result.stdout, REF_FIELDS)) do
                if ref.symref == "" then
                    ref.remote = ref.ref:sub(1, 13) == "refs/remotes/"
                    ref.display = ("%s %s  %s  %s"):format(ref.head == "*" and "*" or " ",
                        ref.name, ref.short, parse.clean(ref.subject))
                    if ref.remote then
                        remotes[#remotes + 1] = ref
                    else
                        branches[ref.name] = true
                        locals[#locals + 1] = ref
                    end
                end
            end
            require("neo.plugins.picker").open({
                title = " Branches ",
                items = vim.list_extend(locals, remotes),
                footer = " <CR> switch  <C-n> new from query ",
                on_select = function(item) switch(state, item, branches) end,
                keys = {
                    ["<C-n>"] = function(p)
                        local name = p:query()
                        p:close()
                        vim.schedule(function() create(state, name) end)
                    end,
                },
            })
        end)
end

-- Closes on success. A failure stays on screen, with git's output in it.
local function terminal(state, args, what)
    local origin = vim.api.nvim_get_current_win()
    vim.cmd("botright 10new")
    local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    vim.bo[buf].bufhidden = "wipe"

    local function on_exit(_, code)
        vim.schedule(function()
            git.release()
            if code == 0 then
                if vim.api.nvim_win_is_valid(win) then
                    pcall(vim.api.nvim_win_close, win, true)
                end
                if vim.api.nvim_win_is_valid(origin) then
                    vim.api.nvim_set_current_win(origin)
                end
                git.notify(what .. " finished")
            else
                git.notify(what .. " failed", vim.log.levels.ERROR)
            end
            -- (even a failed pull can have changed files)
            git.reload_buffers()
            refresh(state)
        end)
    end

    local command = vim.list_extend({ "git" }, args)
    local opts = { cwd = state.repo.root, on_exit = on_exit }
    git.hold()
    local ok, id
    if vim.fn.has("nvim-0.11") == 1 then
        opts.term = true
        ok, id = pcall(vim.fn.jobstart, command, opts)
    else
        ok, id = pcall(vim.fn.termopen, command, opts)
    end
    if not ok or type(id) ~= "number" or id <= 0 then
        git.release()
        pcall(vim.api.nvim_win_close, win, true)
        git.notify("couldn't start git " .. args[1], vim.log.levels.ERROR)
        return
    end
    vim.cmd("startinsert")
end

function M.fetch(state)
    terminal(state, { "fetch" }, "fetch")
end

function M.pull(state)
    terminal(state, { "pull", "--no-edit" }, "pull")
end

local function push_new(state, branch, remote)
    malleable.confirm({
        title = " Push ",
        lines = { ("Push %s to %s and track it?"):format(branch, remote) },
        on_yes = function()
            terminal(state, { "push", "--set-upstream", remote, branch }, "push")
        end,
    })
end

-- A branch with no upstream goes to remote.pushDefault, then origin, then
-- the only remote; otherwise you choose.
local function choose_remote(state, branch)
    git.all(state.repo.root, { { "remote" }, { "config", "--get", "remote.pushDefault" } }, function(results)
        local remotes = vim.split(vim.trim(results[1].stdout), "\n", { plain = true, trimempty = true })
        if #remotes == 0 then
            git.notify("this repository has no remotes", vim.log.levels.WARN)
            return
        end
        local default = vim.trim(results[2].stdout)
        if default == "" and vim.tbl_contains(remotes, "origin") then default = "origin" end
        if default == "" and #remotes == 1 then default = remotes[1] end
        if default ~= "" then
            push_new(state, branch, default)
            return
        end
        vim.ui.select(remotes, { prompt = "Push " .. branch .. " to:" }, function(remote)
            if remote then push_new(state, branch, remote) end
        end)
    end)
end

function M.push(state)
    local status = state.data and state.data.status
    if not status then return end
    if status.detached then
        git.notify("can't push a detached HEAD from here", vim.log.levels.WARN)
        return
    end
    if status.upstream then
        terminal(state, { "push" }, "push")
    else
        choose_remote(state, status.head)
    end
end

return M
