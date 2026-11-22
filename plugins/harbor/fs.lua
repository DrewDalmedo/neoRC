-- lua/neo/plugins/harbor/fs.lua
-- Harbor's disk layer: path helpers, and running the operations plan.lua
-- ordered. Everything goes through vim.uv, so it behaves the same on every
-- platform and never starts a shell.
--
-- M.run stops at the first failure. Deletes come last in a plan, so a
-- failure before them has destroyed nothing. Names parked during a swap
-- are put back when they can be, and reported when they can't.
local M = {}

local uv = vim.uv

M.windows = vim.fn.has("win32") == 1

--- path as compared with others: case-insensitively on Windows.
function M.key(path, windows)
    if windows == nil then windows = M.windows end
    return windows and path:lower() or path
end

-- Not vim.fs.joinpath + normalize: normalize expands $VARS, and a file can
-- be called $HOME.
function M.join(dir, name)
    if dir:sub(-1) == "/" then
        return dir .. name
    end
    return dir .. "/" .. name
end

--- Whether path is strictly inside dir.
function M.below(path, dir, windows)
    local prefix, key = M.key(dir, windows), M.key(path, windows)
    if prefix:sub(-1) ~= "/" then
        prefix = prefix .. "/"
    end
    return #key > #prefix and key:sub(1, #prefix) == prefix
end

--- Whether path is dir or inside it.
function M.within(path, dir, windows)
    return M.key(path, windows) == M.key(dir, windows) or M.below(path, dir, windows)
end

function M.short(path)
    return vim.fn.fnamemodify(path, ":~")
end

--- path with the directories above it resolved, but not path itself: a
--- symlink keeps its own name, so moving one never counts as moving what
--- it points to.
function M.real_parent(path)
    local parent = vim.fs.dirname(path)
    if not parent or parent == path then
        return path
    end
    local real = uv.fs_realpath(parent)
    if not real then
        return path
    end
    return M.join(vim.fs.normalize(real, { expand_env = false }), vim.fs.basename(path))
end

--- What's at path, without following links: { files, dirs, bytes, special },
--- special being the first FIFO, socket, or device found.
function M.measure(path)
    local out = { files = 0, dirs = 0, bytes = 0 }
    local function walk(p)
        local st = uv.fs_lstat(p)
        if not st then return end
        if st.type == "directory" then
            out.dirs = out.dirs + 1
            local handle = uv.fs_scandir(p)
            while handle do
                local name = uv.fs_scandir_next(handle)
                if not name then break end
                walk(M.join(p, name))
            end
        elseif st.type == "file" then
            out.files = out.files + 1
            out.bytes = out.bytes + st.size
        elseif st.type == "link" then
            out.files = out.files + 1
        else
            out.special = out.special or p
        end
    end
    walk(path)
    return out
end

local function remove(path)
    local st = uv.fs_lstat(path)
    if not st then return true end
    -- (a link is removed itself, never what it points to)
    local flags = st.type == "directory" and "rf" or ""
    if vim.fn.delete(path, flags) ~= 0 or uv.fs_lstat(path) then
        return nil, "couldn't delete all of " .. M.short(path)
    end
    return true
end

local function copy_tree(from, to)
    local st, err = uv.fs_lstat(from)
    if not st then return nil, err end
    if st.type == "link" then
        local target, read_err = uv.fs_readlink(from)
        if not target then return nil, read_err end
        local pointed = uv.fs_stat(from)
        return uv.fs_symlink(target, to, { dir = pointed ~= nil and pointed.type == "directory" })
    elseif st.type == "file" then
        return uv.fs_copyfile(from, to, { excl = true })
    elseif st.type ~= "directory" then
        return nil, ("can't copy a %s: %s"):format(st.type, M.short(from))
    end
    -- Writable while it fills up, so a read-only directory can be copied.
    local ok, mk_err = uv.fs_mkdir(to, 448)
    if not ok then return nil, mk_err end
    local handle, scan_err = uv.fs_scandir(from)
    if not handle then return nil, scan_err end
    while true do
        local name = uv.fs_scandir_next(handle)
        if not name then break end
        local copied, copy_err = copy_tree(M.join(from, name), M.join(to, name))
        if not copied then return nil, copy_err end
    end
    uv.fs_chmod(to, st.mode % 512)
    return true
end

local function copy(from, to)
    local ok, err = copy_tree(from, to)
    if ok then return true end
    remove(to)
    return nil, err
end

local function move(op)
    -- rename replaces what's there without a word.
    if not op.case_only and uv.fs_lstat(op.to) then
        return nil, "already exists: " .. M.short(op.to)
    end
    local ok, err, code = uv.fs_rename(op.from, op.to)
    if ok then return true end
    if code ~= "EXDEV" then return nil, err end

    -- Another drive: the source goes only once the copy has checked out.
    local before = M.measure(op.from)
    local copied, copy_err = copy(op.from, op.to)
    if not copied then return nil, copy_err end
    local after = M.measure(op.to)
    if before.files ~= after.files or before.dirs ~= after.dirs or before.bytes ~= after.bytes then
        remove(op.to)
        return nil, "the copy of " .. M.short(op.from) .. " didn't match it"
    end
    return remove(op.from)
end

local function mkdir(path)
    local ok, err = uv.fs_mkdir(path, 493)
    if ok then return true end
    local st = uv.fs_stat(path)
    if st and st.type == "directory" then return true end
    return nil, err
end

local function touch(path)
    local fd, err = uv.fs_open(path, "wx", 420)
    if not fd then return nil, err end
    uv.fs_close(fd)
    return true
end

local function step(op)
    if op.op == "mkdir" then return mkdir(op.to) end
    if op.op == "touch" then return touch(op.to) end
    if op.op == "copy" then return copy(op.from, op.to) end
    if op.op == "move" then return move(op) end
    if op.op == "delete" then return remove(op.from) end
    return nil, "unknown operation: " .. tostring(op.op)
end

--- How an operation reads in a report.
function M.describe(op)
    if op.from and op.to then
        return ("%s %s -> %s"):format(op.op, M.short(op.origin or op.from), M.short(op.to))
    end
    return ("%s %s"):format(op.op, M.short(op.from or op.to))
end

--- Runs ops in order, stopping at the first failure. Returns
--- { done, failed = { op, err }, skipped, moved = { { from, to } },
---   deleted = { path }, parked = { { at, name } } }; parked lists what
--- couldn't be put back after a failed swap.
function M.run(ops)
    local out = { done = {}, skipped = {}, moved = {}, deleted = {}, parked = {} }
    local temps = {}
    for i, op in ipairs(ops) do
        local ok, err = step(op)
        if not ok then
            out.failed = { op = op, err = tostring(err) }
            for j = i + 1, #ops do
                if not ops[j].temp then
                    out.skipped[#out.skipped + 1] = ops[j]
                end
            end
            break
        end
        if op.temp then
            temps[op.to] = op.from
        else
            out.done[#out.done + 1] = op
            if op.op == "move" then
                temps[op.from] = nil
                out.moved[#out.moved + 1] = { from = op.origin or op.from, to = op.to }
            elseif op.op == "delete" then
                out.deleted[#out.deleted + 1] = op.from
            end
        end
    end
    for at, name in pairs(temps) do
        if uv.fs_lstat(name) or not uv.fs_rename(at, name) then
            out.parked[#out.parked + 1] = { at = at, name = name }
        end
    end
    return out
end

return M
