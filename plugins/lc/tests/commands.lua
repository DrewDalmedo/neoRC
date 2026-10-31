-- lua/neo/plugins/lc/tests/commands.lua
-- :Lc's subcommands and completion, the pickers, :checkhealth neo.plugins.lc.

local H = require("neo.plugins.lc.tests.helpers")
local tests = {}
local function test(name, fn)
    tests[#tests + 1] = { name, fn }
end

local function complete(line)
    return vim.fn.getcompletion(line, "cmdline")
end

test("completion", function()
    H.eq(complete("Lc "), { "cancel", "list", "random", "result", "show", "start", "stats", "std", "submit", "test" })
    H.eq(complete("Lc s"), { "show", "start", "stats", "std", "submit" })
    local two = complete("Lc show two")
    H.ok(vim.tbl_contains(two, "two-sum"), vim.inspect(two))
    for _, slug in ipairs(two) do
        H.ok(slug:sub(1, 3) == "two", slug)
    end
    local twelve = complete("Lc show 12")
    H.ok(vim.tbl_contains(twelve, "121"), vim.inspect(twelve))
    for _, id in ipairs(twelve) do
        H.ok(id:sub(1, 2) == "12", id)
    end
    H.eq(complete("Lc show 1 "), {})
    H.eq(complete("Lc start 1 "), { "c", "cpp" })
    H.eq(complete("Lc start 1 --lang c"), { "c", "cpp" })
    H.eq(complete("Lc list --"), { "--difficulty", "--status", "--tag" })
    H.eq(complete("Lc list --difficulty easy,me"), { "easy,medium" })
    H.eq(complete("Lc random --status "), { "todo", "attempted", "solved" })
    local hash = complete("Lc list --tag hash")
    H.ok(vim.tbl_contains(hash, "hash-table"), vim.inspect(hash))
    H.ok(vim.tbl_contains(complete("Lc show 000"), "0001"))
    H.eq(complete("Lc show 0001-"), { "0001-two-sum" })
    H.eq(complete("Lc list --difficulty easy,"), { "easy,medium", "easy,hard" })
    H.eq(complete("Lc list --status=sol"), { "--status=solved" })
    H.eq(complete("Lc test --std=c++1"), { "--std=c++11", "--std=c++14", "--std=c++17" })
    H.eq(complete("Lc start --lang="), { "--lang=c", "--lang=cpp" })
    H.eq(complete("Lc std c++ c++2"), { "c++20", "c++23" })
    H.eq(complete("Lc test --std c++1"), { "c++11", "c++14", "c++17" })
    H.eq(complete("Lc test --s"), { "--std", "--sanitize" })
    H.eq(complete("Lc submit --"), { "--lang", "--std", "--sanitize" })
    H.eq(complete("Lc test --lang "), { "c", "cpp" })
    H.eq(complete("Lc std c "), { "c99", "c11", "c17", "c23", "max", "default" })
    H.eq(complete("Lc std d"), { "default" })
    H.eq(complete("Lc std cpp c++2"), { "c++20", "c++23" })
    H.eq(complete("Lc nope "), {})
    -- After a modifier or a bang.
    H.ok(vim.tbl_contains(complete("tab Lc show two"), "two-sum"))
    H.eq(complete("silent! Lc st"), { "start", "stats", "std" })
    H.eq(complete("vertical Lc "), complete("Lc "))
    -- After a |, the second command.
    H.eq(complete("Lc show 9 | Lc st"), { "start", "stats", "std" })
end)

test("file names with spaces complete escaped", function()
    local dir = H.tmp .. "/completion"
    vim.fn.mkdir(dir, "p")
    H.write(dir .. "/my cases.txt", "")
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    H.eq(complete("Lc test --case my"), { [[my\ cases.txt]] })
    H.eq(complete([[Lc test --case my\ c]]), { [[my\ cases.txt]] })
    -- | would end the command (:Lc takes a bar), " would start a comment.
    H.write(dir .. "/a|b.txt", "")
    H.write(dir .. '/q"x.txt', "")
    H.eq(complete("Lc test --case a"), { [[a\|b.txt]] })
    H.eq(complete("Lc test --case q"), { [[q\"x.txt]] })
end)

test(":Lc takes a | and another command", function()
    vim.g.lc_after = nil
    vim.cmd("Lc show 9 | let g:lc_after = 1")
    H.eq(vim.g.lc_after, 1)
    H.no_errors()
end)

test("an unknown command", function()
    vim.cmd("Lc nope")
    H.has(H.note("unknown command 'nope'").msg, "test")
end)

test("the select picker starts the chosen problem", function()
    local items, opts
    vim.ui.select = function(list, o, on_choice)
        items, opts = list, o
        for _, p in ipairs(list) do
            if p.id == 9 then
                on_choice(p)
            end
        end
    end
    vim.cmd("Lc")
    H.ok(#items >= 10, "too few problems")
    H.eq(opts.prompt, "Problems")
    H.eq(opts.format_item(items[1]), "1     Easy          Two Sum  (array, hash-table)")
    H.ok(vim.api.nvim_buf_get_name(0):match("/0009%-palindrome%-number/solution%.cpp$"), vim.api.nvim_buf_get_name(0))
end)

test("list filters, and nothing to pick", function()
    local items
    vim.ui.select = function(list)
        items = list
    end
    vim.cmd("Lc list --difficulty easy --tag string")
    H.ok(#items > 0)
    for _, p in ipairs(items) do
        H.ok(vim.tbl_contains(p.tags, "string"), p.slug)
    end
    items = nil
    vim.cmd("Lc list --tag no-such-tag")
    H.eq(items, nil)
    H.note("no problem matches")
    vim.cmd("Lc list --difficulty nope")
    H.eq(H.note("nope").level, vim.log.levels.ERROR)
end)

test("random, with open = show", function()
    require("neo.plugins.lc").setup({ cmd = H.lc, open = "show" })
    vim.cmd("Lc random --tag bit-manipulation")
    local name
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.w[w].lc_statement then
            name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
        end
    end
    local id = tonumber(H.ok(name and name:match("^lc://problem/(%d+)%-"), tostring(name)))
    local p = require("neo.plugins.lc.catalog").find(id)
    H.ok(vim.tbl_contains(p.tags, "bit-manipulation"), name)
end)

-- The <CR> of neo's picker, as the prompt buffer maps it.
local function picker_enter(p)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(p.ui.prompt_buf, "n")) do
        if m.lhs == "<CR>" then
            return m.callback()
        end
    end
    error("the picker's prompt maps no <CR>")
end

test("the neo picker starts the chosen problem", function()
    require("neo.plugins.lc").setup({ cmd = H.lc, picker = "neo" })
    local before = vim.api.nvim_get_current_win()
    vim.cmd("Lc list")
    local p = H.ok(require("neo.plugins.picker").current(), "no picker open")
    H.ok(p:count() >= 10, "too few problems")
    H.eq(p.items[1].display, "1     Easy          Two Sum  (array, hash-table)")
    -- The prompt matches anything on the line: here the title.
    vim.api.nvim_buf_set_lines(p.ui.prompt_buf, 0, -1, false, { "palindrome" })
    p:refresh()
    H.eq(p.filtered[p.selected].problem.id, 9)
    picker_enter(p)
    H.eq(require("neo.plugins.picker").current(), nil)
    H.ok(vim.api.nvim_buf_get_name(0):match("/0009%-palindrome%-number/solution%.cpp$"), vim.api.nvim_buf_get_name(0))
    H.eq(vim.api.nvim_get_current_win(), before)
end)

test("the neo picker closed without a choice", function()
    require("neo.plugins.lc").setup({ cmd = H.lc, picker = "neo" })
    local buf = vim.api.nvim_get_current_buf()
    vim.cmd("Lc list --tag no-such-tag")
    H.eq(require("neo.plugins.picker").current(), nil)
    H.note("no problem matches")
    vim.cmd("Lc list")
    require("neo.plugins.picker").current():close()
    H.eq(vim.api.nvim_get_current_buf(), buf)
    H.no_errors()
end)

test("a slug that starts with digits completes", function()
    local list = [[{"schema":1,"problems":[{"id":717,"slug":"1-bit-and-2-bit-characters","title":"1-bit and 2-bit Characters","difficulty":"easy","tags":[]}],"warnings":[]}]]
    require("neo.plugins.lc").setup({ cmd = H.fake_lc(("echo '%s'"):format(list)) })
    H.eq(complete("Lc show 1-"), { "1-bit-and-2-bit-characters" })
    H.eq(complete("Lc show 07"), { "0717" })
end)

test("lc killed by a signal", function()
    require("neo.plugins.lc").setup({ cmd = H.fake_lc("kill -9 $$") })
    vim.cmd("Lc list")
    H.note("lc was killed by signal 9")
    local data = H.run("Lc test 1")
    H.eq(data.verdict, "error")
    H.eq(data.error, "lc was killed by signal 9")
    -- What it said before dying is kept.
    require("neo.plugins.lc").setup({ cmd = H.fake_lc("echo 'Assertion failed: (len < cap)' >&2; kill -ABRT $$") })
    data = H.run("Lc test 1")
    H.eq(data.error, "lc was killed by signal 6")
    H.has(H.lines(H.result_buf()), "Assertion failed: (len < cap)")
end)

test("the warnings of an error document are shown", function()
    local doc = [[{"schema":1,"error":{"message":"no problem matches x9"},"warnings":["p/0005-five/problem.md:1: skipped"]}]]
    require("neo.plugins.lc").setup({ cmd = H.fake_lc(("echo '%s'; exit 3"):format(doc)) })
    vim.cmd("Lc show x")
    H.eq(H.note("no problem matches x9").level, vim.log.levels.ERROR)
    H.eq(H.note("0005-five/problem.md:1: skipped").level, vim.log.levels.WARN)
    H.notes = {}
    local data = H.run("Lc test 1")
    H.eq(data.error, "no problem matches x9")
    H.note("0005-five/problem.md:1: skipped")
end)

test("another schema", function()
    require("neo.plugins.lc").setup({ cmd = H.fake_lc([[echo '{"schema":2,"problems":[]}']]) })
    vim.cmd("Lc list")
    H.has(H.note("JSON schema 2").msg, "the lc plugin reads schema 1")
end)

test(":checkhealth neo.plugins.lc", function()
    vim.cmd("checkhealth neo.plugins.lc")
    local text = table.concat(H.lines(0), "\n")
    H.has(text, "Picker: select")
    H.has(text, "JSON schema 1")
    H.has(text, "problems")
    H.hasnt(text, "ERROR")
end)

test("the statusline", function()
    H.eq(require("neo.plugins.lc").status(), "")
end)

return tests
