-- lua/neo/plugins/harbor/plan.lua
-- Checks a list of changes (see diff.lua) against the disk and orders it.
-- Nothing here writes: either every check passes and there's a plan to run,
-- or the whole save is refused with the reasons.
--
-- A plan runs in this order: missing directories, copies (their sources are
-- still in place), moves, new files, deletes. Deletes come last so a failure
-- earlier has destroyed nothing, and so something moved out of a directory
-- survives that directory being deleted.
--
-- Only a move can take a name another move frees in the same save. Swaps
-- and longer cycles go through a temporary name.
local fs = require("neo.plugins.harbor.fs")

local M = {}

local uv = vim.uv
local short = fs.short

local function listed(dir, name)
    local handle = uv.fs_scandir(dir)
    while handle do
        local found = uv.fs_scandir_next(handle)
        if not found then return false end
        if found == name then return true end
    end
    return false
end

--- Whether b is another spelling of a's directory entry, as on a
--- case-insensitive disk. Two hard links share an inode too, so b's exact
--- name mustn't be listed in its own right.
function M.same_entry(a, b)
    if a == b then return true end
    local dir = vim.fs.dirname(a)
    if dir ~= vim.fs.dirname(b) then return false end
    local sa, sb = uv.fs_lstat(a), uv.fs_lstat(b)
    if not sa or not sb or sa.dev ~= sb.dev then return false end
    if sa.ino == 0 or sb.ino == 0 then
        return a:lower() == b:lower()
    end
    return sa.ino == sb.ino and not listed(dir, vim.fs.basename(b))
end

local function changed_on_disk(entry, st)
    if st.type ~= entry.type then return true end
    if entry.ino == 0 or st.ino == 0 then return false end
    return st.ino ~= entry.ino or st.dev ~= entry.dev
end

local function touches(change, dir)
    return (change.kind ~= "copy" and change.from and fs.below(change.from, dir))
        or (change.to and fs.below(change.to, dir))
end

-- The directories missing above path, shallowest first, or nil and why
-- path can't go there.
local function missing_above(path)
    local missing = {}
    local p = vim.fs.dirname(path)
    while p do
        local st = uv.fs_stat(p)
        if st then
            if st.type ~= "directory" then
                return nil, short(p) .. " isn't a directory"
            end
            return missing
        end
        table.insert(missing, 1, p)
        local up = vim.fs.dirname(p)
        if up == p then break end
        p = up
    end
    return missing
end

local function device_above(path)
    local p = vim.fs.dirname(path)
    while p do
        local st = uv.fs_stat(p)
        if st then return st.dev end
        local up = vim.fs.dirname(p)
        if up == p then break end
        p = up
    end
end

local function temp_name(path, n)
    while true do
        local name = ("%s.harbor-%d-%d"):format(path, uv.os_getpid(), n)
        if not uv.fs_lstat(name) then return name end
        n = n + 1
    end
end

