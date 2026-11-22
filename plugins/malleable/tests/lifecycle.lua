-- lua/neo/plugins/malleable/tests/lifecycle.lua
local malleable = require("neo.plugins.malleable")

local count = 0
local function name()
    count = count + 1
    return "malltest://lifecycle/" .. count
end

local function noop() end

local function get(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

return function(t)
    do
        local view, created = malleable.open({ name = name(), filetype = "malltest" })
        local bo = vim.bo[view.buf]
        t.eq("open reports a new view", created, true)
        t.eq("read-only is nofile", bo.buftype, "nofile")
        t.eq("read-only is nomodifiable", bo.modifiable, false)
        t.eq("hidden, not wiped", bo.bufhidden, "hide")
        t.eq("no swapfile", bo.swapfile, false)
        t.eq("unlisted", bo.buflisted, false)
        t.eq("filetype set", bo.filetype, "malltest")
        t.ok("open leaves the current buffer", vim.api.nvim_get_current_buf() ~= view.buf)
    end

    do
        local view = malleable.open({ name = name(), editable = true, on_write = noop })
        t.eq("editable is acwrite", vim.bo[view.buf].buftype, "acwrite")
        t.eq("editable is modifiable", vim.bo[view.buf].modifiable, true)
        t.eq("editable starts unmodified", vim.bo[view.buf].modified, false)
    end

    do
        local shared = name()
        local first = malleable.open({ name = shared })
        local again, created = malleable.open({ name = shared })
        t.ok("same name reuses the view", again == first)
        t.eq("reuse isn't reported as new", created, false)
        t.ok("another name is another view", malleable.open({ name = name() }) ~= first)
    end

    do
        t.eq("a name is required", pcall(malleable.open, {}), false)
        t.eq("editable needs on_write", pcall(malleable.open, { name = name(), editable = true }), false)
    end

    do
        local hit
        local view = malleable.open({
            name = name(),
            keys = { { "zk", function(v) hit = v end, desc = "Key" } },
        })
        vim.api.nvim_set_current_buf(view.buf)
        vim.api.nvim_feedkeys("zk", "mx", false)
        t.ok("open maps keys", hit == view)
    end

    do
        local stale = name()
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(buf, stale)
        vim.api.nvim_set_current_buf(buf)
        local win = vim.api.nvim_get_current_win()
        local view = malleable.open({ name = stale })
        t.eq("adopts a restored buffer", view.buf, buf)
        t.eq("adopted buffer stays in its window", vim.api.nvim_win_get_buf(win), buf)
        t.eq("adopted buffer is configured", vim.bo[buf].buftype, "nofile")
    end

    do
        local wiped = {}
        local view = malleable.open({ name = name(), on_wipe = function(v) wiped[#wiped + 1] = v end })
        vim.api.nvim_set_current_buf(view.buf)
        vim.cmd("enew")
        t.ok("hiding keeps the buffer", vim.api.nvim_buf_is_loaded(view.buf))
        t.eq("hiding doesn't fire on_wipe", #wiped, 0)
        local buf = view.buf
        vim.cmd("bwipeout! " .. buf)
        t.eq("on_wipe fires once", #wiped, 1)
        t.ok("on_wipe gets the view", wiped[1] == view)
        t.ok("wipe disposes the view", view.disposed)
    end

    do
        local shared, wiped = name(), 0
        local view = malleable.open({ name = shared, on_wipe = function() wiped = wiped + 1 end })
        local buf = view.buf
        vim.cmd("bdelete! " .. buf)
        vim.wait(100, function() return wiped > 0 end)
        t.eq(":bdelete fires on_wipe", wiped, 1)
        t.ok(":bdelete removes the buffer", not vim.api.nvim_buf_is_valid(buf))
        local fresh, created = malleable.open({ name = shared })
        t.eq("reopening after it is new", created, true)
        t.ok("reopening makes a new view", fresh ~= view)
    end

    do
        local reloaded, wiped = 0, 0
        local view = malleable.open({
            name = name(),
            on_reload = function() reloaded = reloaded + 1 end,
            on_wipe = function() wiped = wiped + 1 end,
        })
        view:replace({ "rendered1", "rendered2" })
        vim.api.nvim_set_current_buf(view.buf)
        vim.cmd("edit!")
        vim.wait(20)
        t.eq(":e! restores read-only text", get(view.buf), { "rendered1", "rendered2" })
        t.eq(":e! keeps nomodifiable", vim.bo[view.buf].modifiable, false)
        t.eq(":e! calls on_reload", reloaded, 1)
        t.eq(":e! isn't a wipe", wiped, 0)
        t.ok(":e! keeps the view alive", not view.disposed)
        t.eq("the view still replaces", view:replace({ "next" }), true)
        vim.cmd("enew")
    end

    do
        local view = malleable.open({ name = name(), editable = true, on_write = noop })
        view:replace({ "saved" })
        vim.api.nvim_set_current_buf(view.buf)
        vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, { "edit to discard" })
        vim.cmd("edit!")
        vim.wait(20)
        t.eq(":e! discards editable edits", get(view.buf), { "saved" })
        t.eq(":e! clears modified", vim.bo[view.buf].modified, false)
        vim.cmd("enew")
    end

    do
        local clean = malleable.open({ name = name(), editable = true, on_write = noop })
        local dirty = malleable.open({ name = name(), editable = true, on_write = noop })
        vim.api.nvim_buf_set_lines(dirty.buf, 0, -1, false, { "unsaved" })
        local unsaved = malleable.unsaved()
        local has_dirty, has_clean = false, false
        for _, view in ipairs(unsaved) do
            has_dirty = has_dirty or view == dirty
            has_clean = has_clean or view == clean
        end
        t.ok("unsaved lists a modified view", has_dirty)
        t.ok("unsaved skips a clean view", not has_clean)
        vim.cmd("bwipeout! " .. dirty.buf)
        for _, view in ipairs(malleable.unsaved()) do
            t.ok("unsaved drops a wiped view", view ~= dirty)
        end
    end
end
