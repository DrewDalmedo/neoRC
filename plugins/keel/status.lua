-- lua/neo/plugins/keel/status.lua
-- The status view: what's changed, with inline diffs, and the keys that
-- stage, unstage, and discard it.
--
-- The buffer is a render of `state`. Collapsed things simply aren't in it
-- (no native folds), and state.rows maps each row to what it shows, rebuilt
-- with every render so the two can't drift apart.
local git = require("neo.plugins.keel.git")
local parse = require("neo.plugins.keel.parse")
local patch = require("neo.plugins.keel.patch")
local highlight = require("neo.plugins.keel.highlight")
local malleable = require("neo.plugins.malleable")

local M = {}

local MAX_DIFF_LINES = 5000
local RECENT_COMMITS = 10

local SECTIONS = {
    { key = "conflicted", title = "Conflicts" },
    { key = "untracked", title = "Untracked files" },
    { key = "unstaged", title = "Unstaged changes" },
    { key = "staged", title = "Staged changes" },
}

local IN_PROGRESS = {
    { "rebase-merge", "Rebasing" },
    { "rebase-apply", "Rebasing" },
    { "MERGE_HEAD", "Merging" },
    { "CHERRY_PICK_HEAD", "Cherry-picking" },
    { "REVERT_HEAD", "Reverting" },
    { "BISECT_LOG", "Bisecting" },
}

local WINDOW_OPTIONS = {
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldenable = false,
    wrap = false,
    cursorline = true,
}

local states = {}

local function is_open(state, id, default)
    local value = state.open[id]
    if value == nil then return default end
    return value
end

local function file_id(section, entry)
    return ("file:%s:%s"):format(section, entry.path)
end

local function marker(open)
    return open and "v" or ">"
end

local clean = parse.clean

local function in_progress(gitdir)
    for _, item in ipairs(IN_PROGRESS) do
        if vim.uv.fs_stat(gitdir .. "/" .. item[1]) then return item[2] end
    end
    return nil
end

-- Rendering ----------------------------------------------------------------

local function add_diff(state, add, section, entry, file_item)
    if entry.path:sub(-1) == "/" then
        add("    (untracked directory)", nil, "KeelNote")
        return
    end
    local diff = state.diffs[file_item.id]
    if not diff then
        add("    (loading)", nil, "KeelNote")
        return
    end
    if diff.note then
        add("    (" .. diff.note .. ")", nil, "KeelNote")
        return
    end
    local file = diff.file
    for n, hunk in ipairs(file.hunks) do
        local hunk_id = ("hunk:%s:%s:%d"):format(section, entry.path, n)
        local hunk_open = is_open(state, hunk_id, true)
        local hunk_item = {
            kind = "hunk", id = hunk_id, parent = file_item, section = section,
            entry = entry, file = file, hunk = hunk,
        }
        add(marker(hunk_open) .. " " .. hunk.header, hunk_item, "KeelHunk")
        if hunk_open then
            for i, line in ipairs(hunk.lines) do
                add(line, {
                    kind = "line", id = ("line:%s:%s:%d:%d"):format(section, entry.path, n, i),
                    parent = hunk_item, section = section, entry = entry,
                    file = file, hunk = hunk, index = i,
                }, highlight.diff_group(line))
            end
        end
    end
end

local function add_file(state, add, section, entry)
    local id = file_id(section, entry)
    local open = is_open(state, id, false)
    local label = entry.orig and (entry.orig .. " -> " .. entry.path) or entry.path
    local item = { kind = "file", id = id, section = section, entry = entry }
    add(("  %s %s %s"):format(marker(open), entry.status, label), item, "KeelFile")
    if open then add_diff(state, add, section, entry, item) end
end

