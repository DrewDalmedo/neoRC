-- lua/neo/plugins/anchor/menu.lua
-- The editable list (see init.lua's header for how it behaves): a float
-- over an acwrite buffer, one slot per line, read back into slots when it
-- is saved. Leaving it in any way saves it and closes it, so it is only
-- ever open while it is the current window.

local store = require("neo.plugins.anchor.store")

local M = {}

-- The open menu: { buf, win, origin, root }, or nil.
local menu = nil

--- The open menu's buffer and window, or nil.
function M.current()
    if menu then
        return menu.buf, menu.win
    end
    return nil
end

--- Whether the current window is the menu.
function M.is_current()
    return menu ~= nil and vim.api.nvim_get_current_win() == menu.win
end

--- Lines read back into slots: blank lines are empty slots, a path seen
--- on an earlier line is blanked (so the lines below keep their numbers),
--- and every path is stored as :Anchor add would store it.
function M.parse(lines, root)
    local slots, seen = {}, {}
    for i, line in ipairs(lines) do
        local text = vim.trim(line)
        local stored = ""
        if text ~= "" then
            stored = store.canonical(text, root)
            if seen[store.key(stored)] then
                stored = ""
            else
                seen[store.key(stored)] = true
            end
        end
        slots[i] = stored
    end
    return slots
end

-- Saves m's lines as its project's slots. With refresh, the buffer then
-- shows them as saved (paths in stored form, no trailing blank lines).
-- Returns the slots, or nil after an error (which is shown).
local function save(m, refresh)
    if not vim.api.nvim_buf_is_valid(m.buf) then
        return nil
    end
    local slots = M.parse(vim.api.nvim_buf_get_lines(m.buf, 0, -1, false), m.root)
    local ok, err = store.set(m.root, slots)
    if not ok then
        vim.notify("anchor: couldn't save the list: " .. tostring(err), vim.log.levels.ERROR)
        return nil
    end
    -- the slot numbers on the statusline
    pcall(vim.cmd, "redrawstatus!")
    if refresh then
        local shown = vim.deepcopy(slots)
        while #shown > 0 and shown[#shown] == "" do
            shown[#shown] = nil
        end
        local cursor = vim.api.nvim_win_is_valid(m.win) and vim.api.nvim_win_get_cursor(m.win)
        vim.api.nvim_buf_set_lines(m.buf, 0, -1, false, shown)
        if cursor then
            cursor[1] = math.min(cursor[1], vim.api.nvim_buf_line_count(m.buf))
            pcall(vim.api.nvim_win_set_cursor, m.win, cursor)
        end
    end
    vim.bo[m.buf].modified = false
    return slots
end

-- Closes m's window and wipes its buffer; with focus, the window it was
-- opened from becomes current again.
local function teardown(m, focus)
    if vim.api.nvim_win_is_valid(m.win) then
        pcall(vim.api.nvim_win_close, m.win, true)
    end
    if vim.api.nvim_buf_is_valid(m.buf) then
        pcall(vim.api.nvim_buf_delete, m.buf, { force = true })
    end
    if focus and vim.api.nvim_win_is_valid(m.origin) then
        vim.api.nvim_set_current_win(m.origin)
    end
end

--- Saves and closes the menu, back to the window it was opened from.
--- Returns false, staying open, when saving failed.
function M.close()
    local m = menu
    if not m then
        return true
    end
    if not save(m) then
        return false
    end
    menu = nil
    teardown(m, true)
    return true
end

-- <CR>: save, close, and open the cursor line's file (a blank line just
-- closes).
local function choose()
    local m = menu
    if not m then
        return
    end
    local row = vim.api.nvim_win_get_cursor(m.win)[1]
    local slots = save(m)
    if not slots then
        return
    end
    menu = nil
    teardown(m, true)
    if (slots[row] or "") ~= "" then
        require("neo.plugins.anchor").select(row)
    end
end

-- Leaving the menu by any other way than its keys (:q, <C-w>w, a click):
-- save, and close it once Neovim is done leaving.
local function left(m)
    if menu ~= m then
        return
    end
    menu = nil
    save(m)
    vim.schedule(function()
        teardown(m, false)
    end)
end

--- Opens the menu for the current project, or goes to it when it is open.
--- Returns its buffer and window.
function M.open()
    if menu and vim.api.nvim_win_is_valid(menu.win) then
        vim.api.nvim_set_current_win(menu.win)
        return menu.buf, menu.win
    end
    local root = store.root()
    local slots = store.get(root)
    local origin = vim.api.nvim_get_current_win()

    -- Start on the current file's line when it is anchored.
    local line = 1
    local file = store.file_of(0)
    if file then
        local stored = store.to_stored(file, root)
        for i, slot in ipairs(slots) do
            if slot ~= "" and store.same(slot, stored) then
                line = i
                break
            end
        end
    end

    local name = "anchor://" .. root
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b) == name then
            pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
    end
    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].buftype = "acwrite"
    -- (not "wipe": :close on a modified buffer that would be wiped is
    -- E37; teardown wipes it once it is saved)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, slots)
    vim.bo[buf].modified = false
    vim.bo[buf].filetype = "anchor"

    local width = math.max(1, math.min(80, vim.o.columns - 4))
    local height = math.max(1, math.min(math.max(#slots + 1, 5), vim.o.lines - 4))
    local title = vim.fs.basename(root)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        style = "minimal",
        border = "rounded",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        title = (" Anchor · %s "):format(title ~= "" and title or root),
        title_pos = "left",
    })
    -- Line numbers are the slot numbers.
    vim.wo[win].number = true
    vim.wo[win].relativenumber = false
    vim.wo[win].cursorline = true
    vim.wo[win].wrap = false
    pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })

    local m = { buf = buf, win = win, origin = origin, root = root }
    menu = m

    local opts = { buffer = buf, nowait = true, silent = true }
    vim.keymap.set("n", "<CR>", choose, vim.tbl_extend("force", opts, { desc = "anchor: open the file" }))
    vim.keymap.set("n", "q", M.close, vim.tbl_extend("force", opts, { desc = "anchor: close" }))
    vim.keymap.set("n", "<Esc>", M.close, vim.tbl_extend("force", opts, { desc = "anchor: close" }))

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function()
            save(m, true)
        end,
    })
    -- :qa from the menu checks for unsaved buffers after this.
    vim.api.nvim_create_autocmd("QuitPre", {
        buffer = buf,
        callback = function()
            save(m)
        end,
    })
    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = buf,
        callback = function()
            left(m)
        end,
    })
    -- The window closed from elsewhere (nvim_win_close).
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win),
        once = true,
        callback = function()
            left(m)
        end,
    })
    return buf, win
end

return M
