-- lua/neo/plugins/anchor/init.lua
-- Anchor: a few files per project, each in a numbered slot you jump to
-- with one key. A simplified harpoon: one list per project, no extensions,
-- no terminal or tmux navigation.
--
-- A project is the working directory (this window's, so :lcd and :tcd
-- count); :Projects moves it to the project root, so a switch brings that
-- project's list along. Files inside the project are stored relative to
-- it, others as absolute paths.
--
-- :Anchor {command} (<Tab> completes; :Anchor alone is :Anchor menu)
--   add       anchor the current file in the first empty slot (or a new
--             one at the end); a file already anchored stays where it is
--   remove    empty the current file's slot; the other files keep their
--             numbers
--   menu      edit the list (below)
--   {N}       open the file in slot N in the current window
-- keybinds/anchor.lua maps <leader>a (add), <leader>m (menu), and, with
-- map() below, <C-p>, <C-t>, <C-s> and <C-n> (slots 1 to 4).
--
-- Only files can be anchored: not netrw listings, terminals, help, or
-- scratch and unnamed buffers. Opening a file that is already open
-- switches to its buffer, where Neovim keeps your place; one that isn't
-- goes to the '" mark, the last place you were in it (Neovim keeps it in
-- shada across restarts), and the view is centered. A slot whose file has
-- gone says so instead of opening an empty buffer.
--
-- The statusline shows an anchored file's slot key in front of its name,
-- "[C-t] neo: sub/file.txt" (see picker/statusline.lua), going by each
-- window's own project, so it is the key that opens the file from that
-- window. A slot without a key (one past the keys map() was given, or one
-- whose key now does something else, say a buffer-local mapping) shows
-- its number instead: "[5] neo: sub/file.txt".
--
-- The menu is a float over the list, one file per line, and line N is
-- slot N; a blank line is an empty slot. Edit it as text: dd deletes a
-- line (moving the lines below it up a slot), clearing a line (cc<Esc>)
-- empties the slot in place, moving lines moves files between slots, and
-- typing a path anchors that file. A path seen on an earlier line is
-- dropped, leaving its line empty. Keys: <CR> opens the file on the
-- cursor line in the window you came from; q or <Esc> closes. Leaving the
-- menu in any way (those keys, :q, <C-w>w, ...) saves it, and :w (or
-- <C-;>) saves it without leaving.
--
-- The lists live in one JSON file, stdpath("data")/neo/anchor.json, read
-- afresh on every use, so several Neovims share them (see store.lua).
-- setup({ file = path }) puts it elsewhere.
--
-- The tests: nvim -l path/to/plugins/anchor/test.lua

local store = require("neo.plugins.anchor.store")

local M = {}

local function notify(msg, level)
    vim.notify("anchor: " .. msg, level or vim.log.levels.INFO)
end

local function vim_error(err)
    err = tostring(err)
    return err:match("E%d+:.*") or err
end

local function menu()
    return require("neo.plugins.anchor.menu")
end

local function index_of(slots, stored)
    for i, slot in ipairs(slots) do
        if slot ~= "" and store.same(slot, stored) then
            return i
        end
    end
    return nil
end

local function save(root, slots)
    local ok, err = store.set(root, slots)
    if not ok then
        notify("couldn't save the list: " .. tostring(err), vim.log.levels.ERROR)
        return false
    end
    -- every window showing a file whose slot changed, not just this one
    pcall(vim.cmd, "redrawstatus!")
    return true
end

--- The current project's slots, as stored ("" is an empty slot).
function M.list()
    return store.get(store.root())
end