local function add_list(state, out, add, key, title, rows)
    if #rows == 0 then return end
    local id = "section:" .. key
    local open = is_open(state, id, true)
    local first = #out.lines + 1
    add(("%s %s (%d)"):format(marker(open), title, #rows),
        { kind = "section", id = id, section = key }, "KeelSection")
    if open then
        for _, row in ipairs(rows) do row() end
    end
    out.sections[key] = { first = first, last = #out.lines }
    add("")
end

local function build(state)
    local out = { lines = {}, rows = {}, index = {}, marks = {}, sections = {} }
    local function add(text, item, group)
        local row = #out.lines + 1
        out.lines[row] = clean(text)
        out.rows[row] = item or { kind = "info", id = "info:" .. row }
        out.index[out.rows[row].id] = row
        if group then out.marks[#out.marks + 1] = { row - 1, group } end
    end

    local data = state.data
    local status = data.status
    local latest = data.commits[1]
    local head
    if status.detached then
        head = "(detached) " .. (latest and latest.short or "")
    else
        head = status.head or "?"
    end
    local subject = status.unborn and "(no commits yet)" or (latest and latest.subject or "")
    add("Head:     " .. head .. "  " .. subject, nil, "KeelHead")
    if status.upstream then
        local counts = {}
        if status.ahead > 0 then counts[#counts + 1] = "ahead " .. status.ahead end
        if status.behind > 0 then counts[#counts + 1] = "behind " .. status.behind end
        add("Upstream: " .. status.upstream
            .. (#counts > 0 and ("  (" .. table.concat(counts, ", ") .. ")") or ""))
    end
    if data.in_progress then
        add(data.in_progress .. ": finish or abort it with git", nil, "KeelBanner")
    end
    add("")

    for _, section in ipairs(SECTIONS) do
        local rows = {}
        for i, entry in ipairs(status[section.key]) do
            rows[i] = function() add_file(state, add, section.key, entry) end
        end
        add_list(state, out, add, section.key, section.title, rows)
    end

    local stashes = {}
    for i, stash in ipairs(data.stashes) do
        stashes[i] = function()
            add(("  %s %s"):format(stash.ref, stash.subject),
                { kind = "stash", id = "stash:" .. stash.ref, section = "stashes", ref = stash.ref })
        end
    end
    add_list(state, out, add, "stashes", "Stashes", stashes)

    local commits = {}
    for i, commit in ipairs(data.commits) do
        commits[i] = function()
            add(("  %s %s"):format(commit.short, commit.subject),
                { kind = "commit", id = "commit:" .. commit.hash, section = "commits", hash = commit.hash })
        end
    end
    add_list(state, out, add, "commits", "Recent commits", commits)

    local last = #out.lines
    if last > 1 and out.lines[last] == "" then
        out.index[out.rows[last].id] = nil
        out.lines[last], out.rows[last] = nil, nil
    end
    return out
end

-- Where a row's content went: the same thing, else what contained it, else
-- the same place in its section (staging a file lands on the next one).
local function locate(old, new, old_row)
    local item = old.rows and old.rows[old_row]
    if not item then return nil end
    local probe = item
    while probe do
        if new.index[probe.id] then return new.index[probe.id] end
        if probe.parent then
            -- A hunk that moved away: stay near it in the file.
            probe = probe.parent
        else
            break
        end
    end
    local before = old.sections and old.sections[item.section]
    local after = new.sections[item.section]
    if before and after then
        return math.min(after.first + (old_row - before.first), after.last)
    end
    return nil
end

local function render(state)
    if state.view.disposed or not state.data then return end
    state.view:when_stable(function(view)
        local new = build(state)
        local old = state.built or {}
        view:replace(new.lines, {
            cursor = function(_, old_row) return locate(old, new, old_row) end,
        })
        state.built = new
        state.rows = new.rows
        highlight.apply(view, new.marks)
        if (state.changing or 0) == 0 and not state.refreshing and not state.again then
            state.stale = false
        end
    end)
end

-- Loading ------------------------------------------------------------------

local function diff_args(section, entry)
    if section == "untracked" then
        return { "diff", "--no-index", "--no-ext-diff", "--no-color", "-U3", "--", "/dev/null", entry.path }
    end
    local args = { "diff", "--no-ext-diff", "--no-color", "-U3" }
    if section == "staged" then args[#args + 1] = "--cached" end
    args[#args + 1] = "--"
    args[#args + 1] = entry.path
    if entry.orig then args[#args + 1] = entry.orig end
    return args
end

local function read_diff(result)
    -- (--no-index exits 1 when the files differ, which they always do here)
    if result.code ~= 0 and result.code ~= 1 then
        return { note = "couldn't load the diff" }
    end
    local file = parse.diff(result.stdout)[1]
    if not file then return { note = "no changes" } end
    if file.binary then return { note = "binary file" } end
    if file.line_count > MAX_DIFF_LINES then
        return { note = ("diff too large: %d lines"):format(file.line_count) }
    end
    if #file.hunks == 0 then return { note = "no content changes" } end
    return { file = file }
end

local function wanted_diffs(state, status)
    local out = {}
    for _, key in ipairs({ "untracked", "unstaged", "staged" }) do
        for _, entry in ipairs(status[key]) do
            local id = file_id(key, entry)
            -- (an untracked directory has no diff of its own)
            if is_open(state, id, false) and entry.path:sub(-1) ~= "/" then
                out[#out + 1] = { id = id, args = diff_args(key, entry) }
            end
        end
    end
    return out
end

local refresh

local function finish_refresh(state)
    state.refreshing = false
    if state.again then
        refresh(state)
        return
    end
    render(state)
    local waiters = state.waiters
    state.waiters = {}
    for _, waiter in ipairs(waiters) do waiter() end
end

--- Reloads everything from git. Calls made while one is running collapse
--- into a single follow-up, so the last render always reflects the latest.
refresh = function(state, done)
    if done then state.waiters[#state.waiters + 1] = done end
    if state.refreshing then
        state.again = true
        return
    end
    if state.view.disposed then return end
    state.refreshing, state.again = true, false

    local root = state.repo.root
    git.all(root, {
        { "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal" },
        { "stash", "list", parse.STASH_FORMAT },
        { "log", "-n", tostring(RECENT_COMMITS), parse.COMMIT_FORMAT },
    }, function(results)
        if state.view.disposed then
            state.refreshing = false
            return
        end
        if results[1].code ~= 0 then
            git.fail("status", results[1])
            finish_refresh(state)
            return
        end
        local status = parse.status(results[1].stdout)
        local data = {
            status = status,
            stashes = results[2].code == 0 and parse.stashes(results[2].stdout) or {},
            commits = results[3].code == 0 and parse.commits(results[3].stdout) or {},
            in_progress = in_progress(state.repo.gitdir),
        }
        local wanted = wanted_diffs(state, status)
        local list = {}
        for i, want in ipairs(wanted) do list[i] = want.args end
        git.all(root, list, function(diffs)
            if state.view.disposed then
                state.refreshing = false
                return
            end
            local loaded = {}
            for i, want in ipairs(wanted) do
                loaded[want.id] = read_diff(diffs[i])
            end
            state.data, state.diffs = data, loaded
            finish_refresh(state)
        end)
    end)
end

-- Actions ------------------------------------------------------------------

local function selection(state)
    local mode = vim.fn.mode()
    if mode == "v" or mode == "V" or mode == "\22" then
        local a, b = vim.fn.line("v"), vim.fn.line(".")
        if a > b then a, b = b, a end
        local items = {}
        for row = a, b do items[#items + 1] = state.rows[row] end
        -- Read before leaving Visual: that's when a held refresh can land.
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
        return items, true
    end
    return { state.rows[vim.fn.line(".")] }, false
end

local ACTIONABLE = { section = true, file = true, hunk = true, line = true }

local function section_target(state, item)
    local entries = state.data.status[item.section]
    if not entries then return nil, "nothing to act on here" end
    return { kind = "files", section = item.section, entries = entries }
end

local function visual_target(items)
    local hunk, whole, first, last, same_hunk = nil, false, nil, nil, true
    for _, item in ipairs(items) do
        if item.kind == "file" or item.kind == "section" then
            same_hunk = false
        else
            hunk = hunk or item.hunk
            if item.hunk ~= hunk then same_hunk = false end
            if item.kind == "hunk" then
                whole = true
            else
                first = first and math.min(first, item.index) or item.index
                last = last and math.max(last, item.index) or item.index
            end
        end
    end
    if same_hunk and hunk then
        local item = items[1]
        if whole then
            return { kind = "hunk", section = item.section, entry = item.entry, file = item.file, hunk = hunk }
        end
        return {
            kind = "lines", section = item.section, entry = item.entry,
            file = item.file, hunk = hunk, first = first, last = last,
        }
    end

    local section, entries, seen = items[1].section, {}, {}
    for _, item in ipairs(items) do
        if item.kind == "section" or item.section ~= section then
            return nil, "select within one section"
        end
        if item.kind ~= "file" then
            return nil, "select lines in one hunk, or whole files"
        end
        if not seen[item.entry] then
            seen[item.entry] = true
            entries[#entries + 1] = item.entry
        end
    end
    return { kind = "files", section = section, entries = entries }
end

-- What the cursor or selection means: whole files, one hunk, or some lines.
-- On a single line without a selection that's its hunk, as in Magit.
local function target(state, items, visual)
    local useful = {}
    for _, item in ipairs(items) do
        if ACTIONABLE[item.kind] then useful[#useful + 1] = item end
    end
    if #useful == 0 then return nil, "nothing to act on here" end
    if visual then return visual_target(useful) end

    local item = useful[1]
    if item.kind == "section" then return section_target(state, item) end
    if item.kind == "file" then
        return { kind = "files", section = item.section, entries = { item.entry } }
    end
    return { kind = "hunk", section = item.section, entry = item.entry, file = item.file, hunk = item.hunk }
end

local function patch_text(t, reverse)
    if t.kind == "hunk" then return patch.hunk(t.file, t.hunk) end
    return patch.lines(t.file, t.hunk, t.first, t.last, reverse)
end

local function paths(entries, with_orig)
    local out = {}
    for _, entry in ipairs(entries) do
        out[#out + 1] = entry.path
        if with_orig and entry.orig then out[#out + 1] = entry.orig end
    end
    return out
end

-- The rows describe the repository before this change until the next render,
-- and git apply will happily find a stale patch's context somewhere else in
-- a file of repeated lines. So nothing acts on them until then.
local function mutate(state, args, opts, what, after)
    state.stale = true
    state.changing = (state.changing or 0) + 1
    git.mutate(state.repo.root, args, opts, function(result)
        state.changing = state.changing - 1
        if result.code ~= 0 then git.fail(what, result) end
        if after then after(result) end
        refresh(state)
    end)
end

local function current_target(state)
    local items, visual = selection(state)
    if state.stale then return nil, "still updating" end
    return target(state, items, visual)
end

local function stage(state)
    local t, err = current_target(state)
    if not t then return git.notify(err, vim.log.levels.WARN) end
    if t.section == "staged" then return git.notify("already staged") end
    if t.section == "conflicted" then
        return git.notify("resolve conflicts with git", vim.log.levels.WARN)
    end
    if t.section ~= "unstaged" and t.section ~= "untracked" then
        return git.notify("nothing to stage here", vim.log.levels.WARN)
    end
    if t.kind == "files" then
        return mutate(state, vim.list_extend({ "add", "--" }, paths(t.entries)), {}, "stage")
    end
    if t.section == "untracked" then
        return git.notify("stage the whole file while it's untracked", vim.log.levels.WARN)
    end
    local text, why = patch_text(t, false)
    if not text then return git.notify(why, vim.log.levels.WARN) end
    mutate(state, { "apply", "--cached", "--recount", "--whitespace=nowarn", "-" }, { stdin = text }, "stage")
end

local function unstage(state)
    local t, err = current_target(state)
    if not t then return git.notify(err, vim.log.levels.WARN) end
    if t.section ~= "staged" then return git.notify("nothing to unstage here", vim.log.levels.WARN) end
    if t.kind == "files" then
        return mutate(state, vim.list_extend({ "reset", "-q", "--" }, paths(t.entries, true)), {}, "unstage")
    end
    local text, why = patch_text(t, true)
    if not text then return git.notify(why, vim.log.levels.WARN) end
    mutate(state, { "apply", "--cached", "-R", "--recount", "--whitespace=nowarn", "-" }, { stdin = text }, "unstage")
end

local function discard(state)
    local t, err = current_target(state)
    if not t then return git.notify(err, vim.log.levels.WARN) end
    if t.section == "staged" then return git.notify("unstage it first", vim.log.levels.WARN) end
    if t.section == "conflicted" then
        return git.notify("resolve conflicts with git", vim.log.levels.WARN)
    end
    if t.section ~= "unstaged" and t.section ~= "untracked" then
        return git.notify("nothing to discard here", vim.log.levels.WARN)
    end

    local args, opts, lines = nil, {}, nil
    if t.kind == "files" then
        local names = paths(t.entries)
        if t.section == "untracked" then
            args = vim.list_extend({ "clean", "-f", "-d", "--" }, names)
            lines = { "Permanently delete untracked:" }
        else
            args = vim.list_extend({ "restore", "--worktree", "--" }, names)
            lines = { "Discard unstaged changes in:" }
        end
        for _, name in ipairs(names) do lines[#lines + 1] = "  " .. name end
    else
        if t.section == "untracked" then
            return git.notify("discard the whole file while it's untracked", vim.log.levels.WARN)
        end
        local text, why = patch_text(t, true)
        if not text then return git.notify(why, vim.log.levels.WARN) end
        args, opts = { "apply", "-R", "--recount", "--whitespace=nowarn", "-" }, { stdin = text }
        lines = { ("Discard the selected %s in:"):format(t.kind == "hunk" and "hunk" or "lines"), "  " .. t.entry.path }
    end

    malleable.confirm({
        title = " Discard ",
        lines = lines,
        on_yes = function() mutate(state, args, opts, "discard", git.reload_buffers) end,
    })
end

local function stage_all(state)
    if state.stale then return git.notify("still updating", vim.log.levels.WARN) end
    mutate(state, { "add", "-u" }, {}, "stage all")
end

local function unstage_all(state)
    if state.stale then return git.notify("still updating", vim.log.levels.WARN) end
    if state.data and state.data.status.unborn then
        return mutate(state, { "rm", "-r", "-q", "--cached", "--", "." }, {}, "unstage all")
    end
    mutate(state, { "reset", "-q" }, {}, "unstage all")
end

local function toggle(state)
    local item = state.rows[vim.fn.line(".")]
    if item and item.kind == "line" then item = item.parent end
    if not item or not (item.kind == "section" or item.kind == "file" or item.kind == "hunk") then
        return
    end
    local default = item.kind ~= "file"
    state.open[item.id] = not is_open(state, item.id, default)
    if item.kind == "file" and state.open[item.id] and not state.diffs[item.id] then
        refresh(state)
    else
        render(state)
    end
end

local function new_side_line(hunk, index)
    local line = hunk.new_start
    for i = 1, index - 1 do
        local c = hunk.lines[i]:sub(1, 1)
        if c == " " or c == "+" then line = line + 1 end
    end
    return line
end

local function visit(state)
    local item = state.rows[vim.fn.line(".")]
    if not item then return end
    if item.kind == "section" then return toggle(state) end
    if item.kind == "commit" then
        return require("neo.plugins.keel.log").show(state.repo, { commit = item.hash })
    end
    if item.kind == "stash" then
        return require("neo.plugins.keel.log").show(state.repo, { stash = item.ref })
    end
    if not item.entry then return end

    local path = vim.fs.joinpath(state.repo.root, item.entry.path)
    if vim.fn.filereadable(path) ~= 1 then
        return git.notify("no such file in the working tree: " .. item.entry.path, vim.log.levels.WARN)
    end
    local line
    if item.kind == "line" then
        line = new_side_line(item.hunk, item.index)
    elseif item.kind == "hunk" then
        line = item.hunk.new_start
    end
    require("neo.plugins.picker.util").open_file(path, line, line and 1 or nil)
end

local function close(state)
    local previous = state.previous
    if previous and previous ~= state.view.buf and vim.api.nvim_buf_is_valid(previous) then
        vim.api.nvim_win_set_buf(0, previous)
    else
        vim.cmd("enew")
    end
end

local function key_list(state)
    local function on(fn)
        return function() fn(state) end
    end
    local function lazy(module, name, ...)
        local args = { ... }
        return function()
            require("neo.plugins.keel." .. module)[name](state, unpack(args))
        end
    end
    return {
        { "<Tab>", on(toggle), desc = "Expand or collapse" },
        { "<CR>", on(visit), desc = "Open" },
        { "s", on(stage), desc = "Stage", mode = { "n", "x" } },
        { "u", on(unstage), desc = "Unstage", mode = { "n", "x" } },
        { "x", on(discard), desc = "Discard", mode = { "n", "x" } },
        { "S", on(stage_all), desc = "Stage all tracked" },
        { "U", on(unstage_all), desc = "Unstage all" },
        { "cc", lazy("commit", "open", { amend = false }), desc = "Commit" },
        { "ca", lazy("commit", "open", { amend = true }), desc = "Amend" },
        { "b", lazy("branch", "pick"), desc = "Branches" },
        { "f", lazy("branch", "fetch"), desc = "Fetch" },
        { "F", lazy("branch", "pull"), desc = "Pull" },
        { "P", lazy("branch", "push"), desc = "Push" },
        { "l", function() require("neo.plugins.keel.log").open(state.repo) end, desc = "Log" },
        { "gr", on(function(s) refresh(s) end), desc = "Refresh" },
        { "g?", function() state.view:help() end, desc = "Help" },
        { "q", on(close), desc = "Close" },
    }
end

-- Lifecycle ----------------------------------------------------------------

local function apply_window_options(win)
    for name, value in pairs(WINDOW_OPTIONS) do
        vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
    end
end

local function watch(state)
    local buf = state.view.buf
    local group = vim.api.nvim_create_augroup("neo.keel.status." .. buf, { clear = true })
    state.group = group
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        buffer = buf,
        callback = function() apply_window_options(vim.api.nvim_get_current_win()) end,
    })
    vim.api.nvim_create_autocmd("BufEnter", {
        group = group,
        buffer = buf,
        callback = function() refresh(state) end,
    })
    vim.api.nvim_create_autocmd({ "FocusGained", "BufWritePost" }, {
        group = group,
        callback = function()
            if #vim.fn.win_findbuf(buf) > 0 then refresh(state) end
        end,
    })
end

--- Shows the status view for repo in the current window.
function M.open(repo)
    local state = states[repo.root]
    if not state then
        state = { repo = repo, open = {}, diffs = {}, rows = {}, waiters = {} }
        state.view = malleable.open({
            name = "keel://status/" .. repo.root,
            filetype = "keelstatus",
            keys = key_list(state),
            on_reload = function() refresh(state) end,
            on_wipe = function()
                states[repo.root] = nil
                pcall(vim.api.nvim_del_augroup_by_id, state.group)
            end,
        })
        states[repo.root] = state
        watch(state)
    end
    local current = vim.api.nvim_get_current_buf()
    if current ~= state.view.buf then
        state.previous = current
        vim.api.nvim_win_set_buf(0, state.view.buf)
    end
    apply_window_options(vim.api.nvim_get_current_win())
    refresh(state)
    return state
end

--- Reloads the view for this repository, if it has one.
function M.refresh(root, done)
    local state = states[root]
    if state then
        refresh(state, done)
    elseif done then
        done()
    end
end

function M.get(root)
    return states[root]
end

--- True when nothing is loading or queued (for tests).
function M.idle()
    if not git.idle() then return false end
    for _, state in pairs(states) do
        if state.refreshing then return false end
    end
    return true
end

return M
