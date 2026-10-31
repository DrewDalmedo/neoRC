-- lua/neo/plugins/lc/tests/start.lua
-- :Lc start and :Lc show.

local H = require("neo.plugins.lc.tests.helpers")
local tests = {}
local function test(name, fn)
    tests[#tests + 1] = { name, fn }
end

local function wins()
    return vim.api.nvim_tabpage_list_wins(0)
end

local function statement_win()
    for _, w in ipairs(wins()) do
        if vim.w[w].lc_statement then
            return w
        end
    end
    return nil
end

local function bufname(win)
    return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
end

test("start opens the solution with the statement beside it", function()
    vim.cmd("Lc start 1")
    local dir = H.workspace .. "/0001-two-sum"
    H.eq(vim.fn.resolve(vim.api.nvim_buf_get_name(0)), vim.fn.resolve(dir .. "/solution.cpp"))
    H.eq(vim.bo.filetype, "cpp")
    H.eq(#wins(), 2)
    local sw = H.ok(statement_win(), "no statement window")
    H.ok(bufname(sw):match("/0001%-two%-sum/README%.md$"), bufname(sw))
    H.ok(sw ~= vim.api.nvim_get_current_win(), "the cursor should stay in the solution")
    H.has(H.lines(vim.api.nvim_win_get_buf(sw)), "# 1. Two Sum")
    H.ok(vim.uv.fs_stat(dir .. "/cases.txt"), "no cases.txt")
end)

test("starting another problem reuses the windows", function()
    vim.cmd("Lc start 9 c")
    H.ok(vim.api.nvim_buf_get_name(0):match("/0009%-palindrome%-number/solution%.c$"))
    H.eq(vim.bo.filetype, "c")
    vim.cmd("Lc start two-sum")
    H.eq(#wins(), 2)
    H.ok(vim.api.nvim_buf_get_name(0):match("/0001%-two%-sum/solution%.cpp$"))
    H.ok(bufname(statement_win()):match("/0001%-two%-sum/README%.md$"))
end)

test("start without a problem takes the buffer's", function()
    vim.cmd("Lc start 1")
    vim.cmd("Lc start c")
    H.ok(vim.api.nvim_buf_get_name(0):match("/0001%-two%-sum/solution%.c$"), vim.api.nvim_buf_get_name(0))
    vim.cmd("Lc start --lang cpp")
    H.ok(vim.api.nvim_buf_get_name(0):match("/0001%-two%-sum/solution%.cpp$"))
    H.eq(#wins(), 2)
end)

test("start from the result window opens the solution elsewhere", function()
    vim.o.number = true
    vim.cmd("Lc start 1")
    vim.cmd("only")
    H.run("Lc test")
    vim.api.nvim_set_current_win(H.result_win())
    vim.cmd("only")
    vim.cmd("Lc start 9")
    H.ok(vim.api.nvim_buf_get_name(0):match("/0009%-palindrome%-number/solution%.cpp$"))
    H.ok(not vim.w.lc_result, "the solution went into the result window")
    -- The panel's settings stay with the panel.
    H.eq(vim.wo.number, true)
    H.eq(vim.wo.signcolumn, "auto")
    vim.o.number = false
end)

test("a window you took back from lc stays yours", function()
    vim.cmd("Lc start 1")
    vim.cmd("wincmd h")
    local notes = H.tmp .. "/notes.txt"
    vim.cmd("edit " .. vim.fn.fnameescape(notes))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "mine" })
    local mine = vim.api.nvim_get_current_win()
    vim.cmd("wincmd l")
    vim.cmd("Lc start 9")
    H.eq(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(mine)), vim.fn.resolve(notes) == notes and notes or vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(mine)))
    H.ok(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(mine)):match("notes%.txt$"), "notes.txt was replaced")
    H.eq(#wins(), 3)
    H.ok(bufname(statement_win()):match("/0009%-palindrome%-number/README%.md$"))
    -- Likewise with 'nohidden'.
    vim.o.hidden = false
    vim.cmd("Lc start 70")
    H.no_errors()
    vim.o.hidden = true
    H.ok(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(mine)):match("notes%.txt$"))
end)

