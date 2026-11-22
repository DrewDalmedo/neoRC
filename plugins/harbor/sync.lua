-- lua/neo/plugins/harbor/sync.lua
-- Keeps the rest of the editor right when files move: working directories,
-- open buffers, and anchor slots.
--
-- Working directories move off a path before it's renamed or deleted
-- (Windows can't do either to a directory in use), and follow it afterward.
-- A save is refused while a buffer it would move or delete has unsaved
-- changes (see plan.lua), so every buffer handled here matches the disk.
local fs = require("neo.plugins.harbor.fs")

local M = {}

local api = vim.api
local uv = vim.uv

local function norm(path)
    return vim.fs.normalize(path, { expand_env = false })
end

--- Whether an open file at or under path has unsaved changes.
function M.unsaved(path)
    local real = fs.real_parent(path)
    for _, buf in ipairs(api.nvim_list_bufs()) do
        local name = api.nvim_buf_get_name(buf)
        if name ~= "" and vim.bo[buf].buftype == "" and vim.bo[buf].modified then
            name = norm(name)
            if fs.within(name, path) or fs.within(name, real) then
                return true
            end
        end
    end
    return false
end

-- Every working directory in use: the global one, and each tab's and
-- window's own.
local function scopes()
    local out = { { kind = "global", dir = vim.fn.getcwd(-1, -1) } }
    for _, tab in ipairs(api.nvim_list_tabpages()) do
        local tabnr = api.nvim_tabpage_get_number(tab)
        if vim.fn.haslocaldir(-1, tabnr) == 1 then
            out[#out + 1] = { kind = "tab", tab = tab, dir = vim.fn.getcwd(-1, tabnr) }
        end
        for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
            local winnr = vim.fn.win_id2tabwin(win)[2]
            if vim.fn.haslocaldir(winnr, tabnr) == 1 then
                out[#out + 1] = { kind = "win", win = win, dir = vim.fn.getcwd(winnr, tabnr) }
            end
        end
    end
    return out
end

local function set_scope(scope, dir)
    local escaped = vim.fn.fnameescape(dir)
    if scope.kind == "win" then
        if api.nvim_win_is_valid(scope.win) then
            api.nvim_win_call(scope.win, function()
                vim.cmd("silent lcd " .. escaped)
            end)
        end
    elseif scope.kind == "tab" then
        if api.nvim_tabpage_is_valid(scope.tab) then
            api.nvim_win_call(api.nvim_tabpage_get_win(scope.tab), function()
                vim.cmd("silent tcd " .. escaped)
            end)
        end
    else
        -- :cd also clears the current window's and tab's own directories.
        local lcd = vim.fn.haslocaldir() == 1 and vim.fn.getcwd() or nil
        local tcd = vim.fn.haslocaldir(-1, 0) == 1 and vim.fn.getcwd(-1, 0) or nil
        vim.cmd("silent cd " .. escaped)
        if tcd then vim.cmd("silent tcd " .. vim.fn.fnameescape(tcd)) end
        if lcd then vim.cmd("silent lcd " .. vim.fn.fnameescape(lcd)) end
    end
end

--- Call before running planned. Returns what M.after needs.
function M.before(planned)
    local roots, forms = {}, {}
    for _, m in ipairs(planned.moves) do
        forms[m.from] = fs.real_parent(m.from)
        roots[#roots + 1] = { from = m.from, real = forms[m.from], moves = true }
    end
    for _, d in ipairs(planned.deletes) do
        forms[d.from] = fs.real_parent(d.from)
        roots[#roots + 1] = { from = d.from, real = forms[d.from] }
    end

    local parked = {}
    for _, scope in ipairs(scopes()) do
        local dir = norm(scope.dir)
        local outer, moved
        for _, root in ipairs(roots) do
            local base = (fs.within(dir, root.real) and root.real)
                or (fs.within(dir, root.from) and root.from)
            if base then
                if not outer or #root.real < #outer.real then
                    outer = root
                end
                if root.moves and (not moved or #base > #moved.base) then
                    moved = { from = root.from, base = base }
                end
            end
        end
        if outer then
            parked[#parked + 1] = { scope = scope, dir = dir, moved = moved }
            set_scope(scope, vim.fs.dirname(outer.real))
        end
    end
    return { parked = parked, forms = forms }
end

local function mapped(name, from, to)
    if name == from then return to end
    if fs.below(name, from) then
        return to .. name:sub(#from + 1)
    end
end

local function set_name(buf, name)
    local old = api.nvim_buf_get_name(buf)
    local ok, err = pcall(api.nvim_buf_set_name, buf, name)
    if not ok then
        return false, err
    end
    -- Neovim keeps the old name around as an unlisted buffer.
    for _, other in ipairs(api.nvim_list_bufs()) do
        if other ~= buf and api.nvim_buf_get_name(other) == old
            and not api.nvim_buf_is_loaded(other) then
            pcall(api.nvim_buf_delete, other, { force = true })
        end
    end
    return true
end

-- moves: { { from, real_from, to, real_to } }. In two steps, so buffers
-- swapping names (or changing only their case) never collide.
local function rename_buffers(moves)
    local pending = {}
    for _, buf in ipairs(api.nvim_list_bufs()) do
        local name = api.nvim_buf_get_name(buf)
        if name ~= "" and vim.bo[buf].buftype == "" then
            name = norm(name)
            for _, m in ipairs(moves) do
                local new = mapped(name, m.from, m.to) or mapped(name, m.real_from, m.real_to)
                if new then
                    pending[#pending + 1] = { buf = buf, new = new }
                    break
                end
            end
        end
    end
    for i, p in ipairs(pending) do
        set_name(p.buf, ("%s.harbor-rename-%d-%d"):format(p.new, uv.os_getpid(), i))
    end
    for _, p in ipairs(pending) do
        local ok, err = set_name(p.buf, p.new)
        if not ok then
            vim.notify(("harbor: couldn't rename the buffer for %s: %s"):format(fs.short(p.new), tostring(err)),
                vim.log.levels.WARN)
        elseif api.nvim_buf_is_loaded(p.buf) and not vim.bo[p.buf].modified then
            -- Reading it back, or the next :w is E13 ("file exists").
            pcall(api.nvim_buf_call, p.buf, function()
                vim.cmd("silent keepalt edit")
            end)
        end
    end
end

local function wipe_buffers(path, real)
    for _, buf in ipairs(api.nvim_list_bufs()) do
        local name = api.nvim_buf_get_name(buf)
        if name ~= "" and vim.bo[buf].buftype == "" then
            name = norm(name)
            if (fs.within(name, path) or fs.within(name, real)) and not uv.fs_lstat(name) then
                for _, win in ipairs(vim.fn.win_findbuf(buf)) do
                    pcall(api.nvim_win_call, win, function()
                        vim.cmd("silent keepalt enew")
                    end)
                end
                pcall(api.nvim_buf_delete, buf, { force = true })
            end
        end
    end
end

--- Call after running, with M.before's result and fs.run's.
function M.after(state, result)
    local moved_to, reals = {}, {}
    for _, m in ipairs(result.moved) do
        moved_to[m.from] = m.to
        reals[m.from] = fs.real_parent(m.to)
    end

    for _, p in ipairs(state.parked) do
        local target = p.dir
        if p.moved and moved_to[p.moved.from] then
            target = reals[p.moved.from] .. p.dir:sub(#p.moved.base + 1)
        end
        local st = uv.fs_stat(target)
        if st and st.type == "directory" then
            set_scope(p.scope, target)
        end
    end

    local moves = {}
    for _, m in ipairs(result.moved) do
        moves[#moves + 1] = {
            from = m.from,
            real_from = state.forms[m.from] or m.from,
            to = m.to,
            real_to = reals[m.from],
        }
    end
    rename_buffers(moves)

    -- Through a parked name, so a swap doesn't merge the two files' slots.
    local ok_store, store = pcall(require, "neo.plugins.anchor.store")
    if ok_store then
        local function follow(old, new)
            local saved, err = store.rename(old, new)
            if not saved then
                vim.notify("harbor: couldn't update anchor slots: " .. tostring(err), vim.log.levels.WARN)
            end
        end
        for i, m in ipairs(moves) do
            m.parked = ("%s.harbor-slot-%d-%d"):format(m.real_to, uv.os_getpid(), i)
            follow(m.real_from, m.parked)
        end
        for _, m in ipairs(moves) do
            follow(m.parked, m.real_to)
        end
    end

    for _, path in ipairs(result.deleted) do
        wipe_buffers(path, state.forms[path] or path)
    end
    pcall(vim.cmd, "redrawstatus!")
end

return M
