-- lua/neo/plugins/projects/store.lua
-- What the picker (<C-t>, <C-x>) and :Projects track/untrack changed about
-- the tracked set, kept on disk so it outlives the session:
--
--   { "version": 1,
--     "dirs": ["/home/me/Work"],          tracked on top of the configured set
--     "untracked": ["/home/me/Projects"] } configured entries to leave out
--
-- Paths are stored absolute. The file only holds data; init.lua decides
-- what it means. Nothing is cached: every call reads the file afresh, so
-- two Neovims see each other's changes. Writes go to a temporary file
-- renamed over the real one, so a crash can't leave half a file. A file
-- that doesn't parse is moved aside to <file>.bad rather than overwritten.

local M = {}

M.VERSION = 1

-- Where the file lives. The tests repoint it.
M.file = vim.fs.joinpath(vim.fn.stdpath("data"), "neo", "projects.json")

local windows = vim.fn.has("win32") == 1

--- path as compared with others: case-insensitively on Windows.
function M.key(path)
    return windows and path:lower() or path
end

-- The strings of a decoded list, in order; anything else is dropped.
local function strings(list)
    local out = {}
    if type(list) == "table" then
        for _, v in ipairs(list) do
            if type(v) == "string" and v ~= "" then
                out[#out + 1] = v
            end
        end
    end
    return out
end

--- The file as { dirs = {...}, untracked = {...} }, fresh lists of paths.
--- A missing file reads as an empty one. quiet (for the statusline, which
--- can't be notifying) reads a broken one as empty too, but leaves it
--- where it is for a louder read to move aside and report.
function M.read(quiet)
    local f = io.open(M.file, "rb")
    if not f then
        return { dirs = {}, untracked = {} }
    end
    local text = f:read("*a")
    f:close()
    local ok, doc = pcall(vim.json.decode, text)
    if ok and type(doc) == "table" then
        return { dirs = strings(doc.dirs), untracked = strings(doc.untracked) }
    end
    if quiet then
        return { dirs = {}, untracked = {} }
    end
    local bad = M.file .. ".bad"
    local moved = vim.uv.fs_rename(M.file, bad)
    vim.notify(("projects: %s isn't valid projects data; %s"):format(
        M.file, moved and ("moved it to " .. bad) or "couldn't move it aside"), vim.log.levels.ERROR)
    return { dirs = {}, untracked = {} }
end

--- Replaces the file with doc ({ dirs, untracked }). Returns true, or
--- false and an error.
function M.write(doc)
    vim.fn.mkdir(vim.fs.dirname(M.file), "p")
    local tmp = ("%s.%d.tmp"):format(M.file, vim.uv.os_getpid())
    local f, err = io.open(tmp, "wb")
    if not f then
        return false, err
    end
    local ok, werr = f:write(vim.json.encode({
        version = M.VERSION,
        dirs = doc.dirs or {},
        untracked = doc.untracked or {},
    }))
    f:close()
    if ok then
        ok, werr = vim.uv.fs_rename(tmp, M.file)
    end
    if not ok then
        os.remove(tmp)
        return false, werr
    end
    return true
end

--- Whether list holds path.
function M.has(list, path)
    local key = M.key(path)
    for _, p in ipairs(list) do
        if M.key(p) == key then return true end
    end
    return false
end

--- list without path, as a new list.
function M.without(list, path)
    local key = M.key(path)
    local out = {}
    for _, p in ipairs(list) do
        if M.key(p) ~= key then out[#out + 1] = p end
    end
    return out
end

return M
