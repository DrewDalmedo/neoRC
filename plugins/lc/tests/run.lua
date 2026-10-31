-- lua/neo/plugins/lc/tests/run.lua
-- :Lc test, :Lc submit and :Lc cancel: verdicts, the result buffer,
-- diagnostics, quickfix, and adding cases.

local H = require("neo.plugins.lc.tests.helpers")
local tests = {}
local function test(name, fn)
    tests[#tests + 1] = { name, fn }
end

local function result()
    return H.lines(H.result_buf())
end

local function qf()
    return vim.fn.getqflist({ title = 0, items = 0, nr = 0, context = 0 })
end

test("an accepted solution", function()
    local sol = H.start(1, "cpp", "two-sum/ok.cpp")
    local data = H.run("Lc test")
    H.eq(data.kind, "test")
    H.eq(data.verdict, "accepted")
    H.eq(data.passed, data.total)
    H.eq(data.problem.id, 1)
    H.eq(vim.fn.resolve(data.solution), vim.fn.resolve(sol))
    local lines = result()
    H.eq(lines[1], "lc test · 1. Two Sum · solution.cpp (C++, c++11)")
    H.ok(lines[2]:match("^Accepted: 3/3 cases passed, slowest %d+ ms, peak memory [%d.]+ MB$"), lines[2])
    H.has(lines, "  Example 1  Accepted")
    H.has(lines, "  Example 3  Accepted")
    H.eq(H.diagnostics(sol), {})
    H.note("1. Two Sum: Accepted, 3/3 cases")
    -- An accepted run with nothing to list adds no quickfix list.
    H.eq(qf().nr, 0)
    H.eq(require("neo.plugins.lc").status(), "")
end)

test("a C solution", function()
    H.start(1, "c", "two-sum/ok.c")
    local data = H.run("Lc test")
    H.eq(data.verdict, "accepted")
    H.eq(result()[1], "lc test · 1. Two Sum · solution.c (C, c11)")
end)

test("compile errors become diagnostics and quickfix entries", function()
    local sol = H.start(1, "cpp", "two-sum/compile_error.cpp")
    local data = H.run("Lc test")
    H.eq(data.verdict, "compile_error")
    local d = H.diagnostics(sol)
    H.ok(#d >= 1, "no diagnostics")
    H.eq(d[1].lnum, 3)
    H.eq(d[1].severity, vim.diagnostic.severity.ERROR)
    H.has(d[1].message, "undefined_thing")
    H.eq(d[1].source, "lc")
    local list = qf()
    H.eq(list.title, "lc test: 1. Two Sum")
    local item = list.items[1]
    H.eq(vim.fn.resolve(vim.api.nvim_buf_get_name(item.bufnr)), vim.fn.resolve(sol))
    H.eq(item.lnum, 4)
    H.eq(item.type, "E")
    local lines = result()
    H.eq(lines[2], "Compile Error")
    H.has(lines, "Compiler output:")
    H.has(lines, "  solution.cpp:4:")
    H.has(lines, "This was built as C++11.")
    H.eq(H.note("Compile Error").level, vim.log.levels.ERROR)

    -- <CR> on the error goes there.
    H.cursor_on("solution.cpp:4:")
    H.keys("<CR>")
    H.eq(vim.fn.resolve(vim.api.nvim_buf_get_name(0)), vim.fn.resolve(sol))
    H.eq(vim.api.nvim_win_get_cursor(0)[1], 4)
end)

test("each run replaces its own quickfix list and leaves yours", function()
    H.start(1, "cpp", "two-sum/compile_error.cpp")
    H.run("Lc test")
    H.run("Lc test")
    H.eq(qf().nr, 1)
    H.eq(#qf().items > 0, true)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(H.fixture("two-sum/ok.cpp"), "\n"))
    H.run("Lc test") -- written by autowrite
    H.eq(qf().nr, 1)
    H.eq(qf().items, {})
    H.eq(vim.bo.modified, false)
    vim.fn.setqflist({}, " ", { title = "mine", items = { { filename = "x", lnum = 1, text = "mine" } } })
    H.run("Lc test")
    H.eq(qf().title, "mine")
end)

test("a wrong answer, and adding the case to cases.txt", function()
    local sol = H.start(1, "cpp", "two-sum/wrong.cpp")
    local cases = vim.fs.dirname(sol) .. "/cases.txt"
    local data = H.run("Lc test")
    H.eq(data.verdict, "wrong_answer")
    H.eq(data.passed, 0)
    local lines = result()
    H.eq(lines[2], "Wrong Answer: 0/3 cases passed")
    H.has(lines, "Wrong Answer on example 1")
    H.has(lines, "  Input:    nums = [5,2,7,9], target = 11")
    H.has(lines, "  Output:   [0,0]")
    H.has(lines, "  Expected: [1,3]")
    H.has(lines, "  Stdout:\n    looking at 4 numbers")
    H.has(H.note("Wrong Answer on example 1").msg, "0/3 cases passed")
    local list = qf()
    H.eq(#list.items, 3)
    H.eq(list.items[1].text, "Wrong Answer on example 1")
    H.eq(list.items[1].lnum, 1)

    -- a on example 2's details adds it.
    H.cursor_on("  Input:    nums = [6,1,6]")
    H.keys("a")
    H.note("added example 2")
    local text = H.read(cases)
    H.ok(text:sub(-62) == "\n\n# From lc test: example 2, Wrong Answer\n[6,1,6]\n12\n=> [0,2]\n", text)

    -- The next run has it, as one of your cases.
    data = H.run("Lc test")
    H.eq(data.total, 4)
    lines = result()
    H.has(lines, "Wrong Answer on your case at cases.txt:")
    H.has(lines, "  cases.txt:")
    list = qf()
    H.eq(vim.fn.resolve(vim.api.nvim_buf_get_name(list.items[4].bufnr)), vim.fn.resolve(cases))

    -- It is yours already; <CR> goes to it.
    H.cursor_on("  cases.txt:")
    H.keys("a")
    H.note("is one of your cases already")
    H.cursor_on("  cases.txt:")
    H.keys("<CR>")
    H.eq(vim.fn.resolve(vim.api.nvim_buf_get_name(0)), vim.fn.resolve(cases))
    H.eq(vim.api.nvim_get_current_line(), "[6,1,6]")
end)

test("adding a case to a loaded cases.txt", function()
    local sol = H.start(1, "cpp", "two-sum/wrong.cpp")
    local cases = vim.fs.dirname(sol) .. "/cases.txt"
    vim.cmd("split " .. vim.fn.fnameescape(cases))
    local buf = vim.api.nvim_get_current_buf()
    vim.cmd("wincmd p")
    H.run("Lc test " .. vim.fn.fnameescape(sol))
    vim.api.nvim_set_current_win(H.result_win())
    -- Not on a case: the only failure is needed, and there are three.
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    H.keys("a")
    H.note("put the cursor on a case")
    H.cursor_on("Wrong Answer on example 3")
    H.keys("a")
    H.eq(vim.bo[buf].modified, false)
    local want = { "# From lc test: example 3, Wrong Answer", "[-3,8]", "5", "=> [0,1]" }
    local lines = H.lines(buf)
    H.eq(vim.list_slice(lines, #lines - 3), want)
    H.eq(lines[#lines - 4], "")
    H.has(H.read(cases), table.concat(want, "\n") .. "\n")
end)

test("a problem by number, from another problem's directory", function()
    local nine = H.start(9, "cpp", table.concat({
        "class Solution {",
        "public:",
        "    bool isPalindrome(int x) { return false; }",
        "};",
    }, "\n"))
    H.start(1, "cpp")
    local one = H.read(H.workspace .. "/0001-two-sum/cases.txt")
    vim.cmd("cd " .. vim.fn.fnameescape(H.workspace .. "/0001-two-sum"))
    vim.cmd("enew")
    local data = H.run("Lc test 9")
    H.eq(data.problem.id, 9)
    H.has(result()[1], "lc test · 9. Palindrome Number · solution.cpp")
    H.eq(data.verdict, "wrong_answer")
    vim.api.nvim_set_current_win(H.result_win())
    H.cursor_on("Wrong Answer on example")
    H.keys("a")
    H.has(H.read(vim.fs.dirname(nine) .. "/cases.txt"), "# From lc test: example")
    H.eq(H.read(H.workspace .. "/0001-two-sum/cases.txt"), one)
end)

test("autowrite when the problem is named by number", function()
    H.start(1, "cpp")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(H.fixture("two-sum/ok.cpp"), "\n"))
    vim.cmd("enew")
    local data = H.run("Lc test 1")
    H.eq(data.verdict, "accepted")
    H.eq(vim.bo[buf].modified, false)
    -- From the statement of :Lc show, which knows only the ID.
    vim.cmd("buffer " .. buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(H.fixture("two-sum/wrong.cpp"), "\n"))
    vim.cmd("Lc show")
    vim.cmd("wincmd h")
    H.eq(vim.api.nvim_buf_get_name(0), "lc://problem/0001-two-sum")
    data = H.run("Lc test")
    H.eq(data.verdict, "wrong_answer")
    H.eq(vim.bo[buf].modified, false)
end)

test("a result option that fails doesn't stop the run", function()
    H.start(1, "cpp", "two-sum/ok.cpp")
    require("neo.plugins.lc").setup({ cmd = H.lc, result = "botright 15splt" })
    local data = H.run("Lc test")
    H.eq(data.verdict, "accepted")
    H.note("couldn't open the result window")
    H.eq(require("neo.plugins.lc").status(), "")
    require("neo.plugins.lc").setup({ cmd = H.lc })
    data = H.run("Lc test")
    H.eq(data.verdict, "accepted")
    H.has(result(), "Accepted: 3/3")
end)

test("<CR> on an error with unsaved changes", function()
    local sol = H.start(1, "cpp", "two-sum/compile_error.cpp")
    H.run("Lc test")
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { "// unsaved" })
    H.cursor_on("solution.cpp:4:")
    H.keys("<CR>")
    H.eq(H.notes[#H.notes].msg:find("E37", 1, true), nil)
    H.eq(vim.fn.resolve(vim.api.nvim_buf_get_name(0)), vim.fn.resolve(sol))
    H.eq(vim.api.nvim_win_get_cursor(0)[1], 4)
    H.eq(vim.bo.modified, true)
end)

test(":Lc result draws the result again", function()
    H.start(1, "cpp", "two-sum/wrong.cpp")
    H.run("Lc test")
    local n = #result()
    for _, cmd in ipairs({ "bwipeout", "bdelete", "bunload" }) do
        vim.api.nvim_set_current_win(H.result_win())
        vim.cmd(cmd)
        vim.cmd("Lc result")
        H.eq(#result(), n, cmd)
        H.eq(vim.b[H.result_buf()].lc_problem.id, 1, cmd)
    end
end)

test("the cursor stays on its case as the result grows", function()
    H.start(1, "cpp", "two-sum/wrong.cpp")
    H.run("Lc test")
    H.cursor_on("Wrong Answer on example 2")
    -- One more case comes in: a line goes in above the details.
    local run = require("neo.plugins.lc.run").last
    local extra = vim.deepcopy(run.cases[1])
    extra.index, extra.custom, extra.example, extra.label = 3, true, false, "cases.txt:30"
    table.insert(run.cases, extra)
    require("neo.plugins.lc.run").redraw()
    H.eq(vim.api.nvim_get_current_line(), "Wrong Answer on example 2")
end)

test("diagnostics reach a solution opened after the run", function()
    local sol = H.start(1, "cpp", "two-sum/compile_error.cpp")
    vim.cmd("bwipeout " .. vim.fn.bufnr(sol))
    vim.cmd("enew")
    H.run("Lc test 1")
    vim.cmd("edit " .. vim.fn.fnameescape(sol))
    H.wait(function()
        return #H.diagnostics(sol) > 0
    end, "the diagnostics")
    H.eq(H.diagnostics(sol)[1].lnum, 3)
end)

test("an error that names a line of cases.txt", function()
    local sol = H.start(1, "cpp", "two-sum/ok.cpp")
    local cases = vim.fs.dirname(sol) .. "/cases.txt"
    H.write(cases, "[1,2]\n=> [0,1]\n")
    local data = H.run("Lc test")
    H.eq(data.verdict, "error")
    local item = qf().items[1]
    H.eq(vim.fn.resolve(vim.api.nvim_buf_get_name(item.bufnr)), vim.fn.resolve(cases))
    -- lc names the case's first line.
    H.eq(item.lnum, 1)
    H.has(item.text, "case has 1 input")
    H.cursor_on("Error: ")
    H.keys("<CR>")
    H.eq(vim.fn.resolve(vim.api.nvim_buf_get_name(0)), vim.fn.resolve(cases))
    H.eq(vim.api.nvim_get_current_line(), "[1,2]")
end)

test("a case without inputs is added as ()", function()
    local file = H.tmp .. "/noinput-" .. H.n .. "/cases.txt"
    H.write(file, "# mine")
    require("neo.plugins.lc.run").last = {
        kind = "test",
        cases = { { verdict = "wrong_answer", index = 0, example = true, inputs = {}, expected = "42" } },
        cases_file = file,
        diags = {},
        flags = {},
    }
    require("neo.plugins.lc").add_case()
    H.eq(H.read(file), "# mine\n\n# From lc test: example 1, Wrong Answer\n()\n=> 42\n")
end)

test("adding a case to a cases.txt buffer that can't take it", function()
    local sol = H.start(1, "cpp", "two-sum/wrong.cpp")
    local cases = vim.fs.dirname(sol) .. "/cases.txt"
    local before = H.read(cases)
    vim.cmd("split " .. vim.fn.fnameescape(cases))
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].readonly = true
    vim.cmd("wincmd p")
    H.run("Lc test " .. vim.fn.fnameescape(sol))
    H.cursor_on("Wrong Answer on example 2")
    H.keys("a")
    H.has(H.note("couldn't add the case").msg, "read-only")
    H.eq(H.read(cases), before)
    -- With changes of yours, it goes into the buffer, unsaved.
    vim.bo[buf].readonly = false
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "# my change" })
    H.cursor_on("Wrong Answer on example 2")
    H.keys("a")
    H.note("which has unsaved changes")
    H.eq(vim.bo[buf].modified, true)
    H.has(H.lines(buf), "=> [0,2]")
    H.eq(H.read(cases), before)
end)

test("--case with ~, and r after :cd", function()
    H.start(1, "cpp", "two-sum/ok.cpp")
    local home = vim.env.HOME
    vim.env.HOME = H.tmp .. "/home-" .. H.n
    H.write(vim.env.HOME .. "/mine.txt", "[1,2]\n3\n=> [0,1]\n")
    local data = H.run("Lc test --case ~/mine.txt")
    vim.env.HOME = home
    H.eq(data.verdict, "accepted")
    H.has(result(), "  mine.txt:1 ")
    vim.cmd("cd /")
    vim.api.nvim_set_current_win(H.result_win())
    data = H.run("normal r")
    H.eq(data.verdict, "accepted")
    H.has(result(), "  mine.txt:1 ")
end)

test("autowrite by number leaves other files alone", function()
    H.start(1, "cpp", "two-sum/ok.cpp")
    local base = H.tmp .. "/elsewhere-" .. H.n
    -- Not a file lc reads, and directories lc wouldn't take for 0001.
    local others = {
        base .. "/0001-two-sum/tests.txt",
        base .. "/two-sum/solution.cpp",
        base .. "/1/cases.txt",
    }
    for _, f in ipairs(others) do
        H.write(f, "# original\n")
        vim.cmd("edit " .. vim.fn.fnameescape(f))
        vim.api.nvim_buf_set_lines(0, -1, -1, false, { "half-finished" })
    end
    local data = H.run("Lc test 1")
    H.eq(data.verdict, "accepted")
    for _, f in ipairs(others) do
        H.eq(H.read(f), "# original\n", f)
    end
end)

test("autowrite by number in a workspace directory that is a link", function()
    local sols = H.tmp .. "/sols-" .. H.n .. "/two-sum"
    vim.fn.mkdir(sols, "p")
    vim.fn.mkdir(H.workspace, "p")
    vim.uv.fs_symlink(sols, H.workspace .. "/0001-two-sum")
    vim.cmd("Lc start 1")
    -- Neovim names the buffer by the link's target.
    H.ok(vim.api.nvim_buf_get_name(0):find("/two-sum/solution.cpp", 1, true), vim.api.nvim_buf_get_name(0))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(H.fixture("two-sum/ok.cpp"), "\n"))
    vim.cmd("enew")
    local data = H.run("Lc test 1")
    H.eq(data.verdict, "accepted")
    -- And the buffer knows its problem: :Lc test from it works too.
    vim.cmd("buffer #")
    H.eq(H.run("Lc test").verdict, "accepted")
end)

test("LcRunStart sees the run", function()
    H.start(1, "cpp", "two-sum/ok.cpp")
    local status
    vim.api.nvim_create_autocmd("User", {
        pattern = "LcRunStart",
        once = true,
        callback = function()
            status = require("neo.plugins.lc").status()
        end,
    })
    H.run("Lc test")
    H.eq(status, "lc test: building")
end)

test("quitting Neovim during a run", function()
    -- In a Neovim of its own: start a run that spins, then :qa!.
    local dir = H.tmp .. "/quit-" .. H.n
    local marker = dir .. "/done-fired"
    local script = dir .. "/quit.lua"
    H.write(script, table.concat({
        ("vim.opt.rtp:prepend(%q)"):format(H.rtp),
        'package.loaded["neo.overrides"] = {}',
        ("require('neo.plugins.lc').setup({ cmd = %q })"):format(H.lc),
        "vim.notify = function() end",
        'vim.cmd("Lc start 1")',
        ("vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(%q, '\\n'))"):format(H.fixture("two-sum/loop.cpp")),
        'vim.cmd("silent write")',
        ("vim.api.nvim_create_autocmd('User', { pattern = 'LcRunDone', callback = function() io.open(%q, 'w'):close() end })"):format(marker),
        'vim.cmd("Lc submit")',
        "vim.wait(60000, function() return require('neo.plugins.lc.run').current and require('neo.plugins.lc.run').current.running ~= nil end, 20)",
        'vim.cmd("qa!")',
    }, "\n"))
    local r = vim.system({ vim.v.progpath, "--headless", "--clean", "-l", script }, {
        env = { LC_WORKSPACE = dir .. "/ws", XDG_DATA_HOME = dir .. "/data" },
        text = true,
    }):wait(120000)
    H.eq(r.code, 0, r.stderr)
    H.eq(vim.uv.fs_stat(marker), nil, "LcRunDone fired while Neovim quit")
end)

test("submit records the problem", function()
    H.start(1, "cpp", "two-sum/ok.cpp")
    local data = H.run("Lc submit")
    H.eq(data.kind, "submit")
    H.eq(data.verdict, "accepted")
    H.ok(data.total > 3, "submit should run the hidden cases too")
    local lines = result()
    H.ok(lines[2]:match("· solved for the first time$"), lines[2])
    H.hasnt(lines, "  Case 1 ")
    H.has(H.note("Solved!").msg, "Accepted")

    -- :Lc stats takes the result's window.
    local panel = H.result_win()
    vim.cmd("Lc stats")
    local stats = vim.api.nvim_win_get_buf(panel)
    H.eq(vim.api.nvim_buf_get_name(stats), "lc://stats")
    H.has(H.lines(stats), "Solved 1 of")
    H.has(H.lines(stats), "Easy                          1         0")

    local items
    vim.ui.select = function(list, _, _)
        items = list
    end
    vim.cmd("Lc list --status solved")
    H.eq(#items, 1)
    H.eq(items[1].slug, "two-sum")
end)

test("submit stops at the first failure", function()
    H.start(1, "cpp", "two-sum/wrong.cpp")
    local data = H.run("Lc submit")
    H.eq(data.verdict, "wrong_answer")
    local lines = result()
    H.ok(lines[2]:match("^Wrong Answer: 0/%d+ cases passed · status: attempted$"), lines[2])
    H.has(lines, "Wrong Answer on case 1 of ")
    -- In the details, a moves the only failure without the cursor on it.
    vim.api.nvim_set_current_win(H.result_win())
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    H.keys("a")
    H.note("added case 1")
end)

test("cancel, and the statusline", function()
    H.start(1, "cpp", "two-sum/loop.cpp")
    local data
    vim.api.nvim_create_autocmd("User", {
        pattern = "LcRunDone",
        once = true,
        callback = function(ev)
            data = ev.data
        end,
    })
    vim.cmd("Lc submit")
    H.wait(function()
        return require("neo.plugins.lc.run").current and require("neo.plugins.lc.run").current.running ~= nil
    end, "a case to start")
    H.ok(require("neo.plugins.lc").status():match("^lc submit: 1/%d+$"), require("neo.plugins.lc").status())
    vim.cmd("Lc cancel")
    H.has(result(), "Cancelling…")
    H.wait(function()
        return data ~= nil
    end, "the run to stop")
    H.eq(data.verdict, "none")
    H.eq(data.cancelled, true)
    H.ok(result()[2]:match("^Cancelled after 0 of %d+ cases$"), result()[2])
    H.note("1. Two Sum: cancelled")
    H.eq(require("neo.plugins.lc").status(), "")
    vim.cmd("Lc cancel")
    H.note("nothing is running")
end)

test("cancel twice kills lc", function()
    H.start(1, "cpp", "two-sum/loop.cpp")
    local data
    vim.api.nvim_create_autocmd("User", {
        pattern = "LcRunDone",
        once = true,
        callback = function(ev)
            data = ev.data
        end,
    })
    vim.cmd("Lc submit")
    H.wait(function()
        return require("neo.plugins.lc.run").current and require("neo.plugins.lc.run").current.running ~= nil
    end, "a case to start")
    vim.cmd("Lc cancel")
    vim.cmd("Lc cancel")
    H.wait(function()
        return data ~= nil
    end, "the run to stop")
    H.eq(data.verdict, "none")
    H.eq(data.cancelled, true)
    H.ok(result()[2]:match("^Cancelled after 0"), result()[2])
    H.note("1. Two Sum: cancelled")
end)

test("a new run replaces the one going on", function()
    local sol = H.start(1, "cpp", "two-sum/loop.cpp")
    local done = {}
    vim.api.nvim_create_autocmd("User", {
        pattern = "LcRunDone",
        callback = function(ev)
            done[#done + 1] = ev.data
        end,
    })
    vim.cmd("Lc submit")
    H.wait(function()
        return require("neo.plugins.lc.run").current.running ~= nil
    end, "a case to start")
    local first = require("neo.plugins.lc.run").current
    H.write(sol, H.fixture("two-sum/ok.cpp"))
    vim.cmd("checktime")
    H.run("Lc test")
    H.wait(function()
        return first.finished
    end, "the first run to stop")
    H.eq(#done, 1)
    H.eq(done[1].kind, "test")
    H.eq(done[1].verdict, "accepted")
    H.has(result(), "Accepted: 3/3")
end)

test("sanitizer reports become diagnostics", function()
    local sol = H.start(1, "cpp", "two-sum/overflow.cpp")
    local data = H.run("Lc test --sanitize")
    H.eq(data.verdict, "runtime_error")
    H.has(result()[1], ", sanitizers)")
    local found = vim.tbl_filter(function(d)
        return d.message:find("signed integer overflow", 1, true) ~= nil
    end, H.diagnostics(sol))
    H.eq(#found, 1, "one diagnostic for the cases with the same report")
    found = found[1]
    H.ok(found, "no diagnostic for the overflow: " .. vim.inspect(H.diagnostics(sol)))
    H.eq(found.lnum, 4)
    H.eq(found.severity, vim.diagnostic.severity.ERROR)
    H.has(found.message, "(Example 1)")
    local items = vim.tbl_filter(function(i)
        return i.text:find("signed integer overflow", 1, true) ~= nil
    end, qf().items)
    H.eq(#items, 1, "one quickfix entry for the cases with the same report")
    H.eq(items[1].lnum, 5)
end)

test(":Lc std for the session", function()
    H.start(1, "cpp", "two-sum/ok.cpp")
    vim.cmd("Lc std c++17")
    H.has(H.note("C++: c++17 (this session)").msg, "C: lc's setting")
    H.run("Lc test")
    H.has(result()[1], "(C++, c++17)")
    H.run("Lc test --std c++14")
    H.has(result()[1], "(C++, c++14)")
    vim.cmd("Lc std default")
    H.run("Lc test")
    H.has(result()[1], "(C++, c++11)")
    vim.cmd("Lc std c99")
    H.eq(require("neo.plugins.lc.cli").std.c, "c99")
    vim.cmd("Lc std cpp max")
    H.eq(require("neo.plugins.lc.cli").std.cpp, "max")
    vim.cmd("Lc std c++99")
    H.note("unknown standard 'c++99'")
    vim.cmd("Lc std rust 1")
    H.note("unknown language 'rust'")
end)

test("test from the README tests the solution beside it", function()
    H.start(1, "cpp", "two-sum/ok.cpp")
    vim.cmd("wincmd h")
    H.ok(vim.api.nvim_buf_get_name(0):match("README%.md$"))
    local data = H.run("Lc test")
    H.eq(data.verdict, "accepted")
    H.has(result()[1], "solution.cpp")
end)

test("test by problem number, and r runs again", function()
    H.start(1, "cpp", "two-sum/ok.cpp")
    vim.cmd("enew")
    local data = H.run("Lc test 1")
    H.eq(data.verdict, "accepted")
    vim.api.nvim_set_current_win(H.result_win())
    data = H.run("normal r")
    H.eq(data.verdict, "accepted")
end)

test("outside a problem", function()
    vim.cmd("enew")
    vim.cmd("Lc test")
    H.has(H.note("isn't a solution").msg, ":Lc test 1")
    vim.cmd("Lc result")
    H.note("nothing has run yet")
end)

test("lc's own errors", function()
    H.start(1, "cpp")
    vim.cmd("Lc start 1 c")
    -- The directory has solution.c and solution.cpp.
    local data = H.run("Lc test " .. vim.fn.fnameescape(H.workspace .. "/0001-two-sum"))
    H.eq(data.verdict, "error")
    H.has(result()[2], "Error: ")
    H.has(result()[2], "--lang")
    H.eq(H.note("--lang").level, vim.log.levels.ERROR)
end)

test("a cmd that isn't there", function()
    -- (setup() would turn lc off: this is lc gone from PATH since.)
    require("neo.plugins.lc.config").setup({ cmd = "/nonexistent/lc" })
    vim.cmd("Lc list")
    H.note("can't run /nonexistent/lc")
    local starts = 0
    vim.api.nvim_create_autocmd("User", {
        pattern = "LcRunStart",
        callback = function()
            starts = starts + 1
        end,
    })
    local data = H.run("Lc test 1")
    H.eq(starts, 1, "LcRunStart comes before every LcRunDone")
    H.eq(data.verdict, "error")
    H.has(data.error, "can't run /nonexistent/lc")
end)

return tests