-- The moves in an order where each target is free when its turn comes,
-- with cycles broken by parking one source under a temporary name.
local function order_moves(moves)
    local pending, out, parked = {}, {}, 0
    for _, m in ipairs(moves) do
        pending[#pending + 1] = { from = m.from, to = m.to, case_only = m.case_only }
    end
    local function occupies(other, target)
        return not other.origin and M.same_entry(other.from, target)
    end
    while #pending > 0 do
        local ready
        for i, m in ipairs(pending) do
            local blocked = false
            for j, other in ipairs(pending) do
                if i ~= j and occupies(other, m.to) then
                    blocked = true
                    break
                end
            end
            if not blocked then
                ready = i
                break
            end
        end
        if ready then
            local m = table.remove(pending, ready)
            out[#out + 1] = { op = "move", from = m.from, to = m.to, origin = m.origin, case_only = m.case_only }
        else
            local m = pending[1]
            parked = parked + 1
            local temp = temp_name(m.from, parked)
            out[#out + 1] = { op = "move", from = m.from, to = temp, temp = true }
            m.origin, m.from = m.from, temp
        end
    end
    return out
end

local function count_items(measured)
    local n = measured.files + measured.dirs - 1
    return (" (%d item%s inside)"):format(n, n == 1 and "" or "s")
end

local function summary(change)
    local slash = change.is_dir and "/" or ""
    if change.kind == "create" then
        return ("CREATE  %s%s"):format(short(change.to), slash)
    elseif change.kind == "delete" then
        local items = change.measured and count_items(change.measured) or ""
        return ("DELETE  %s%s%s"):format(short(change.from), slash, items)
    elseif change.kind == "copy" then
        local items = change.is_dir and change.measured and count_items(change.measured) or ""
        return ("COPY    %s%s -> %s%s%s"):format(short(change.from), slash, short(change.to), slash, items)
    end
    if vim.fs.dirname(change.from) == vim.fs.dirname(change.to) then
        return ("RENAME  %s%s -> %s%s"):format(short(change.from), slash, vim.fs.basename(change.to), slash)
    end
    return ("MOVE    %s%s -> %s%s"):format(short(change.from), slash, short(change.to), slash)
end

--- opts: protected = fn(path) -> why it can't move or go, or nil;
--- unsaved = fn(path) -> whether an open buffer at or under path has unsaved
--- changes. Returns { ops, lines, moves, deletes }, or nil and the errors.
function M.build(changes, opts)
    opts = opts or {}
    local errors = {}
    local function fail(message, ...)
        errors[#errors + 1] = message:format(...)
    end

    local by = { create = {}, move = {}, copy = {}, delete = {} }
    for _, change in ipairs(changes) do
        table.insert(by[change.kind], change)
    end

    for _, change in ipairs(changes) do
        if change.from then
            local st = uv.fs_lstat(change.from)
            if not st then
                fail("%s no longer exists (gR refreshes the listing)", short(change.from))
            elseif change.entry and changed_on_disk(change.entry, st) then
                fail("%s changed on disk (gR refreshes the listing)", short(change.from))
            end
        end
    end
    if #errors > 0 then return nil, errors end

    for _, group in ipairs({ by.move, by.delete }) do
        for _, change in ipairs(group) do
            local why = opts.protected and opts.protected(change.from)
            if why then
                fail("won't %s %s: %s", change.kind, short(change.from), why)
            end
            if opts.unsaved and opts.unsaved(change.from) then
                fail("%s has unsaved changes in an open buffer", short(change.from))
            end
        end
    end

    for _, group in ipairs({ by.move, by.copy }) do
        for _, change in ipairs(group) do
            if change.is_dir and fs.below(change.to, change.from) then
                fail("can't put %s inside itself", short(change.from))
            end
        end
    end

    for _, m in ipairs(by.move) do
        if m.is_dir then
            for _, other in ipairs(changes) do
                if other ~= m and (touches(other, m.from) or touches(other, m.to)) then
                    fail("%s is moving, so change what's inside it in a separate save", short(m.from))
                    break
                end
            end
        end
    end

    local deletes = {}
    for _, d in ipairs(by.delete) do
        local nested = false
        for _, other in ipairs(by.delete) do
            if other ~= d and other.is_dir and fs.below(d.from, other.from) then
                nested = true
            end
        end
        if not nested then
            deletes[#deletes + 1] = d
        end
        for _, other in ipairs(changes) do
            if other.to and fs.below(other.to, d.from) then
                fail("%s is being deleted, so nothing can go inside it", short(d.from))
                break
            end
        end
    end

    for _, group in ipairs({ by.create, by.copy }) do
        for _, change in ipairs(group) do
            if uv.fs_lstat(change.to) then
                fail("%s already exists", short(change.to))
            end
        end
    end
    for _, m in ipairs(by.move) do
        if uv.fs_lstat(m.to) then
            if M.same_entry(m.from, m.to) then
                m.case_only = true
            else
                local freed = false
                for _, other in ipairs(by.move) do
                    if other ~= m and M.same_entry(other.from, m.to) then
                        freed = true
                        break
                    end
                end
                if not freed then
                    fail("%s already exists", short(m.to))
                end
            end
        end
    end

    local mkdirs, wanted = {}, {}
    local function want(path)
        local key = fs.key(path)
        if not wanted[key] then
            wanted[key] = true
            mkdirs[#mkdirs + 1] = path
        end
    end
    for _, change in ipairs(changes) do
        if change.to then
            local missing, why = missing_above(change.to)
            if not missing then
                fail("can't put %s there: %s", short(change.to), why)
            else
                for _, p in ipairs(missing) do want(p) end
            end
            if change.kind == "create" and change.is_dir then
                want(change.to)
            end
        end
    end
    for _, change in ipairs(changes) do
        if change.to and not (change.kind == "create" and change.is_dir)
            and wanted[fs.key(change.to)] then
            fail("%s can't be both a file and a directory", short(change.to))
        end
    end
    table.sort(mkdirs, function(a, b)
        if #a ~= #b then return #a < #b end
        return a < b
    end)

    for _, c in ipairs(by.copy) do
        c.measured = fs.measure(c.from)
        if c.measured.special then
            fail("can't copy %s: it's a FIFO, socket, or device", short(c.measured.special))
        end
    end
    for _, m in ipairs(by.move) do
        local st = uv.fs_lstat(m.from)
        if st and device_above(m.to) ~= st.dev then
            local measured = fs.measure(m.from)
            if measured.special then
                fail("can't move %s to another drive: it's a FIFO, socket, or device",
                    short(measured.special))
            end
        end
    end
    for _, d in ipairs(deletes) do
        if d.is_dir then
            d.measured = fs.measure(d.from)
        end
    end

    if #errors > 0 then return nil, errors end

    local ops = {}
    for _, path in ipairs(mkdirs) do
        ops[#ops + 1] = { op = "mkdir", to = path }
    end
    for _, c in ipairs(by.copy) do
        ops[#ops + 1] = { op = "copy", from = c.from, to = c.to }
    end
    vim.list_extend(ops, order_moves(by.move))
    for _, c in ipairs(by.create) do
        if not c.is_dir then
            ops[#ops + 1] = { op = "touch", to = c.to }
        end
    end
    for _, d in ipairs(deletes) do
        ops[#ops + 1] = { op = "delete", from = d.from }
    end

    -- Deletes first: they're what you'd least want to miss.
    local lines = {}
    for _, group in ipairs({ deletes, by.move, by.copy, by.create }) do
        for _, change in ipairs(group) do
            lines[#lines + 1] = summary(change)
        end
    end
    return { ops = ops, lines = lines, moves = by.move, deletes = deletes }
end

return M
