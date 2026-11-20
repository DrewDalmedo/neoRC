-- lua/neo/plugins/picker/test.lua
-- Run from anywhere: nvim -l path/to/plugins/picker/test.lua
-- Standalone: neo.* requires resolve relative to this file, so no rtp setup
-- is needed and an installed copy of the config never shadows this checkout.
local here = debug.getinfo(1, "S").source:sub(2):match("(.*)[/\\]")
local root = here .. "/../.."

table.insert(package.loaders or package.searchers, 2, function(name)
    local rel = name:match("^neo%.(.+)$")
    if not rel then return end
    local base = root .. "/" .. rel:gsub("%.", "/")
    for _, cand in ipairs({ base .. ".lua", base .. "/init.lua" }) do
        local f = io.open(cand, "r")
        if f then
            f:close()
            return function() return dofile(cand) end
        end
    end
end)

local picker = require("neo.plugins.picker")

local failures = 0
local function eq(desc, got, want)
    if got ~= want then
        failures = failures + 1
        print(("FAIL %s: got=%s want=%s"):format(desc, vim.inspect(got), vim.inspect(want)))
    else
        print("ok   " .. desc)
    end
end

-- the buffer-local mapping for lhs in mode, from the current (prompt) buffer
local function map(lhs, mode)
    local m = vim.fn.maparg(lhs, mode, false, true)
    return m.buffer == 1 and m or nil
end

local function footer_text(win)
    local footer = vim.api.nvim_win_get_config(win).footer
    if type(footer) ~= "table" then return footer end
    local parts = {}
    for _, chunk in ipairs(footer) do
        parts[#parts + 1] = chunk[1]
    end
    return table.concat(parts)
end

-- keys: mapped in the prompt in insert and normal mode, handed the open
-- controller; footer: shown on the results window's bottom border
local chosen, handed
local p = picker.open({
    title = " Test ",
    footer = " <C-y> yank ",
    items = { { display = "alpha" }, { display = "beta" } },
    on_select = function(item) chosen = item.display end,
    keys = { ["<C-y>"] = function(pp) handed = pp end },
})
eq("footer shown", footer_text(p.ui.results_win), " <C-y> yank ")
eq("key mapped in insert mode", map("<C-y>", "i") ~= nil, true)
eq("key mapped in normal mode", map("<C-y>", "n") ~= nil, true)
map("<C-y>", "i").callback()
eq("key gets the controller", handed, p)
eq("key leaves the picker open", p:valid(), true)

-- selection() is the highlighted item; choose() is what <CR> does
eq("selection starts at the top", p:selection().display, "alpha")
p:select(2)
eq("selection follows the cursor", p:selection().display, "beta")
p:choose()
eq("choose selects the highlighted item", chosen, "beta")
eq("choose closes", p:valid(), false)
eq("nothing selected once closed", p:selection(), nil)

-- no footer unless asked for
p = picker.open({ items = { { display = "x" } } })
eq("no footer by default", footer_text(p.ui.results_win) or "", "")
p:close()

-- choose on an empty list just closes
local called = false
p = picker.open({ items = {}, on_select = function() called = true end })
eq("empty selection", p:selection(), nil)
p:choose()
eq("empty choose selects nothing", called, false)
eq("empty choose closes", p:valid(), false)

-- without on_select, choose runs the item's own action
local acted
p = picker.open({ items = { { display = "x", action = function(item) acted = item.display end } } })
p:choose()
eq("choose falls back to item.action", acted, "x")

-- keys win over the built-in maps
local overridden = false
p = picker.open({ items = { { display = "x" } }, keys = { ["<CR>"] = function() overridden = true end } })
map("<CR>", "i").callback()
eq("keys override built-ins", overridden, true)
eq("overridden <CR> doesn't close", p:valid(), true)
p:close()

if failures > 0 then
    print("FAILURES: " .. failures)
    os.exit(1)
end
print("ALL PICKER TESTS PASSED")