--- The slot the file at path (absolute) is in, in the list of the project
--- at dir (default: the current window's working directory), or nil. For
--- the statusline, which asks on every redraw: the list is read again only
--- once it has changed on disk (see store.peek), and nothing is reported.
function M.slot(path, dir)
    local root = dir and store.real(dir) or store.root()
    local slots = store.get(root, store.peek())
    return index_of(slots, store.to_stored(store.real(path), root))
end

-- The slot keys map() set: { [slot] = { lhs, callback } }.
local slot_keys = {}

--- Maps keys[i] in normal mode to open slot i (as :Anchor i does), and has
--- the statusline show an anchored file's key instead of its slot number.
function M.map(keys)
    for i, lhs in ipairs(keys) do
        local function go()
            M.select(i)
        end
        vim.keymap.set("n", lhs, go, { desc = "Anchor: Go to Slot " .. i })
        slot_keys[i] = { lhs = lhs, callback = go }
    end
end

-- How the statusline shows slot n: its key, written as map() was given it
-- with a lone <...> key's brackets dropped ("C-t" for <C-t>), as long as
-- that key still opens the slot in the current buffer; else n.
local function key_of(n)
    local key = slot_keys[n]
    if key and vim.fn.maparg(key.lhs, "n", false, true).callback == key.callback then
        return key.lhs:match("^<([^<>]+)>$") or key.lhs
    end
    return tostring(n)
end

--- What the statusline shows for the file at path (absolute) in the
--- project at dir: the key that opens its slot ("C-t"), else the slot's
--- number ("5"), or nil when it isn't anchored. Like slot(), cheap enough
--- for every redraw.
function M.slot_label(path, dir)
    local n = M.slot(path, dir)
    return n and key_of(n) or nil
end

--- :Anchor add. Returns the slot the current file is in, or nil.
function M.add()
    local file = store.file_of(0)
    if not file then
        notify("only files can be anchored", vim.log.levels.WARN)
        return nil
    end
    local root = store.root()
    local slots = store.get(root)
    local stored = store.to_stored(file, root)
    local at = index_of(slots, stored)
    if at then
        notify(("%s is already in slot %d"):format(stored, at))
        return at
    end
    at = #slots + 1
    for i, slot in ipairs(slots) do
        if slot == "" then
            at = i
            break
        end
    end
    slots[at] = stored
    if not save(root, slots) then
        return nil
    end
    notify(("%s is in slot %d"):format(stored, at))
    return at
end

--- :Anchor remove. Returns the slot the current file was in, or nil.
function M.remove()
    local file = store.file_of(0)
    if not file then
        notify("only files can be anchored", vim.log.levels.WARN)
        return nil
    end
    local root = store.root()
    local slots = store.get(root)
    local stored = store.to_stored(file, root)
    local at = index_of(slots, stored)
    if not at then
        notify(stored .. " isn't anchored")
        return nil
    end
    slots[at] = ""
    if not save(root, slots) then
        return nil
    end
    notify(("%s is out of slot %d"):format(stored, at))
    return at
end

-- The loaded buffer of file (absolute, resolved), or nil.
local function find_buf(file)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
            local name = vim.api.nvim_buf_get_name(b)
            if name ~= "" and vim.bo[b].buftype == "" and store.same(store.real(name), file) then
                return b
            end
        end
    end
    return nil
end

-- Opens file (absolute) in the current window. Returns true, or false
-- and why not.
local function edit(file)
    file = store.real(file)
    local buf = find_buf(file)
    if buf and buf == vim.api.nvim_get_current_buf() then
        return true
    end
    local ok, err
    if buf then
        -- Neovim puts the cursor back where it was in this buffer.
        ok, err = pcall(vim.api.nvim_set_current_buf, buf)
    else
        if not vim.uv.fs_stat(file) then
            return false, store.to_stored(file, store.root()) .. " no longer exists"
        end
        -- Relative to the working directory when inside it, so the buffer
        -- gets a short name.
        ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(vim.fn.fnamemodify(file, ":.")))
        if ok then
            local mark = vim.api.nvim_buf_get_mark(0, '"')
            if mark[1] > 0 and mark[1] <= vim.api.nvim_buf_line_count(0) then
                pcall(vim.api.nvim_win_set_cursor, 0, mark)
            end
        end
    end
    if not ok then
        return false, vim_error(err)
    end
    vim.cmd("normal! zz")
    return true
end

--- :Anchor N: opens the file in slot n in the current window. Returns
--- true, or false.
function M.select(n)
    -- From the menu (the slot keys work there too), save and leave it first,
    -- for the window it was opened from.
    if menu().is_current() and not menu().close() then
        return false
    end
    local root = store.root()
    local slot = store.get(root)[n]
    if not slot or slot == "" then
        notify(("slot %d is empty"):format(n))
        return false
    end
    local ok, err = edit(store.to_abs(slot, root))
    if not ok then
        notify(err, vim.log.levels.WARN)
    end
    return ok
end

--- :Anchor menu: the editable list. Returns its buffer and window.
function M.menu()
    return menu().open()
end

M.commands = {
    add = M.add,
    remove = M.remove,
    menu = M.menu,
}

local function names()
    local list = vim.tbl_keys(M.commands)
    table.sort(list)
    return list
end

--- Runs :Anchor with its argument (nil for none).
function M.command(arg)
    arg = arg or "menu"
    local n = arg:match("^%d+$") and tonumber(arg)
    if n and n > 0 then
        return M.select(n)
    end
    local cmd = M.commands[arg]
    if not cmd then
        notify(("unknown command '%s'; the commands are %s, or a slot number"):format(
            arg, table.concat(names(), ", ")), vim.log.levels.ERROR)
        return nil
    end
    return cmd()
end

--- Completes :Anchor's argument: the commands, and the filled slots.
function M.complete(lead)
    local out = {}
    for _, name in ipairs(names()) do
        if name:sub(1, #lead) == lead then
            out[#out + 1] = name
        end
    end
    for i, slot in ipairs(M.list()) do
        if slot ~= "" and tostring(i):sub(1, #lead) == lead then
            out[#out + 1] = tostring(i)
        end
    end
    return out
end

--- opts.file: where the lists live (default stdpath("data")/neo/anchor.json).
function M.setup(opts)
    opts = opts or {}
    if opts.file then
        store.file = vim.fs.normalize(opts.file)
    end
    require("neo.plugins.picker.statusline").set_slotter(M.slot_label)
    vim.api.nvim_create_user_command("Anchor", function(o)
        M.command(o.fargs[1])
    end, {
        nargs = "?",
        desc = "Anchor: add, remove, menu, or open slot N",
        complete = M.complete,
    })
end

return M
