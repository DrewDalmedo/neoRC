-- lua/neo/plugins/picker/init.lua
-- Generic floating picker framework: a prompt window over a results window,
-- with fuzzy filtering, list navigation, and async-friendly item streaming.
-- Plugins build on this instead of rolling their own picker plumbing:
--
--   local picker = require("neo.plugins.picker")
--   picker.open({
--       title = " Projects ",
--       items = { { display = "neo", path = "~/.config/nvim/lua/neo" } },
--       on_select = function(item)
--           vim.cmd("cd " .. vim.fn.fnameescape(item.path))
--       end,
--   })
--
-- An item is any table with a `display` string; other fields are caller data.
--
-- opts for M.open():
--   title            window title string
--   items            initial item list (default {})
--   filter           "fuzzy" (default): rank items against the prompt text
--                    "none": show items as-is (source pre-filters, e.g. grep)
--   limit            maximum rendered results (default 500)
--   width, height    window geometry overrides
--   on_select(item)  called on <CR> after the picker closes; when absent the
--                    picker falls back to calling item.action(item)
--   on_query(q, p)   debounced hook on prompt changes, for sources that
--                    recompute the items externally (pair with filter="none")
--   query_debounce   ms delay before on_query fires (default 120)
--   on_close(p)      cleanup hook: stop jobs/timers the caller owns
--
-- M.open returns a controller `p`. Async producers hold onto it and use:
--   p:add_items(list)  append items and refresh (debounced, cheap per chunk)
--   p:set_items(list)  replace all items and refresh now
--   p:query()          current prompt text, trimmed
--   p:count()          number of items currently held
--   p:valid()          false once closed or superseded; check before touching
--   p:close()          tear down (also runs on <Esc>, <CR>, window close)
--
-- Only one picker is open at a time; opening a new one closes the old one.
-- Keys: <CR> select; <Esc> close (normal mode); <Up>/<Down> move (any mode);
-- j/k/gg/G move (normal mode). Extra buffer-local maps can be added to
-- p.ui.prompt_buf after open().
local ui = require("neo.plugins.picker.ui")
local fuzzy = require("neo.plugins.picker.fuzzy")
local util = require("neo.plugins.picker.util")

local M = {}

-- Re-exported so consumers can use the pieces on their own.
M.ui, M.fuzzy, M.util = ui, fuzzy, util

local DEFAULT_LIMIT = 500
local FILTER_DEBOUNCE_MS = 30
local QUERY_DEBOUNCE_MS = 120

local active = nil

local Picker = {}
Picker.__index = Picker

function Picker:valid()
    return not self.closed and active == self and ui.is_valid(self.ui)
end

function Picker:query()
    if not (self.ui.prompt_buf and vim.api.nvim_buf_is_valid(self.ui.prompt_buf)) then
        return ""
    end
    local line = vim.api.nvim_buf_get_lines(self.ui.prompt_buf, 0, 1, false)[1] or ""
    return (line:match("^%s*(.-)%s*$"))
end

function Picker:count()
    return #self.items
end

-- Re-filter items against the prompt and render from the top.
function Picker:refresh()
    if not self:valid() then return end
    local query = self:query()
    if self.filter == "none" or query == "" then
        -- "none" sources pre-filter their items; empty prompts keep insertion order
        local shown = {}
        for i = 1, math.min(#self.items, self.limit) do
            shown[i] = self.items[i]
        end
        self.filtered = shown
    else
        self.filtered = fuzzy.filter(self.items, query, { limit = self.limit })
    end
    self.selected = #self.filtered == 0 and 0 or 1
    ui.render(self.ui, self.filtered, self.selected)
end

-- Move the selection (clamped) without re-filtering.
function Picker:select(idx)
    if #self.filtered == 0 then
        self.selected = 0
    else
        self.selected = math.max(1, math.min(idx, #self.filtered))
    end
    ui.render(self.ui, self.filtered, self.selected)
end

function Picker:set_items(items)
    if not self:valid() then return end
    self.items = items or {}
    self:refresh()
end

function Picker:add_items(items)
    if not self:valid() then return end
    local n = #self.items
    for i, item in ipairs(items) do
        self.items[n + i] = item
    end
    self._debounced_refresh()
end

function Picker:close()
    if self.closed then return end
    self.closed = true
    if active == self then active = nil end
    self._debounced_refresh.close()
    if self._debounced_query then self._debounced_query.close() end
    if self._winclosed_autocmd then
        pcall(vim.api.nvim_del_autocmd, self._winclosed_autocmd)
        self._winclosed_autocmd = nil
    end
    if vim.api.nvim_get_mode().mode:match("i") then vim.cmd("stopinsert") end
    if self.on_close then self.on_close(self) end
    ui.close(self.ui)
    self.items, self.filtered, self.selected = {}, {}, 0
end

local function setup_keymaps(self)
    local opts = { buffer = self.ui.prompt_buf, silent = true, nowait = true }

    vim.keymap.set({ "i", "n" }, "<CR>", function()
        local sel = self.filtered[self.selected]
        self:close()
        if not sel then return end
        local action = self.on_select or sel.action
        if action then action(sel) end
    end, opts)

    vim.keymap.set("n", "<Esc>", function() self:close() end, opts)

    vim.keymap.set({ "i", "n" }, "<Up>", function() self:select(self.selected - 1) end, opts)
    vim.keymap.set({ "i", "n" }, "<Down>", function() self:select(self.selected + 1) end, opts)
    vim.keymap.set("n", "k", function() self:select(self.selected - 1) end, opts)
    vim.keymap.set("n", "j", function() self:select(self.selected + 1) end, opts)
    vim.keymap.set("n", "gg", function() self:select(1) end, opts)
    vim.keymap.set("n", "go", function() self:select(1) end, opts)
    vim.keymap.set("n", "G", function() self:select(#self.filtered) end, opts)
end

local function setup_autocmds(self)
    -- Buffer-local autocmds die with the wiped prompt buffer; only the
    -- window-pattern one below needs manual cleanup in close().
    vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
        buffer = self.ui.prompt_buf,
        callback = function()
            self._debounced_refresh()
            if self._debounced_query then self._debounced_query() end
        end,
    })

    self._winclosed_autocmd = vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(self.ui.prompt_win),
        once = true,
        callback = function() self:close() end,
    })
end

-- The currently open picker controller, or nil.
function M.current()
    return active
end

function M.open(opts)
    opts = opts or {}
    if active then active:close() end

    local self = setmetatable({
        items = opts.items or {},
        filtered = {},
        selected = 0,
        filter = opts.filter or "fuzzy",
        limit = opts.limit or DEFAULT_LIMIT,
        on_select = opts.on_select,
        on_close = opts.on_close,
        closed = false,
    }, Picker)

    self.ui = ui.create({ title = opts.title, width = opts.width, height = opts.height })
    active = self

    self._debounced_refresh = util.debounce(FILTER_DEBOUNCE_MS, function() self:refresh() end)
    if opts.on_query then
        self._debounced_query = util.debounce(opts.query_debounce or QUERY_DEBOUNCE_MS, function()
            if self:valid() then opts.on_query(self:query(), self) end
        end)
    end

    setup_keymaps(self)
    setup_autocmds(self)
    vim.cmd("startinsert!")
    self:refresh()
    return self
end

return M
