-- lua/neo/plugins/malleable/init.lua
-- Buffers that plugins render and users act on or edit: the small core
-- shared by the Git, file, and lc plugins. It owns the buffer's lifecycle,
-- safe redraws, keys, and the shape of a write. What the lines mean, how
-- they're parsed, and what a write does stay in each plugin.
--
--   local malleable = require("neo.plugins.malleable")
--   local view, created = malleable.open({
--       name = "harbor://" .. dir,   -- reused by name
--       filetype = "harbor",
--       editable = true,
--       on_write = function(view, done) apply(view, done) end,
--       keys = { { "<CR>", open_entry, desc = "Open" } },
--   })
--   vim.api.nvim_win_set_buf(0, view.buf)   -- open never touches windows
--   view:replace(lines)
--
-- opts for M.open():
--   name          the buffer's name, URI-style ("scheme://..."); opening the
--                 same name again returns the same view
--   filetype      optional
--   editable      true: acwrite, :w runs on_write
--                 false (default): nofile, nomodifiable
--   on_write(view, done)   required when editable; see write.lua
--   on_reload(view)        after :e! has put back the last rendered lines
--   on_wipe(view)          after the buffer is gone (:bdelete or :bwipeout)
--   keys          see keys.lua
--
-- A view's methods are in view.lua: replace, when_stable, help.
-- M.confirm is in confirm.lua. M.unsaved() lists views with unsaved edits,
-- for anything about to throw buffers away.
local View = require("neo.plugins.malleable.view")
local keys = require("neo.plugins.malleable.keys")
local write = require("neo.plugins.malleable.write")

local M = {}

M.confirm = require("neo.plugins.malleable.confirm").confirm

local views = {}

local function find_view(name)
    for buf, view in pairs(views) do
        if view.name == name and vim.api.nvim_buf_is_valid(buf) then
            return view
        end
    end
end

-- A buffer of this name that isn't a view yet: a session brings them back
-- as plain empty buffers, in the windows that showed them.
local function find_buffer(name)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf) == name then
            return buf
        end
    end
end

local function configure(buf, opts)
    local bo = vim.bo[buf]
    -- nofile first, so loading an adopted buffer never reads a file
    bo.buftype = "nofile"
    if not vim.api.nvim_buf_is_loaded(buf) then
        vim.fn.bufload(buf)
    end
    bo.buftype = opts.editable and "acwrite" or "nofile"
    -- (not "wipe": :close on a modified buffer that would be wiped is E37)
    bo.bufhidden = "hide"
    bo.swapfile = false
    bo.buflisted = false
    bo.modifiable = opts.editable == true
    bo.modified = false
    if opts.filetype then
        bo.filetype = opts.filetype
    end
end

local function teardown(view, on_wipe)
    if views[view.buf] ~= view then return end
    views[view.buf] = nil
    view:dispose()
    pcall(vim.api.nvim_del_augroup_by_id, view.group)
    if on_wipe then on_wipe(view) end
end

local function watch_lifecycle(view, opts)
    local buf = view.buf
    -- Without this, :e! leaves the buffer empty.
    vim.api.nvim_create_autocmd("BufReadCmd", {
        group = view.group,
        buffer = buf,
        callback = function()
            view:replace(view.rendered or { "" }, { force = true })
            if opts.on_reload then opts.on_reload(view) end
        end,
    })
    -- :bdelete leaves a valid, unloaded buffer. :e! unloads too, but it's
    -- loaded again by the next tick.
    vim.api.nvim_create_autocmd("BufUnload", {
        group = view.group,
        buffer = buf,
        callback = function()
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(buf) and not vim.api.nvim_buf_is_loaded(buf) then
                    pcall(vim.api.nvim_buf_delete, buf, { force = true })
                end
            end)
        end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = view.group,
        buffer = buf,
        callback = function()
            teardown(view, opts.on_wipe)
        end,
    })
end

--- Returns the view for opts.name, and whether this call created it.
function M.open(opts)
    if type(opts.name) ~= "string" or opts.name == "" then
        error("malleable: open needs a name", 2)
    end
    if opts.editable and type(opts.on_write) ~= "function" then
        error("malleable: an editable view needs on_write", 2)
    end
    local existing = find_view(opts.name)
    if existing then return existing, false end

    local buf = find_buffer(opts.name)
    if not buf then
        buf = vim.api.nvim_create_buf(false, false)
        vim.api.nvim_buf_set_name(buf, opts.name)
    end
    configure(buf, opts)

    local view = View.new({ buf = buf, editable = opts.editable })
    view.name = opts.name
    view.group = vim.api.nvim_create_augroup("neo.malleable." .. buf, { clear = true })
    keys.apply(view, opts.keys)
    if opts.editable then
        write.attach(view, opts.on_write)
    end
    watch_lifecycle(view, opts)
    views[buf] = view
    return view, true
end

--- Views with unsaved edits, oldest buffer first.
function M.unsaved()
    local out = {}
    for buf, view in pairs(views) do
        if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
            out[#out + 1] = view
        end
    end
    table.sort(out, function(a, b) return a.buf < b.buf end)
    return out
end

return M
