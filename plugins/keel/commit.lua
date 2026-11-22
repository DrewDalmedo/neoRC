-- lua/neo/plugins/keel/commit.lua
-- The commit message buffer. :w only saves a draft, so a habitual save can
-- never create a commit: <C-c><C-c> commits and <C-c><C-k> aborts. The
-- message goes to `git commit -F -`, so the hooks still run, and a failed
-- commit leaves the buffer and its text as they were.
local git = require("neo.plugins.keel.git")
local malleable = require("neo.plugins.malleable")

local M = {}

local HINT = " <C-c><C-c> commit   <C-c><C-k> abort   :w save draft "

local function draft_path(repo, amend)
    return repo.gitdir .. (amend and "/KEEL_AMEND_DRAFT" or "/KEEL_COMMIT_DRAFT")
end

local function read_lines(path)
    if vim.fn.filereadable(path) ~= 1 then return nil end
    return vim.fn.readfile(path)
end

local function trim_end(lines)
    while #lines > 1 and vim.trim(lines[#lines]) == "" do
        lines[#lines] = nil
    end
    return lines
end

local function first_lines(repo, amend)
    local draft = read_lines(draft_path(repo, amend))
    if draft and #draft > 0 then return draft end
    if amend then
        local result = git.run_sync(repo.root, { "log", "-1", "--format=%B" })
        if result.code == 0 then
            return trim_end(vim.split(result.stdout, "\n", { plain = true }))
        end
    end
    -- A merge's prepared message, minus git's comment lines: this message
    -- is committed exactly as written.
    local merge = read_lines(repo.gitdir .. "/MERGE_MSG")
    if merge then
        local kept = {}
        for _, line in ipairs(merge) do
            if line:sub(1, 1) ~= "#" then kept[#kept + 1] = line end
        end
        return trim_end(kept)
    end
    return { "" }
end

local function close(state, view)
    for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do
        if #vim.api.nvim_list_wins() > 1 then
            pcall(vim.api.nvim_win_close, win, true)
        elseif state.view and vim.api.nvim_buf_is_valid(state.view.buf) then
            vim.api.nvim_win_set_buf(win, state.view.buf)
        end
    end
    pcall(vim.api.nvim_buf_delete, view.buf, { force = true })
end

local function commit(state, view, amend)
    if view.committing then return end
    local lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
    local message = table.concat(lines, "\n")
    if vim.trim(message) == "" then
        git.notify("write a message first", vim.log.levels.WARN)
        return
    end
    vim.cmd("stopinsert")

    local args = { "commit", "--cleanup=whitespace", "-F", "-" }
    if amend then args[#args + 1] = "--amend" end
    -- Locked while hooks run, so nothing typed now is lost when it closes.
    view.committing = true
    vim.bo[view.buf].modifiable = false
    git.mutate(state.repo.root, args, { stdin = message .. "\n", hooks = true }, function(result)
        view.committing = false
        if vim.api.nvim_buf_is_valid(view.buf) then
            vim.bo[view.buf].modifiable = true
        end
        if result.code ~= 0 then
            git.fail(amend and "amend" or "commit", result)
            require("neo.plugins.keel.status").refresh(state.repo.root)
            return
        end
        vim.fn.delete(draft_path(state.repo, amend))
        close(state, view)
        git.notify((amend and "amended: " or "committed: ") .. vim.trim(lines[1] or ""))
        require("neo.plugins.keel.status").refresh(state.repo.root)
    end)
end

local function abort(state, view, amend)
    vim.cmd("stopinsert")
    local path = draft_path(state.repo, amend)
    if not vim.bo[view.buf].modified and vim.fn.filereadable(path) ~= 1 then
        close(state, view)
        return
    end
    malleable.confirm({
        title = " Abort ",
        lines = { "Throw away this message?" },
        on_yes = function()
            vim.fn.delete(path)
            close(state, view)
        end,
    })
end

local function show(view)
    local existing = vim.fn.win_findbuf(view.buf)[1]
    if existing then
        vim.api.nvim_set_current_win(existing)
        return
    end
    vim.cmd("botright 12split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, view.buf)
    vim.api.nvim_set_option_value("winbar", HINT, { scope = "local", win = win })
end

--- opts.amend: rewrite the last commit.
function M.open(state, opts)
    local repo, amend = state.repo, opts.amend
    local status = state.data and state.data.status
    if amend and status and status.unborn then
        git.notify("no commit to amend yet", vim.log.levels.WARN)
        return
    end
    if not amend and status and #status.staged == 0 and not state.data.in_progress then
        git.notify("nothing staged", vim.log.levels.WARN)
        return
    end

    local path = draft_path(repo, amend)
    local view, created
    view, created = malleable.open({
        name = ("keel://%s/%s"):format(amend and "amend" or "commit", repo.root),
        filetype = "gitcommit",
        editable = true,
        on_write = function(v, done)
            local lines = vim.api.nvim_buf_get_lines(v.buf, 0, -1, false)
            local ok, result = pcall(vim.fn.writefile, lines, path)
            if ok and result == 0 then
                done(true)
            else
                git.notify("couldn't save the draft", vim.log.levels.ERROR)
                done(false)
            end
        end,
        on_reload = function(v)
            local draft = read_lines(path)
            if draft then v:replace(draft, { force = true }) end
        end,
        keys = {
            { "<C-c><C-c>", function(v) commit(state, v, amend) end, desc = "Commit", mode = { "n", "i" } },
            { "<C-c><C-k>", function(v) abort(state, v, amend) end, desc = "Abort", mode = { "n", "i" } },
            { "g?", function(v) v:help() end, desc = "Help" },
        },
    })
    if created then view:replace(first_lines(repo, amend)) end
    show(view)
    if vim.trim(table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "")) == "" then
        vim.cmd("startinsert")
    end
    return view
end

return M