test("show from a lone result window opens one window", function()
    vim.cmd("Lc start 1")
    H.run("Lc test")
    vim.api.nvim_set_current_win(H.result_win())
    vim.cmd("only")
    vim.cmd("Lc show 9")
    H.eq(#wins(), 2)
    H.ok(statement_win(), "no statement window")
end)

test("a result window you reuse loses the panel's settings", function()
    vim.cmd("Lc start 1")
    H.run("Lc test")
    local panel = H.result_win()
    vim.api.nvim_set_current_win(panel)
    vim.cmd("edit " .. vim.fn.fnameescape(H.tmp .. "/mine.txt"))
    vim.cmd("wincmd t")
    H.run("Lc test")
    H.ok(H.result_win() ~= panel, "the result took the window back")
    H.eq(vim.wo[panel].winfixheight, false)
end)

test("'winfixbuf' windows are left alone", function()
    vim.cmd("enew")
    vim.cmd("vsplit")
    vim.wo.winfixbuf = true
    local fixed = vim.api.nvim_get_current_win()
    vim.cmd("Lc start 1")
    H.no_errors()
    H.ok(vim.api.nvim_get_current_win() ~= fixed)
    H.ok(vim.api.nvim_buf_get_name(0):match("/0001%-two%-sum/solution%.cpp$"))
end)

test("buffers a session brought back are taken over", function()
    -- What :mksession and a restore leave: plain buffers with lc's names.
    vim.cmd("enew")
    vim.cmd("file lc://problem/0009-palindrome-number")
    vim.cmd("vsplit | enew")
    vim.cmd("file lc://result")
    vim.cmd("vsplit | enew")
    vim.cmd("file lc://stats")
    vim.cmd("Lc show 9")
    vim.cmd("Lc stats")
    H.no_errors()
    H.eq(#wins(), 3, "the restored windows should be used")
    for _, name in ipairs({ "lc://problem/0009-palindrome-number", "lc://stats" }) do
        local buf = vim.fn.bufnr(name)
        H.eq(vim.bo[buf].buftype, "nofile", name)
        H.ok(#H.lines(buf) > 1, name .. " is empty")
    end
    H.start(1, "cpp", "two-sum/ok.cpp")
    H.run("Lc test")
    H.no_errors()
    H.has(H.lines(H.result_buf()), "Accepted: 3/3")
end)

test(":Lc std reaches clangd through the next start", function()
    vim.cmd("Lc start 1")
    H.has(H.read(H.workspace .. "/.clangd"), "-std=c++11")
    vim.cmd("Lc std c++17")
    vim.cmd("Lc start")
    H.has(H.read(H.workspace .. "/.clangd"), "-std=c++17")
end)

test("start keeps unsaved changes", function()
    vim.cmd("Lc start 1")
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "// mine" })
    vim.cmd("Lc start 1")
    H.no_errors()
    H.eq(vim.bo.modified, true)
    H.eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "// mine")
    H.eq(#wins(), 2)
end)

test("statement = false opens the solution alone", function()
    require("neo.plugins.lc").setup({ cmd = H.lc, statement = false })
    vim.cmd("Lc start 1")
    H.eq(#wins(), 1)
end)

test("start of an unknown problem", function()
    vim.cmd("Lc start 99999")
    H.eq(H.note("no problem matches").level, vim.log.levels.ERROR)
    H.eq(#wins(), 1)
end)

test("show matches the README that lc start writes", function()
    vim.cmd("Lc start 1")
    local readme = vim.split(H.read(H.workspace .. "/0001-two-sum/README.md"), "\n")
    -- Without the closing note: from the blank line before its "---".
    local rule
    for i, l in ipairs(readme) do
        if l == "---" then
            rule = i
        end
    end
    readme = vim.list_slice(readme, 1, rule - 2)
    vim.cmd("Lc show")
    local sw = statement_win()
    H.eq(bufname(sw), "lc://problem/0001-two-sum")
    H.eq(vim.bo[vim.api.nvim_win_get_buf(sw)].filetype, "markdown")
    H.eq(H.lines(vim.api.nvim_win_get_buf(sw)), readme)
    H.eq(#wins(), 2)
    H.ok(vim.bo.filetype == "cpp", "the cursor should stay in the solution")
end)

test("show another problem in the same window", function()
    vim.cmd("Lc show 9")
    H.eq(#wins(), 2)
    local buf = vim.api.nvim_win_get_buf(statement_win())
    H.has(H.lines(buf), "# 9. Palindrome Number")
    vim.cmd("Lc show 0070-climbing-stairs")
    H.eq(#wins(), 2)
    H.has(H.lines(vim.api.nvim_win_get_buf(statement_win())), "# 70. Climbing Stairs")
    -- From the statement buffer, the commands know the problem.
    vim.api.nvim_set_current_win(statement_win())
    vim.cmd("Lc start")
    H.ok(vim.api.nvim_buf_get_name(0):match("/0070%-climbing%-stairs/solution%.cpp$"))
end)

test("show without a problem", function()
    vim.cmd("Lc show")
    H.has(H.note("name a problem").msg, ":Lc show 1")
end)

return tests
