-- lua/neo/plugins/harbor/view.lua
-- What a listing looks like: its entries and their ids, the lines they
-- render to, the concealed ids, and keeping the cursor and edits off them.
--
-- An id stays with a path for as long as the same file is there, so a line
-- yanked before a refresh still means what it did.
--
-- 'clipboard' is emptied while a listing is current. With unnamedplus, a
-- plain yy would put the hidden ids on the system clipboard. Yanks still
-- work between listings; gy copies a path out.
local diff = require("neo.plugins.harbor.diff")
local fs = require("neo.plugins.harbor.fs")

local M = {}

local api = vim.api
local uv = vim.uv

local NS = api.nvim_create_namespace("neo.harbor")

local registry, by_path, last_id = {}, {}, 0
local live = {}
local saved_clipboard = nil

--- The entry an id stands for.
function M.entry(id)
    return registry[id]
end

local function identify(dir, name, st)
    local path = fs.join(dir, name)
    local entry = registry[by_path[path]]
    if not (entry and entry.type == st.type and entry.ino == st.ino and entry.dev == st.dev) then
        last_id = last_id + 1
        local shown = diff.display(name)
        entry = {
            id = last_id,
            path = path,
            dir = dir,
            name = name,
            type = st.type,
            ino = st.ino,
            dev = st.dev,
            escaped = shown ~= name,
            text = shown .. (st.type == "directory" and "/" or ""),
        }
        registry[last_id] = entry
        by_path[path] = last_id
    end
    entry.opens_dir = st.type == "directory"
    if st.type == "link" then
        entry.target = uv.fs_readlink(path)
        local pointed = uv.fs_stat(path)
        entry.opens_dir = pointed ~= nil and pointed.type == "directory"
    end
    return entry
end

