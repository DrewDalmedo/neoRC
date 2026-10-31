-- lua/neo/plugins/lc/tests/unit.lua
-- The parts that need no lc: paths, markdown, sanitizer reports, options,
-- and when setup() loads at all. (The two that ask lc for its problems
-- skip without it.)

local H = require("neo.plugins.lc.tests.helpers")
local tests = {}
local function test(name, fn)
    tests[#tests + 1] = { name, fn }
end

local function needs_lc()
    if not H.lc then
        H.skip("needs lc and its problems")
    end
end

test("problem directory names", function()
    local problem = require("neo.plugins.lc.problem")
    H.eq({ problem.parse_dirname("0001-two-sum") }, { 1, "two-sum" })
    H.eq({ problem.parse_dirname("10000-big-one") }, { 10000, "big-one" })
    H.eq(problem.parse_dirname("1-two-sum"), nil)
    H.eq(problem.parse_dirname("0001two-sum"), nil)
    H.eq(problem.parse_dirname("notes"), nil)
end)

test("solution languages", function()
    local problem = require("neo.plugins.lc.problem")
    H.eq(problem.lang_of("/a/solution.c"), "c")
    H.eq(problem.lang_of("/a/solution.cpp"), "cpp")
    H.eq(problem.lang_of("/a/x.cc"), "cpp")
    H.eq(problem.lang_of("/a/x.cxx"), "cpp")
    H.eq(problem.lang_of("/a/README.md"), nil)
end)

test("the problem of a path", function()
    local problem = require("neo.plugins.lc.problem")
    H.eq(problem.from_path("/nowhere/0001-two-sum/solution.cpp"), {
        id = 1,
        slug = "two-sum",
        dir = "/nowhere/0001-two-sum",
        solution = "/nowhere/0001-two-sum/solution.cpp",
        lang = "cpp",
    })
    H.eq(problem.from_path("/nowhere/0009-palindrome-number/cases.txt"), {
        id = 9,
        slug = "palindrome-number",
        dir = "/nowhere/0009-palindrome-number",
    })
    H.eq(problem.from_path("/nowhere/notes/solution.cpp"), nil)
    H.eq(problem.from_path(""), nil)
    local dir = H.tmp .. "/0070-climbing-stairs"
    vim.fn.mkdir(dir, "p")
    H.eq(problem.from_path(dir .. "/").dir, dir)
    H.eq(problem.from_path(dir).id, 70)
end)

test("statement markdown, examples where @examples is", function()
    local md = require("neo.plugins.lc.statement").markdown({
        id = 7,
        title = "Seven",
        difficulty = "easy",
        tags = { "math" },
        status = "solved",
        statement = "First.\n\n@examples\n\nLast.\n",
        blocks = { { type = "paragraph", line = 1 }, { type = "examples", line = 3 }, { type = "paragraph", line = 5 } },
        examples = {
            { inputs = { { name = "n", value = "3" } }, output = "6", explanation = "Twice." },
            { inputs = { { value = "1" }, { value = "2" } }, output = "0" },
        },
    })
    H.eq(md, {
        "# 7. Seven",
        "",
        "**Difficulty:** Easy · **Tags:** math · **Status:** Solved",
        "",
        "First.",
        "",
        "**Example 1:**",
        "",
        "```",
        "Input: n = 3",
        "Output: 6",
        "```",
        "",
        "**Explanation:** Twice.",
        "",
        "**Example 2:**",
        "",
        "```",
        "Input:",
        "1",
        "2",
        "Output: 0",
        "```",
        "",
        "Last.",
    })
end)

test("statement markdown without @examples", function()
    local md = require("neo.plugins.lc.statement").markdown({
        id = 8,
        title = "Eight",
        difficulty = "hard",
        tags = {},
        status = "todo",
        statement = "Only text.",
        blocks = { { type = "paragraph", line = 1 } },
        examples = { { inputs = { { name = "s", value = '"a"' } }, output = "1" } },
    })
    H.eq(md, {
        "# 8. Eight",
        "",
        "**Difficulty:** Hard",
        "",
        "Only text.",
        "",
        "**Example 1:**",
        "",
        "```",
        'Input: s = "a"',
        "Output: 1",
        "```",
    })
end)

test("AddressSanitizer reports", function()
    local src = "/ws/0001-two-sum/solution.cpp"
    local report = table.concat({
        "=================================================================",
        "==1234==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x602000000158 at pc 0x55d7 bp 0x7ffd sp 0x7ffd",
        "READ of size 4 at 0x602000000158 thread T0",
        "    #0 0x55d7c8 in Solution::twoSum(std::vector<int, std::allocator<int> >&, int) " .. src .. ":7:20",
        "    #1 0x55d7c9 in Solution::helper() " .. src .. ":12:9",
        "    #2 0x55d7ca in main lc_harness:120",
        "",
        "0x602000000158 is located 40 bytes after 8-byte region [0x602000000110,0x602000000118)",
        "allocated by thread T0 here:",
        "    #0 0x7f00 in operator new[](unsigned long) ../src/libsanitizer/asan/asan_new_delete.cpp:98",
        "    #1 0x55d7cb in Solution::twoSum(std::vector<int, std::allocator<int> >&, int) " .. src .. ":4",
        "",
        "SUMMARY: AddressSanitizer: heap-buffer-overflow " .. src .. ":7:20 in Solution::twoSum",
    }, "\n")
    local S = vim.diagnostic.severity
    H.eq(require("neo.plugins.lc.run").parse_sanitizer(report, src), {
        { lnum = 7, col = 20, severity = S.ERROR, message = "AddressSanitizer: heap-buffer-overflow" },
        { lnum = 12, col = 9, severity = S.INFO, message = "AddressSanitizer: heap-buffer-overflow: called from here" },
        {
            lnum = 4,
            col = 0,
            severity = S.INFO,
            message = "AddressSanitizer: heap-buffer-overflow: allocated by thread T0 here",
        },
    })
end)

test("AddressSanitizer reports symbolized by atos (macOS)", function()
    local src = "/ws/0001-two-sum/solution.cpp"
    local report = table.concat({
        "==61242==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x602000000148 at pc 0x1 bp 0x2 sp 0x3",
        "    #0 0x00010218574c in Solution::twoSum(std::__1::vector<int>&, int) solution.cpp:7",
        "    #1 0x000102184ef8 in main lc_harness:11",
        "    #0 0x0001 in other(int) not_solution.cpp:3",
    }, "\n")
    H.eq(require("neo.plugins.lc.run").parse_sanitizer(report, src), {
        { lnum = 7, col = 0, severity = vim.diagnostic.severity.ERROR, message = "AddressSanitizer: heap-buffer-overflow" },
    })
end)

test("UndefinedBehaviorSanitizer reports", function()
    local src = "/ws/0001-two-sum/solution.cpp"
    local report = src
        .. ":5:13: runtime error: signed integer overflow: 2147483647 + 5 cannot be represented in type 'int'\n"
        .. "SUMMARY: UndefinedBehaviorSanitizer: undefined-behavior "
        .. src
        .. ":5:13 \n"
    H.eq(require("neo.plugins.lc.run").parse_sanitizer(report, src), {
        {
            lnum = 5,
            col = 13,
            severity = vim.diagnostic.severity.ERROR,
            message = "runtime error: signed integer overflow: 2147483647 + 5 cannot be represented in type 'int'",
        },
    })
    H.eq(require("neo.plugins.lc.run").parse_sanitizer("nothing here\n", src), {})
end)

test("an error of several lines in the result", function()
    local lines = require("neo.plugins.lc.run").render_lines({
        kind = "test",
        title = "1. Two Sum",
        error = "the reference solution ref.c does not compile:\nref.c:3:1: error: oops\n",
        finished = true,
        cases = {},
        diags = {},
        flags = {},
    })
    for _, l in ipairs(lines) do
        H.ok(not l:find("\n"), vim.inspect(lines))
    end
    H.eq(lines[2], "Error: the reference solution ref.c does not compile:")
    H.has(lines, "ref.c:3:1: error: oops")
end)

test("arguments of :Lc test", function()
    local parse = require("neo.plugins.lc.run").parse_args
    H.eq({ parse({}) }, { nil, {} })
    H.eq({ parse({ "--std", "c++17", "1", "--sanitize" }) }, { "1", { "--std", "c++17", "--sanitize" } })
    local cwd = vim.fn.getcwd()
    H.eq({ parse({ "--case", "mine.txt", "--lang=c" }) }, { nil, { "--case", cwd .. "/mine.txt", "--lang=c" } })
    local home = vim.env.HOME
    vim.env.HOME = H.tmp
    H.write(H.tmp .. "/x.txt", "")
    local real = vim.uv.fs_realpath
    local _, flags = parse({ "--case=~/x.txt" })
    H.eq(real(flags[1]:sub(8)), real(H.tmp .. "/x.txt"))
    _, flags = parse({ "--case", "~/x.txt" })
    H.eq(flags[1], "--case")
    H.eq(real(flags[2]), real(H.tmp .. "/x.txt"))
    vim.env.HOME = home
    vim.cmd("enew")
    vim.api.nvim_buf_set_name(0, H.tmp .. "/0001-two-sum/solution.cpp")
    H.eq({ parse({ "%" }) }, { H.tmp .. "/0001-two-sum/solution.cpp", {} })
end)

test("problems by name, as lc finds them", function()
    needs_lc()
    local catalog = require("neo.plugins.lc.catalog")
    H.eq(catalog.find("1").slug, "two-sum")
    H.eq(catalog.find("0001").slug, "two-sum")
    H.eq(catalog.find("two-sum").id, 1)
    H.eq(catalog.find("0001-two-sum").id, 1)
    H.eq(catalog.find("0001-wrong-slug"), nil)
    H.eq(catalog.find("0001-"), nil)
    H.eq(catalog.find("nothing-like-it"), nil)
end)

test("a problem directory named by its slug or ID, as a link's target may be", function()
    needs_lc()
    local problem = require("neo.plugins.lc.problem")
    for _, name in ipairs({ "two-sum", "1" }) do
        local dir = ("%s/sols/%s"):format(H.tmp, name)
        vim.fn.mkdir(dir, "p")
        local info = problem.from_path(dir .. "/solution.cpp")
        H.eq(info and info.id, 1, name)
        H.eq(info.dir, dir)
    end
    H.eq(problem.from_path(H.tmp .. "/sols/0001-wrong/solution.cpp"), nil)
end)

test("paths keep their $", function()
    local info = require("neo.plugins.lc.problem").from_path("/nowhere/a$HOME/0001-two-sum/solution.cpp")
    H.eq(info.dir, "/nowhere/a$HOME/0001-two-sum")
end)

test("splitting :Lc's arguments", function()
    local split = require("neo.plugins.lc.commands").split_args
    H.eq(split([[test --case my\ cases.txt  1]]), { "test", "--case", [[my\ cases.txt]], "1" })
    H.eq(split(""), {})
end)

test("the reference's compiler output is shown once", function()
    local lines = require("neo.plugins.lc.run").render_lines({
        kind = "test",
        title = "1. Two Sum",
        error = "the reference solution ref.c does not compile:\nref.c:3:1: error: oops\n",
        ref_build = {},
        ref_done = { ok = false, output = "ref.c:3:1: error: oops\n" },
        finished = true,
        cases = {},
        diags = {},
        flags = {},
    })
    local n = 0
    for _, l in ipairs(lines) do
        if l:find("oops", 1, true) then
            n = n + 1
        end
    end
    H.eq(n, 1, vim.inspect(lines))
end)

test("drawing many cases is quick", function()
    local cases = {}
    for i = 1, 1000 do
        cases[i] = {
            index = i - 1,
            custom = true,
            file = "/home/someone/with-a-rather-long-directory-name-here/lc/0001-two-sum/cases.txt",
            line = i * 4,
            verdict = "accepted",
            time_ms = 1,
        }
    end
    local run = { kind = "test", title = "1. Two Sum", finished = true, cases = cases, diags = {}, flags = {} }
    local t0 = vim.uv.hrtime()
    for _ = 1, 10 do
        require("neo.plugins.lc.run").render_lines(run)
    end
    local ms = (vim.uv.hrtime() - t0) / 1e6 / 10
    H.ok(ms < 100, ("drawing 1000 cases took %d ms"):format(ms))
end)

test("bad options are errors", function()
    local config = require("neo.plugins.lc.config")
    local ok, err = pcall(config.setup, { picker = "nope" })
    H.ok(not ok)
    H.has(err, "picker")
    ok, err = pcall(config.setup, { result = 3 })
    H.ok(not ok)
    H.has(err, "result")
    ok, err = pcall(config.setup, { keys = { jump = true } })
    H.ok(not ok)
    H.has(err, "keys.jump")
    ok, err = pcall(config.setup, { keys = { addcase = "x" } })
    H.ok(not ok)
    H.has(err, "keys.addcase: no such key")
    H.eq(config.setup({ keys = { jump = false } }).keys.jump, false)
    -- A list replaces the default rather than being merged into it.
    H.eq(config.setup({ cmd = { "/x/lc", "--flag" } }).cmd, { "/x/lc", "--flag" })
    vim.g.lc = { open = "show" }
    H.eq(config.setup().open, "show")
    H.eq(config.setup({ open = "start" }).open, "start")
    vim.g.lc = nil
end)

test("options from overrides.lua, under vim.g.lc and setup()", function()
    local config = require("neo.plugins.lc.config")
    package.loaded["neo.overrides"] = { lc = { open = "show", cmd = "~/bin/lc" } }
    local o = config.setup()
    H.eq(o.open, "show")
    H.eq(o.cmd, vim.fs.normalize("~/bin/lc"))
    vim.g.lc = { open = "start", cmd = { "~/other/lc", "--flag" } }
    o = config.setup()
    H.eq(o.open, "start")
    H.eq(o.cmd, { vim.fs.normalize("~/other/lc"), "--flag" })
    H.eq(config.setup({ picker = "neo" }).picker, "neo")
    -- Other sections, and no lc section, are fine.
    vim.g.lc = nil
    package.loaded["neo.overrides"] = { graphical = { font_size = 20 } }
    H.eq(config.setup().cmd, "lc")
end)

-- Runs fn with vim.fn.has answering the features given, the rest as before.
local function with_has(features, fn)
    local has = vim.fn.has
    vim.fn.has = function(f)
        if features[f] ~= nil then
            return features[f]
        end
        return has(f)
    end
    local ok, err = pcall(fn)
    vim.fn.has = has
    if not ok then
        error(err, 0)
    end
end

test("setup loads only where lc runs", function()
    local lc = require("neo.plugins.lc")
    local fake = H.fake_lc("exit 0")
    H.eq(lc.setup({ cmd = fake }), true)
    H.eq(lc.enabled, true)
    H.eq(vim.fn.exists(":Lc"), 2)
    -- Without lc, :Lc goes, even when an earlier setup() made it.
    H.eq(lc.setup({ cmd = H.tmp .. "/no-lc" }), false)
    H.eq(lc.enabled, false)
    H.eq(vim.fn.exists(":Lc"), 0)
    H.eq(lc.setup({ cmd = fake }), true)
    -- Native Windows: nothing, whatever lc there is.
    with_has({ win32 = 1, unix = 0, wsl = 0 }, function()
        H.eq(lc.setup({ cmd = fake }), false)
    end)
    H.eq(lc.enabled, false)
    H.eq(vim.fn.exists(":Lc"), 0)
    -- WSL is Linux to Neovim: has("wsl"), never has("win32").
    with_has({ win32 = 0, unix = 1, wsl = 1 }, function()
        H.eq(lc.setup({ cmd = fake }), true)
    end)
    H.eq(vim.fn.exists(":Lc"), 2)
end)

test("a bad option turns lc off rather than stopping the config", function()
    local lc = require("neo.plugins.lc")
    H.eq(lc.setup({ cmd = H.fake_lc("exit 0"), picker = "telescope" }), false)
    H.eq(vim.fn.exists(":Lc"), 0)
    H.eq(H.note("bad option picker: neo or select").level, vim.log.levels.ERROR)
end)

test("keybinds/lc.lua maps keys only where lc loaded", function()
    local file = H.root .. "/../../keybinds/lc.lua"
    local lc = require("neo.plugins.lc")
    lc.setup({ cmd = H.tmp .. "/no-lc" })
    dofile(file)
    H.eq(vim.fn.maparg("<leader>tt", "n"), "")
    lc.setup({ cmd = H.fake_lc("exit 0") })
    dofile(file)
    H.eq(vim.fn.maparg("<leader>tl", "n"), "<Cmd>Lc list<CR>")
    H.eq(vim.fn.maparg("<leader>tt", "n"), "<Cmd>Lc test<CR>")
    H.eq(vim.fn.maparg("<leader>ts", "n"), "<Cmd>Lc submit<CR>")
    for _, lhs in ipairs({ "tl", "tt", "ts", "tr", "tx" }) do
        vim.keymap.del("n", "<leader>" .. lhs)
    end
end)

return tests
