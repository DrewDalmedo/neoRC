-- lua/neo/plugins/harbor/init.lua
-- Harbor: a file explorer you edit like text. A directory is a buffer with
-- one entry per line, and :w (or <C-;>) applies what you changed:
--
--   change a name                      rename
--   type a new line                    new file ("name/" a directory,
--                                      "a/b.txt" with its parents)
--   dd                                 delete
--   dd, go to another directory, p     move
--   yy, p, change the name             copy (or paste it somewhere else)
--
-- Edits across several directories are one save. Every save shows what it
-- will do first: y applies it; n, q or <Esc> keeps editing. :wq shows the
-- same question and leaves the listing open, since the save only finishes
-- once you've answered.
--
-- :Harbor [dir] opens a directory (default: the current file's, with the
-- cursor on it). It also takes over from netrw for :e some/dir, nvim ., and
-- project switches; :Explore and netrw's scp:// editing still work.
--
-- Keys in a listing:
--   <CR>   open the file or directory    g.   show or hide dotfiles
--   -      go up a directory             gy   copy the path to the clipboard
--   gR     read the listing from disk    g?   list these keys
--
-- A save is all or nothing up front: before touching anything it refuses
-- if something changed on disk since it was listed, a target exists, a file
-- it would move or delete has unsaved changes, or it would touch a
-- filesystem root, your home directory, or the config directory itself
-- (files inside the config are fine). Deletes run last and are permanent.
-- If an operation still fails, Harbor stops there and reports what was
-- done, what failed, and what never ran.
--
-- diff.lua turns edited lines into changes, plan.lua checks and orders
-- them, fs.lua runs them, sync.lua updates buffers, working directories and
-- anchor slots, and view.lua draws the listing. The buffer itself is a
-- malleable view (see neo.plugins.malleable).
--
-- The tests: nvim -l path/to/plugins/harbor/test.lua
local malleable = require("neo.plugins.malleable")
local diff = require("neo.plugins.harbor.diff")
local fs = require("neo.plugins.harbor.fs")
local plan = require("neo.plugins.harbor.plan")
local sync = require("neo.plugins.harbor.sync")
local hview = require("neo.plugins.harbor.view")

local M = {}

local api = vim.api
local uv = vim.uv

local config = { show_hidden = true }

-- Listings by buffer: { view, dir, shown = { [row] = id } }.
local states = {}
-- A save's confirmation is open.
local saving = false

local function notify(message, level)
    vim.notify("harbor: " .. message, level or vim.log.levels.INFO)
end

local function resolve(path)
    return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"), { expand_env = false })
end

local function render(state, opts)
    opts = opts or {}
    local entries, err = hview.scan(state.dir, config.show_hidden)
    if not entries then
        notify(("can't read %s: %s"):format(fs.short(state.dir), tostring(err)), vim.log.levels.ERROR)
        return false
    end
    local rows, ids = {}, {}
    for row, entry in ipairs(entries) do
        rows[entry.id] = row
        ids[row] = entry.id
    end
    local shown = state.shown
    local replaced = state.view:replace(hview.lines(entries), {
        force = opts.force,
        cursor = function(win, old_row)
            if opts.focus and (not opts.win or opts.win == win) then
                for row, entry in ipairs(entries) do
                    if entry.name == opts.focus then return row end
                end
            end
            local id = shown[old_row]
            return id and rows[id] or nil
        end,
    })
    if not replaced then
        return false
    end
    state.shown = ids
    for _, win in ipairs(vim.fn.win_findbuf(state.view.buf)) do
        hview.clamp(win)
    end
    return true
end

local function refresh(state, opts)
    state.view:when_stable(function()
        render(state, opts)
    end)
end