--- dir's entries, directories first, then by name ignoring case. Returns
--- nil and an error when it can't be read.
function M.scan(dir, show_hidden)
    local handle, err = uv.fs_scandir(dir)
    if not handle then
        return nil, err
    end
    local entries = {}
    while true do
        local name = uv.fs_scandir_next(handle)
        if not name then break end
        if show_hidden or name:sub(1, 1) ~= "." then
            local st = uv.fs_lstat(fs.join(dir, name))
            if st then
                entries[#entries + 1] = identify(dir, name, st)
            end
        end
    end
    table.sort(entries, function(a, b)
        if a.opens_dir ~= b.opens_dir then
            return a.opens_dir
        end
        local la, lb = a.name:lower(), b.name:lower()
        if la ~= lb then
            return la < lb
        end
        return a.name < b.name
    end)
    return entries
end

function M.line(entry)
    return ("/%d %s"):format(entry.id, entry.text)
end

--- The lines for entries (a buffer always has one).
function M.lines(entries)
    local lines = {}
    for i, entry in ipairs(entries) do
        lines[i] = M.line(entry)
    end
    if #lines == 0 then
        lines[1] = ""
    end
    return lines
end

--- Byte column where the name starts: past the id, or 0 without one.
function M.name_col(line)
    local _, stop = line:find("^/%d+ ")
    return stop or 0
end

local function mark(buf, row, col, opts)
    opts.ephemeral = true
    pcall(api.nvim_buf_set_extmark, buf, NS, row, col, opts)
end

-- Drawn from the text on every redraw, so pasted and edited lines are
-- right without anything having to keep up with them.
local function decorate(buf, row)
    local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    if not line then return end
    local id, text = diff.parse_line(line)
    if not id then return end
    local start = #line - #text
    mark(buf, row, 0, { end_col = start, conceal = "" })
    local entry = registry[id]
    local group = text:sub(-1) == "/" and "Directory"
        or (entry and entry.type == "link" and "Special")
        or nil
    if group and #text > 0 then
        mark(buf, row, start, { end_col = #line, hl_group = group })
    end
    if entry and entry.target and text == entry.text then
        mark(buf, row, 0, {
            virt_text = { { "-> " .. entry.target, "Comment" } },
            virt_text_pos = "eol",
        })
    end
end

api.nvim_set_decoration_provider(NS, {
    on_win = function(_, _, buf)
        return live[buf] == true
    end,
    on_line = function(_, _, buf, row)
        decorate(buf, row)
    end,
})

--- Keeps win's cursor off the id on its line.
function M.clamp(win)
    if not api.nvim_win_is_valid(win) then return end
    local pos = api.nvim_win_get_cursor(win)
    local buf = api.nvim_win_get_buf(win)
    local line = api.nvim_buf_get_lines(buf, pos[1] - 1, pos[1], false)[1] or ""
    local col = M.name_col(line)
    if pos[2] < col then
        pcall(api.nvim_win_set_cursor, win, { pos[1], col })
    end
end

local function to_name()
    local pos = api.nvim_win_get_cursor(0)
    local col = M.name_col(api.nvim_get_current_line())
    pcall(api.nvim_win_set_cursor, 0, { pos[1], col })
end

-- ("i": ahead of what's already typed, or a macro's text would run first)
local function feed(keys)
    api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "ni", false)
end

-- How far insert mode may delete back: the bytes after the id, or nil on
-- a line without one.
local function room()
    local line = api.nvim_get_current_line()
    local col = M.name_col(line)
    if col == 0 then return nil end
    return api.nvim_win_get_cursor(0)[2] - col, line, col
end

local function protect(buf)
    local opts = { buffer = buf, silent = true }
    for _, lhs in ipairs({ "0", "^" }) do
        vim.keymap.set({ "n", "x", "o" }, lhs, to_name, opts)
    end
    vim.keymap.set("n", "I", function()
        to_name()
        vim.cmd("startinsert")
    end, opts)
    for _, lhs in ipairs({ "cc", "S" }) do
        vim.keymap.set("n", lhs, function()
            if vim.v.count > 1 then
                feed(vim.v.count .. "cc")
                return
            end
            to_name()
            feed("C")
        end, opts)
    end
    local expr = { buffer = buf, silent = true, expr = true, replace_keycodes = true }
    for _, lhs in ipairs({ "<BS>", "<C-h>", "<C-w>" }) do
        vim.keymap.set("i", lhs, function()
            local left = room()
            if left and left <= 0 then return "" end
            return lhs
        end, expr)
    end
    vim.keymap.set("i", "<C-u>", function()
        local left, line, col = room()
        if not left then return "<C-u>" end
        if left <= 0 then return "" end
        local typed = line:sub(col + 1, col + left)
        return ("<BS>"):rep(vim.fn.strchars(typed))
    end, expr)
end

--- Sets the options a listing needs in win, for this buffer only.
function M.set_window(win)
    for name, value in pairs({ conceallevel = 3, concealcursor = "nvic", wrap = false }) do
        api.nvim_set_option_value(name, value, { scope = "local", win = win })
    end
end

--- Call whenever a listing becomes current.
function M.enter()
    if saved_clipboard == nil then
        saved_clipboard = vim.o.clipboard
    end
    vim.o.clipboard = ""
end

--- Call when a listing stops being current.
function M.leave()
    if saved_clipboard ~= nil then
        vim.o.clipboard = saved_clipboard
        saved_clipboard = nil
    end
end

--- Sets up a new view's buffer. on_enter runs each time it is entered.
function M.attach(view, on_enter)
    local buf = view.buf
    live[buf] = true
    protect(buf)
    api.nvim_create_autocmd("BufEnter", {
        group = view.group,
        buffer = buf,
        callback = function()
            M.enter()
            on_enter()
        end,
    })
    api.nvim_create_autocmd("BufLeave", { group = view.group, buffer = buf, callback = M.leave })
    api.nvim_create_autocmd("BufWinEnter", {
        group = view.group,
        buffer = buf,
        callback = function()
            M.set_window(api.nvim_get_current_win())
        end,
    })
    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = view.group,
        buffer = buf,
        callback = function()
            M.clamp(api.nvim_get_current_win())
        end,
    })
end

--- The buffer is gone.
function M.detach(buf)
    live[buf] = nil
end

return M
