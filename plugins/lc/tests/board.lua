-- lua/neo/plugins/lc/tests/board.lua
-- The malleable views: :Lc problems, and the keys of stats and the statement.

local H = require("neo.plugins.lc.tests.helpers")
local tests = {}
local function test(name, fn)
    tests[#tests + 1] = { name, fn }
end

local NAME = "lc://problems"

local function board()
    local buf = vim.fn.bufnr(NAME)
    H.ok(buf > 0, "no board")
    return buf
end

-- The cursor on the first line containing s, in the current window.
local function on(s)
    for i, l in ipairs(H.lines(0)) do
        if l:find(s, 1, true) then
            vim.api.nvim_win_set_cursor(0, { i, 0 })
            return i
        end
    end
    error(("no line %q"):format(s), 2)
end

local function line()
    return vim.api.nvim_get_current_line()
end

-- vim.ui.select answering with the first item format_item shows s in.
local function answer(s)
    vim.ui.select = function(list, opts, on_choice)
        for _, item in ipairs(list) do
            if opts.format_item(item):find(s, 1, true) then
                return on_choice(item)
            end
        end
        on_choice(nil)
    end
end

test("opens alone, closing everything else as projects does", function()
    local file = H.tmp .. "/note.txt"
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "saved" })
    vim.cmd("vsplit | enew | tabnew")
    vim.cmd("Lc problems")
    H.no_errors()
    H.eq(vim.api.nvim_buf_get_name(0), NAME)
    H.eq(#vim.api.nvim_list_tabpages(), 1)
    H.eq(#vim.api.nvim_tabpage_list_wins(0), 1)
    H.eq(vim.api.nvim_list_bufs(), { board() })
    H.eq(H.read(file), "saved\n")
    H.eq(vim.w.lc_result, nil)
    H.eq(vim.bo.buftype, "nofile")
    H.eq(vim.bo.modifiable, false)
    H.ok(H.lines(0)[1]:match("^Problems: %d+ of %d+$"), H.lines(0)[1])
    H.has(line(), "Two Sum")
end)

test("taking over the result panel's window leaves it an ordinary one", function()
    vim.cmd("Lc stats")
    vim.api.nvim_set_current_win(vim.fn.win_findbuf(vim.fn.bufnr("lc://stats"))[1])
    vim.cmd("Lc problems")
    H.eq(#vim.api.nvim_tabpage_list_wins(0), 1)
    H.eq(vim.w.lc_result, nil)
    H.eq(vim.wo.winfixheight, false)
end)

test("opens from a float", function()
    local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
        relative = "editor", row = 1, col = 1, width = 10, height = 2,
    })
    vim.cmd("Lc problems")
    H.no_errors()
    H.ok(not vim.api.nvim_win_is_valid(float), "the float should be gone")
    H.eq(vim.api.nvim_buf_get_name(0), NAME)
    H.eq(vim.api.nvim_win_get_config(0).relative, "")
end)

test("asks before discarding a view's unsaved edits", function()
    local view = require("neo.plugins.malleable").open({
        name = "test://edits",
        editable = true,
        on_write = function(_, done)
            done(true)
        end,
    })
    vim.api.nvim_win_set_buf(0, view.buf)
    vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, { "edited" })
    local function question()
        H.wait(function()
            return vim.bo.filetype == "malleable_confirm"
        end, "the question")
        H.has(H.lines(0), "test://edits")
    end
    vim.cmd("Lc problems --difficulty easy")
    question()
    H.keys("n")
    H.eq(vim.api.nvim_get_current_buf(), view.buf)
    H.eq(H.lines(view.buf), { "edited" })
    H.eq(vim.fn.bufexists(NAME), 0)
    vim.cmd("Lc problems --difficulty easy")
    question()
    H.keys("y")
    H.eq(vim.api.nvim_buf_get_name(0), NAME)
    H.has(H.lines(0)[1], "· easy")
    H.ok(not vim.api.nvim_buf_is_valid(view.buf), "the view should be gone")
end)