local function modified_states()
    local out = {}
    for buf, state in pairs(states) do
        if api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
            out[#out + 1] = state
        end
    end
    table.sort(out, function(a, b) return a.view.buf < b.view.buf end)
    return out
end

local function protected(path)
    return require("neo.plugins.projects").protected(path, { allow_config_contents = true })
end

-- Where a listing of dir belongs after result: a moved directory's new
-- path, or the nearest directory left above a deleted one.
local function destination(dir, result)
    for _, m in ipairs(result.moved) do
        if fs.within(dir, m.from) then
            return m.to .. dir:sub(#m.from + 1)
        end
    end
    for _, path in ipairs(result.deleted) do
        if fs.within(dir, path) then
            local up = vim.fs.dirname(path)
            while up and not uv.fs_stat(up) do
                local parent = vim.fs.dirname(up)
                if parent == up then break end
                up = parent
            end
            return up
        end
    end
end

local function relocate(result)
    local all = {}
    for _, state in pairs(states) do
        all[#all + 1] = state
    end
    for _, state in ipairs(all) do
        local target = destination(state.dir, result)
        if target and target ~= state.dir then
            for _, win in ipairs(vim.fn.win_findbuf(state.view.buf)) do
                M.open(target, { win = win })
            end
            pcall(api.nvim_buf_delete, state.view.buf, { force = true })
        end
    end
end

local function report(result, count)
    if not result.failed then
        notify(("%d change%s applied"):format(count, count == 1 and "" or "s"))
        return
    end
    local lines = {
        ("stopped at: %s"):format(fs.describe(result.failed.op)),
        result.failed.err,
        ("%d step%s done, %d never ran"):format(#result.done, #result.done == 1 and "" or "s", #result.skipped),
    }
    for _, op in ipairs(result.skipped) do
        lines[#lines + 1] = "not run: " .. fs.describe(op)
    end
    for _, p in ipairs(result.parked) do
        lines[#lines + 1] = ("%s is still at %s"):format(fs.short(p.name), fs.short(p.at))
    end
    notify(table.concat(lines, "\n"), vim.log.levels.ERROR)
end

local function apply(planned, buffers, done)
    for _, b in ipairs(buffers) do
        local buf = b.state.view.buf
        if not api.nvim_buf_is_valid(buf) or api.nvim_buf_get_changedtick(buf) ~= b.tick then
            notify("a listing changed while the question was open, so nothing was applied",
                vim.log.levels.WARN)
            done(false)
            return
        end
    end
    local before = sync.before(planned)
    local result = fs.run(planned.ops)
    sync.after(before, result)
    done(not result.failed)
    relocate(result)
    for _, state in pairs(states) do
        refresh(state, { force = true })
    end
    report(result, #planned.lines)
end

local function refuse(errors)
    notify("nothing was changed:\n" .. table.concat(errors, "\n"), vim.log.levels.ERROR)
end

local function save(view, done)
    -- (:wa reaches here once per modified listing; the first handles all)
    if saving or not states[view.buf] then
        done(false)
        return
    end
    local buffers = {}
    for _, state in ipairs(modified_states()) do
        buffers[#buffers + 1] = {
            state = state,
            dir = state.dir,
            lines = api.nvim_buf_get_lines(state.view.buf, 0, -1, false),
            shown = state.shown,
            tick = api.nvim_buf_get_changedtick(state.view.buf),
        }
    end
    if #buffers == 0 then
        done(true)
        return
    end

    local changes, errors = diff.compute({ buffers = buffers, entry = hview.entry })
    if not changes then
        refuse(errors)
        done(false)
        return
    end
    if #changes == 0 then
        done(true)
        for _, b in ipairs(buffers) do
            render(b.state, { force = true })
        end
        return
    end

    local planned, plan_errors = plan.build(changes, { protected = protected, unsaved = sync.unsaved })
    if not planned then
        refuse(plan_errors)
        done(false)
        return
    end

    saving = true
    local count = #planned.lines
    -- On the next tick: Neovim puts the window back when BufWriteCmd ends,
    -- which would take the focus straight off a float opened here.
    vim.schedule(function()
        local ok, err = pcall(malleable.confirm, {
            title = (" Apply %d change%s? "):format(count, count == 1 and "" or "s"),
            lines = planned.lines,
            on_yes = function()
                saving = false
                apply(planned, buffers, done)
            end,
            on_no = function()
                saving = false
                done(false)
            end,
        })
        if not ok then
            saving = false
            done(false)
            notify("couldn't ask before saving: " .. tostring(err), vim.log.levels.ERROR)
        end
    end)
end

-- The cursor line's entry, as long as the line still says what's on disk.
local function entry_at_cursor(state)
    local line = api.nvim_get_current_line()
    if vim.trim(line) == "" then return nil end
    local id, text = diff.parse_line(line)
    local entry = id and hview.entry(id)
    if not entry or text ~= entry.text or entry.dir ~= state.dir then
        notify("save first: this line isn't on disk yet", vim.log.levels.WARN)
        return nil
    end
    return entry
end

local function open_entry(view)
    local state = states[view.buf]
    local entry = state and entry_at_cursor(state)
    if not entry then return end
    if not uv.fs_lstat(entry.path) then
        notify(fs.short(entry.path) .. " no longer exists", vim.log.levels.WARN)
        refresh(state)
        return
    end
    if entry.opens_dir then
        M.open(entry.path)
    else
        vim.cmd("edit " .. vim.fn.fnameescape(entry.path))
    end
end

local function go_parent(view)
    local state = states[view.buf]
    if not state then return end
    local parent = vim.fs.dirname(state.dir)
    if parent and parent ~= state.dir then
        M.open(parent, { focus = vim.fs.basename(state.dir) })
    end
end

local function toggle_hidden()
    if #modified_states() > 0 then
        notify("save or discard your edits first", vim.log.levels.WARN)
        return
    end
    config.show_hidden = not config.show_hidden
    for _, state in pairs(states) do
        refresh(state)
    end
end

local function yank_path(view)
    local state = states[view.buf]
    local entry = state and entry_at_cursor(state)
    if not entry then return end
    vim.fn.setreg('"', entry.path)
    pcall(vim.fn.setreg, "+", entry.path)
    notify("copied " .. fs.short(entry.path))
end

local function reload(view)
    local state = states[view.buf]
    if not state then return end
    if not vim.bo[view.buf].modified then
        render(state)
        return
    end
    malleable.confirm({
        title = " Discard edits? ",
        lines = { "Discard your unsaved edits to " .. fs.short(state.dir) .. "?" },
        on_yes = function()
            render(state, { force = true })
        end,
    })
end

local KEYS = {
    { "<CR>", open_entry, desc = "Open the file or directory" },
    { "-", go_parent, desc = "Go up a directory" },
    { "g.", toggle_hidden, desc = "Show or hide dotfiles" },
    { "gy", yank_path, desc = "Copy the path to the clipboard" },
    { "gR", reload, desc = "Read the listing from disk" },
    { "g?", function(view) view:help() end, desc = "List these keys" },
}

--- The directory buf lists (default: the current buffer), or nil.
function M.dir(buf)
    if not buf or buf == 0 then
        buf = api.nvim_get_current_buf()
    end
    return states[buf] and states[buf].dir or nil
end

--- Shows the listing of path in opts.win (default: the current window),
--- with the cursor on the entry called opts.focus. Returns its view, or nil
--- when path isn't a directory.
function M.open(path, opts)
    opts = opts or {}
    local dir = resolve(path)
    local st = uv.fs_stat(dir)
    if not st or st.type ~= "directory" then
        notify("not a directory: " .. fs.short(dir), vim.log.levels.ERROR)
        return nil
    end

    local view = malleable.open({
        name = "harbor://" .. dir,
        filetype = "harbor",
        editable = true,
        on_write = save,
        on_reload = function(v)
            if states[v.buf] then
                render(states[v.buf], { force = true })
            end
        end,
        on_wipe = function(v)
            states[v.buf] = nil
            hview.detach(v.buf)
        end,
        keys = KEYS,
    })
    local state = states[view.buf]
    if not state then
        state = { view = view, dir = dir, shown = {} }
        states[view.buf] = state
        hview.attach(view, function()
            -- Files may have come and gone while it wasn't on screen.
            if not state.opening and not view.writing and not vim.bo[view.buf].modified then
                refresh(state)
            end
        end)
    end

    local win = opts.win or api.nvim_get_current_win()
    state.opening = true
    api.nvim_win_set_buf(win, view.buf)
    state.opening = false
    hview.set_window(win)
    if api.nvim_get_current_buf() == view.buf then
        hview.enter()
    end
    if not vim.bo[view.buf].modified then
        render(state, { focus = opts.focus, win = win })
    end
    return view
end

local function command(args)
    if args.args ~= "" then
        M.open(vim.fn.expand(args.args))
        return
    end
    local buf = api.nvim_get_current_buf()
    if states[buf] then
        M.open(states[buf].dir)
        return
    end
    local name = api.nvim_buf_get_name(buf)
    if name ~= "" and vim.bo[buf].buftype == "" then
        local parent = vim.fs.dirname(name)
        if parent and vim.fn.isdirectory(parent) == 1 then
            M.open(parent, { focus = vim.fs.basename(name) })
            return
        end
    end
    M.open(vim.fn.getcwd())
end

-- A plain buffer on a directory (:e dir, nvim .) becomes its listing,
-- unless netrw is the one opening it (:Explore).
local function take_over(buf)
    if states[buf] or not api.nvim_buf_is_valid(buf) then return end
    local name = api.nvim_buf_get_name(buf)
    if name == "" or vim.bo[buf].buftype ~= "" or vim.fn.isdirectory(name) ~= 1 then
        return
    end
    if vim.bo[buf].filetype == "netrw" or vim.b[buf].netrw_curdir
        or vim.fn.expand("<stack>"):find("netrw", 1, true) then
        return
    end
    if api.nvim_get_current_buf() ~= buf then return end
    -- The plain buffer is going, so # (<C-h>) keeps pointing where it did.
    local alternate = vim.fn.bufnr("#")
    M.open(name)
    if alternate > 0 and alternate ~= buf and api.nvim_buf_is_valid(alternate) then
        pcall(vim.fn.setreg, "#", alternate)
    end
    vim.schedule(function()
        if api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
            pcall(api.nvim_buf_delete, buf, { force = true })
        end
    end)
end

local function drop_netrw_browsing()
    -- Only directory browsing: its Network group handles scp:// and friends.
    pcall(api.nvim_del_augroup_by_name, "FileExplorer")
end

--- opts: show_hidden (default true).
function M.setup(opts)
    opts = opts or {}
    if opts.show_hidden ~= nil then
        config.show_hidden = opts.show_hidden
    end

    api.nvim_create_user_command("Harbor", command, {
        nargs = "?",
        complete = "dir",
        desc = "Open a directory as an editable listing",
    })

    local group = api.nvim_create_augroup("neo.harbor", { clear = true })
    -- Plugins load after this config, so netrw's group doesn't exist yet.
    api.nvim_create_autocmd("SourcePost", {
        group = group,
        pattern = "*netrwPlugin.vim",
        callback = drop_netrw_browsing,
    })
    drop_netrw_browsing()
    api.nvim_create_autocmd("BufEnter", {
        group = group,
        nested = true,
        callback = function(ev) take_over(ev.buf) end,
    })
    api.nvim_create_autocmd("VimEnter", {
        group = group,
        nested = true,
        callback = function() take_over(api.nvim_get_current_buf()) end,
    })
    -- A listing restored from a session, or typed as a harbor:// name.
    api.nvim_create_autocmd("BufReadCmd", {
        group = group,
        pattern = "harbor://*",
        nested = true,
        callback = function(ev)
            if states[ev.buf] then return end
            local dir = ev.match:match("^harbor://(.+)$")
            vim.schedule(function()
                if dir and api.nvim_buf_is_valid(ev.buf) and not states[ev.buf]
                    and api.nvim_get_current_buf() == ev.buf then
                    M.open(dir)
                end
            end)
        end,
    })
end

return M
