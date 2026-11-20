-- lua/neo/plugins/anchor/store.lua
-- The anchor lists on disk, and the paths in them. One JSON file holds
-- every project's slots:
--
--   { "version": 1,
--     "projects": { "/home/me/Projects/neo": ["init.lua", "", "/etc/hosts"] } }
--
-- A project is keyed by its root (the working directory, resolved). A
-- slot holds a path relative to the root when the file is inside it, else
-- an absolute one; "" is an empty slot, and a list never ends in one.
--
-- Nothing is cached: every call reads the file afresh, and set() rewrites
-- only the one project it is given, so two Neovims never undo each other's
-- other projects (on the same project, the last write wins). Writes go to
-- a temporary file renamed over the real one, so a crash can't leave half
-- a file. A file that doesn't parse is moved aside to <file>.bad rather
-- than overwritten.

local M = {}

M.VERSION = 1

-- Where the lists live. setup({ file = ... }) repoints it (the tests do).
M.file = vim.fs.joinpath(vim.fn.stdpath("data"), "neo", "anchor.json")

local windows = vim.fn.has("win32") == 1

--- path as compared with others: case-insensitively on Windows.
function M.key(path)
    return windows and path:lower() or path
end

--- Whether two paths name the same file, as far as their text goes.
function M.same(a, b)
    return M.key(a) == M.key(b)
end

function M.is_absolute(path)
    return path:match("^/") ~= nil or path:match("^%a:/") ~= nil
end

--- path (absolute) normalized, with symlinks resolved where it exists, so
--- a symlinked ~/Projects or macOS's /var -> /private/var give one name.
function M.real(path)
    path = vim.fs.normalize(path)
    local real = vim.uv.fs_realpath(path)
    return real and vim.fs.normalize(real) or path
end

--- The current project's root: this window's working directory, so :lcd
--- and :tcd count.
function M.root()
    return M.real(vim.fn.getcwd())
end

--- buf's file as an absolute, resolved path, or nil when it isn't a file:
--- a special buffer (netrw, terminal, help, scratch), an unnamed one, or
--- a directory.
function M.file_of(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.bo[buf].buftype ~= "" or name == "" or vim.fn.isdirectory(name) == 1 then
        return nil
    end
    return M.real(name)
end

--- How the file at abs (absolute, resolved) is stored for root: relative
--- when it is inside root, else absolute.
function M.to_stored(abs, root)
    local prefix = root:sub(-1) == "/" and root or root .. "/"
    if #abs > #prefix and M.same(abs:sub(1, #prefix), prefix) then
        return abs:sub(#prefix + 1)
    end
    return abs
end

--- The absolute path of a slot, or of a path typed into the menu ("~/x",
--- "$HOME/x" and "./x" work there too).
function M.to_abs(path, root)
    path = vim.fs.normalize(path)
    if M.is_absolute(path) then
        return path
    end
    return vim.fs.normalize(vim.fs.joinpath(root, path))
end

--- A path as it would be stored for root, whatever form it was given in.
function M.canonical(path, root)
    return M.to_stored(M.real(M.to_abs(path, root)), root)
end

local function empty()
    return { version = M.VERSION, projects = {} }
end

--- The decoded file: { version, projects = { [root] = slots } }. A
--- missing file reads as an empty one.
function M.read()
    local f = io.open(M.file, "rb")
    if not f then
        return empty()
    end
    local text = f:read("*a")
    f:close()
    local ok, doc = pcall(vim.json.decode, text)
    if ok and type(doc) == "table" and type(doc.projects) == "table" then
        return doc
    end
    local bad = M.file .. ".bad"
    local moved = vim.uv.fs_rename(M.file, bad)
    vim.notify(("anchor: %s isn't valid anchor data; %s"):format(
        M.file, moved and ("moved it to " .. bad) or "couldn't move it aside"), vim.log.levels.ERROR)
    return empty()
end

--- root's slots, as a fresh list ("" is an empty slot). doc is a read()
--- result to use instead of reading the file again.
function M.get(root, doc)
    local raw = (doc or M.read()).projects[root]
    local slots = {}
    if type(raw) == "table" then
        for i, slot in ipairs(raw) do
            slots[i] = type(slot) == "string" and slot or ""
        end
    end
    return slots
end

local function write(doc)
    vim.fn.mkdir(vim.fs.dirname(M.file), "p")
    local tmp = ("%s.%d.tmp"):format(M.file, vim.uv.os_getpid())
    local f, err = io.open(tmp, "wb")
    if not f then
        return false, err
    end
    local ok, werr = f:write(vim.json.encode(doc))
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

--- Replaces root's slots on disk (trailing empty ones dropped; none at all
--- drops the project), leaving every other project as the file has it
--- now. Returns true, or false and an error.
function M.set(root, slots)
    local doc = M.read()
    slots = vim.deepcopy(slots)
    while #slots > 0 and slots[#slots] == "" do
        slots[#slots] = nil
    end
    doc.version = M.VERSION
    doc.projects[root] = #slots > 0 and slots or nil
    if next(doc.projects) == nil then
        -- encode as {} rather than []
        doc.projects = vim.empty_dict()
    end
    return write(doc)
end

return M