test("a board on screen updates without closing what's beside it", function()
    vim.cmd("Lc problems")
    on("Palindrome Number")
    H.keys("p")
    vim.cmd("Lc problems --difficulty easy")
    H.eq(#vim.api.nvim_tabpage_list_wins(0), 2)
    H.ok(vim.fn.bufexists("lc://problem/0009-palindrome-number") == 1)
    H.has(H.lines(board())[1], "· easy")
end)

test("filters keep the cursor on its problem", function()
    vim.cmd("Lc problems")
    on("Palindrome Number")
    H.keys("fd")
    H.has(H.lines(0)[1], "· easy")
    H.has(line(), "Palindrome Number")
    for _, l in ipairs(vim.list_slice(H.lines(0), 3)) do
        H.has(l, "Easy")
    end
    H.keys("fd")
    H.has(H.lines(0)[1], "· medium")
    H.keys("fd")
    H.keys("fd")
    H.hasnt(H.lines(0)[1], "·")
    H.keys("fs")
    H.has(H.lines(0)[1], "· todo")
    H.keys("fc")
    H.hasnt(H.lines(0)[1], "·")
    H.no_errors()
end)

test("tags come from the picker, narrow together and toggle off", function()
    vim.cmd("Lc problems")
    answer(" array ")
    H.keys("ft")
    H.has(H.lines(0)[1], "#array")
    local one = #H.lines(0)
    answer(" hash-table ")
    H.keys("ft")
    H.has(H.lines(0)[1], "#array · #hash-table")
    H.ok(#H.lines(0) < one, "a second tag should narrow the list")
    answer("* array")
    H.keys("ft")
    H.hasnt(H.lines(0)[1], "#array")
    H.has(H.lines(0)[1], "#hash-table")
end)

test("F finds a problem and stays on the board", function()
    vim.cmd("Lc problems")
    answer("Climbing Stairs")
    H.keys("F")
    H.eq(vim.api.nvim_buf_get_name(0), NAME)
    H.has(line(), "Climbing Stairs")
end)

-- The solution beside its statement, with the board gone.
local function solution_open()
    H.no_errors()
    H.ok(vim.api.nvim_buf_get_name(0):match("/0009%-palindrome%-number/solution%.cpp$"), vim.api.nvim_buf_get_name(0))
    H.eq(#vim.fn.win_findbuf(board()), 0, "the board should be gone")
    H.eq(#vim.api.nvim_tabpage_list_wins(0), 2)
    H.eq(vim.fn.winlayout()[1], "row")
end

test("<CR> starts the problem and the board goes away", function()
    vim.cmd("Lc problems --difficulty easy")
    on("Palindrome Number")
    H.keys("<CR>")
    solution_open()
    -- It comes back with its filters.
    vim.cmd("Lc problems")
    H.has(H.lines(board())[1], "· easy")
end)

test("s starts it from beside its statement", function()
    vim.cmd("Lc problems")
    on("Palindrome Number")
    H.keys("p")
    H.keys("s")
    solution_open()
end)

test("p opens the statement in a vertical split beside the board", function()
    vim.cmd("Lc problems")
    on("Palindrome Number")
    H.keys("p")
    H.no_errors()
    H.eq(vim.api.nvim_buf_get_name(0), NAME)
    H.eq(vim.fn.winlayout()[1], "row")
    H.eq(#vim.api.nvim_tabpage_list_wins(0), 2)
    local statement = vim.fn.bufnr("lc://problem/0009-palindrome-number")
    H.ok(statement > 0, "no statement")
    H.has(H.lines(statement), "# 9. Palindrome Number")
end)

test("<CR> with open = show keeps the board", function()
    require("neo.plugins.lc").setup({ cmd = H.lc, open = "show" })
    vim.cmd("Lc problems")
    on("Palindrome Number")
    H.keys("<CR>")
    H.eq(vim.api.nvim_buf_get_name(0), NAME)
    H.eq(vim.fn.winlayout()[1], "row")
end)

test("a problem that can't start keeps the board", function()
    vim.cmd("Lc problems")
    on("Palindrome Number")
    require("neo.plugins.lc").setup({ cmd = H.fake_lc("echo nope >&2; exit 1") })
    H.keys("s")
    H.ok(#H.notes > 0, "the error should be shown")
    H.eq(vim.api.nvim_buf_get_name(0), NAME)
    H.eq(#vim.api.nvim_tabpage_list_wins(0), 1)
end)

test("the statement's s starts its problem", function()
    vim.cmd("Lc show 9")
    vim.api.nvim_set_current_win(vim.fn.win_findbuf(vim.fn.bufnr("lc://problem/0009-palindrome-number"))[1])
    H.keys("s")
    H.no_errors()
    H.ok(vim.api.nvim_buf_get_name(0):match("/0009%-palindrome%-number/solution%.cpp$"), vim.api.nvim_buf_get_name(0))
end)

test("the statement's s closes a board beside it", function()
    vim.cmd("Lc problems")
    on("Palindrome Number")
    H.keys("p")
    vim.api.nvim_set_current_win(vim.fn.win_findbuf(vim.fn.bufnr("lc://problem/0009-palindrome-number"))[1])
    H.keys("s")
    solution_open()
end)

test("no matches keep the board open", function()
    vim.cmd("Lc problems --tag no-such-tag")
    H.no_errors()
    H.has(H.lines(board()), "No problem matches these filters")
    H.keys("fc")
    H.has(H.lines(board()), "Two Sum")
end)

test("bad filters are refused and change nothing", function()
    vim.cmd("Lc problems --difficulty easy")
    local before = H.lines(board())
    vim.cmd("Lc problems --difficulty nope")
    H.eq(H.note("nope").level, vim.log.levels.ERROR)
    H.eq(H.lines(board()), before)
    H.notes = {}
    vim.cmd("Lc problems --bogus x")
    H.has(H.note("unknown argument '--bogus'").msg, "--difficulty")
    H.notes = {}
    vim.cmd("Lc problems --tag=array --bogus=x")
    H.note("unknown argument '--bogus=x'")
    H.notes = {}
    vim.cmd("Lc problems --tag")
    H.note("--tag needs a value")
    H.eq(H.lines(board()), before)
end)

test("filters on the command line, in both forms", function()
    vim.cmd("Lc problems --difficulty=easy --tag string --tag=math")
    H.has(H.lines(board())[1], "· easy · #string · #math")
    -- Without arguments, the board keeps them.
    vim.cmd("Lc problems")
    H.has(H.lines(board())[1], "· easy · #string · #math")
end)

test("<CR> in stats opens the board filtered by the row", function()
    vim.cmd("Lc stats")
    vim.api.nvim_set_current_win(vim.fn.win_findbuf(vim.fn.bufnr("lc://stats"))[1])
    on("Medium")
    H.keys("<CR>")
    H.eq(vim.api.nvim_buf_get_name(0), NAME)
    H.has(H.lines(0)[1], "· medium")

    vim.cmd("Lc stats")
    vim.api.nvim_set_current_win(vim.fn.win_findbuf(vim.fn.bufnr("lc://stats"))[1])
    on("array")
    H.keys("<CR>")
    H.has(H.lines(board())[1], "#array")
end)

test("a submission updates a board on screen", function()
    local solution = H.start(1, "cpp", "two-sum/ok.cpp")
    vim.cmd("Lc problems --status solved")
    H.has(H.lines(board()), "No problem matches")
    -- The run's panel opens under the board.
    H.run("Lc submit " .. vim.fn.fnameescape(solution))
    H.eq(#vim.fn.win_findbuf(board()), 1)
    H.has(H.lines(board()), "Two Sum")
end)

test("a redraw waits for a Visual selection to end", function()
    vim.cmd("Lc problems")
    local before = H.lines(0)
    vim.api.nvim_feedkeys("V", "nx!", false)
    H.eq(vim.api.nvim_get_mode().mode, "V")
    require("neo.plugins.lc.board").open({ difficulty = "hard" })
    H.eq(H.lines(0), before, "the lines moved under the selection")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    H.wait(function()
        return H.lines(board())[1]:find("· hard", 1, true) ~= nil
    end, "the held redraw")
end)

test("g? lists a view's keys, and options apply", function()
    require("neo.plugins.lc").setup({ cmd = H.lc, keys = { close = "Q", help = "K" } })
    vim.cmd("Lc problems")
    H.keys("K")
    H.eq(vim.bo.filetype, "malleable_help")
    H.has(H.lines(0), "Next difficulty")
    H.has(H.lines(0), "Close the window")
    vim.api.nvim_win_close(0, true)
    H.keys("Q")
    H.ok(vim.api.nvim_buf_get_name(0) ~= NAME, "Q should close the board")
end)

test("the views come back after :bwipeout", function()
    vim.cmd("Lc problems --difficulty easy")
    vim.cmd("bwipeout! " .. board())
    vim.cmd("Lc problems")
    -- The filters went with the board.
    H.hasnt(H.lines(board())[1], "·")
    H.keys("fd")
    H.has(H.lines(board())[1], "· easy")
end)

return tests
