-- lua/neo/plugins/scope/init.lua
local M = {}

local state = {
  prompt_buf = nil, prompt_win = nil,
  results_buf = nil, results_win = nil,
  items = {}, filtered = {},
  selected = 1, mode = "files",
  job_id = nil,
  ns_id = vim.api.nvim_create_namespace("scope_picker"),
}

-- Create grep augroup once at require-time
local GREP_AUGROUP = vim.api.nvim_create_augroup("ScopeGrep", { clear = true })

-- ─── Fuzzy Matcher ───────────────────────────────────────────────────────────
local function fuzzy_score(str, pattern)
  if not pattern or pattern == "" then return 1, {} end
  local s, p = str:lower(), pattern:lower()
  local p_idx, score, consec = 1, 0, 0

  for i = 1, #s do
    if s:sub(i, i) == p:sub(p_idx, p_idx) then
      p_idx = p_idx + 1
      consec = consec + 1
      score = score + 10 + consec
      if p_idx > #p then break end
    else
      consec = 0
    end
  end

  return p_idx <= #p and 0 or score, {}
end

-- ─── Debounce Helper (self-contained timer per instance) ─────────────────────
local function debounce(ms, fn)
  local timer = vim.uv.new_timer()
  return function(...)
    timer:stop()
    local args = {...}
    timer:start(ms, 0, vim.schedule_wrap(function() fn(unpack(args)) end))
  end
end

-- ─── UI Management ───────────────────────────────────────────────────────────
local function close_picker()
  if vim.api.nvim_get_mode().mode:match("i") then vim.cmd("stopinsert") end
  if state.job_id then vim.fn.jobstop(state.job_id) end
  for _, win in ipairs({ state.prompt_win, state.results_win }) do
    if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  state.items, state.filtered, state.selected = {}, {}, 1
end

local function create_ui(title)
  close_picker()
  local width = math.min(80, vim.o.columns - 4)
  local total_h = math.min(20, vim.o.lines - 4)
  local row = math.floor((vim.o.lines - total_h) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local base = { relative = "editor", style = "minimal", border = "rounded" }

  state.prompt_buf = vim.api.nvim_create_buf(false, true)
  state.prompt_win = vim.api.nvim_open_win(state.prompt_buf, true, vim.tbl_extend("force", base, {
    row = row, col = col, width = width, height = 1,
    title = title, title_pos = "left", zindex = 50,
  }))

  state.results_buf = vim.api.nvim_create_buf(false, true)
  state.results_win = vim.api.nvim_open_win(state.results_buf, false, vim.tbl_extend("force", base, {
    row = row + 3, col = col, width = width, height = math.max(5, total_h - 5),
    noautocmd = true, zindex = 51,
  }))

  vim.api.nvim_set_option_value("filetype", "scope_prompt", { buf = state.prompt_buf })
  vim.api.nvim_set_option_value("filetype", "scope_results", { buf = state.results_buf })
  vim.api.nvim_set_option_value("cursorline", true, { win = state.results_win })
  vim.api.nvim_set_option_value("wrap", false, { win = state.results_win })
  vim.api.nvim_set_option_value("scrolloff", 999, { win = state.results_win })
  vim.cmd("startinsert")
end

-- ─── Rendering ───────────────────────────────────────────────────────────────
local function render_results()
  if not state.results_buf or not vim.api.nvim_buf_is_valid(state.results_buf) then return end
  vim.api.nvim_buf_clear_namespace(state.results_buf, state.ns_id, 0, -1)
  local lines = {}
  for i, item in ipairs(state.filtered) do
    lines[i] = (i == state.selected and "▸ " or "  ") .. item.display
  end
  vim.api.nvim_buf_set_lines(state.results_buf, 0, -1, false, lines)
  if state.filtered[state.selected] then
    vim.api.nvim_win_set_cursor(state.results_win, { state.selected, 0 })
  end
end

local debounced_filter = debounce(30, function()
  local prompt = vim.api.nvim_buf_get_lines(state.prompt_buf, 0, 1, false)[1] or ""
  prompt = prompt:match("^%s*(.-)%s*$")

  state.selected = 1

  if state.mode == "grep" then
    -- Grep results are pre-filtered by rg/grep. Display as-is.
    state.filtered = state.items
  else
    local scored = {}
    for _, item in ipairs(state.items) do
      local s, _ = fuzzy_score(item.display, prompt)
      if s > 0 then table.insert(scored, { score = s, item = item }) end
    end
    table.sort(scored, function(a, b) return a.score > b.score end)
    state.filtered = vim.tbl_map(function(x) return x.item end, scored)
  end

  if #state.filtered == 0 then state.selected = 0 end
  render_results()
end)

-- ─── Input & Keymaps ─────────────────────────────────────────────────────────
local function setup_keymaps()
  local opts = { buffer = state.prompt_buf, silent = true, nowait = true }
  vim.keymap.set("i", "<CR>", function()
    local sel = state.filtered[state.selected]
    close_picker()
    if sel then sel.action(sel) end
  end, opts)
  vim.keymap.set("i", "<Esc>", close_picker, opts)
  vim.keymap.set("i", "<Up>", function()
    state.selected = math.max(1, state.selected - 1)
    render_results()
  end, opts)
  vim.keymap.set("i", "<Down>", function()
    state.selected = math.min(#state.filtered, state.selected + 1)
    render_results()
  end, opts)

  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = state.prompt_buf,
    callback = debounced_filter,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(state.prompt_win),
    once = true,
    callback = close_picker,
  })
end

-- ─── File Finder ─────────────────────────────────────────────────────────────
local function scan_files_async(callback)
  local cwd = vim.fn.getcwd()
  local files = {}
  local queue = { cwd }
  local idx = 1
  local count = 0
  local max_files = 50000
  local max_depth = 12

  local ignore = {
    [".git"] = true, [".svn"] = true, [".hg"] = true,
    ["node_modules"] = true, ["__pycache__"] = true,
    [".cache"] = true, ["vendor"] = true, ["target"] = true,
    [".venv"] = true, ["env"] = true, [".tox"] = true,
    ["dist"] = true, ["build"] = true, [".next"] = true,
  }

  local depths = { [cwd] = 0 }

  local step
  step = function()
    while idx <= #queue do
      local dir = queue[idx]
      local dir_depth = depths[dir] or 0
      idx = idx + 1

      if dir_depth >= max_depth then goto continue end

      local ok, iter_fn, iter_state, iter_var = pcall(vim.fs.dir, dir)
      if not ok then goto continue end

      for name, type in iter_fn, iter_state, iter_var do
        if type == "directory" then
          if not ignore[name] then
            local next_path = vim.fs.joinpath(dir, name)
            table.insert(queue, next_path)
            depths[next_path] = dir_depth + 1
          end
        elseif type == "file" or type == "link" then
          local full_path = vim.fs.joinpath(dir, name)
          table.insert(files, vim.fs.normalize(full_path))
          count = count + 1
          if count >= max_files then
            callback(files)
            return
          end
          if count % 1000 == 0 then
            vim.schedule(step)
            return
          end
        end
      end
      ::continue::
    end
    callback(files)
  end
  step()
end

-- ─── Live Grep ───────────────────────────────────────────────────────────────
local function run_grep_async(query, on_line, on_exit)
  local cwd = vim.fn.getcwd()
  local cmd
  if vim.fn.executable("rg") == 1 then
    cmd = { "rg", "--vimgrep", "--no-heading", "--color=never", "--", query }
  elseif vim.fn.has("win32") == 1 and vim.fn.executable("findstr") == 1 then
    cmd = { "findstr", "/s", "/n", "/c:" .. query, "*" }
  else
    cmd = { "grep", "-rn", "--color=never", "--", query, "." }
  end

  local line_buf = ""
  state.job_id = vim.fn.jobstart(cmd, {
    cwd = cwd,
    stdout_buffered = false,
    on_stdout = function(_, data)
      if not data then return end
      for _, chunk in ipairs(data) do
        line_buf = line_buf .. chunk
        while true do
          local nl = line_buf:find("\n", 1, true)
          if not nl then break end
          local line = line_buf:sub(1, nl - 1):gsub("\r$", "")
          line_buf = line_buf:sub(nl + 1)
          if line ~= "" then on_line(line) end
        end
      end
    end,
    on_stderr = function(_, data)
      if data and data[1] and data[1] ~= "" then
        vim.notify("Scope grep stderr: " .. data[1], vim.log.levels.WARN)
      end
    end,
    on_exit = function(_, code) on_exit(code) end,
  })

  if state.job_id <= 0 then
    vim.notify("Scope: Failed to start grep job. Check PATH.", vim.log.levels.ERROR)
  end
end

-- ─── Actions ─────────────────────────────────────────────────────────────────
local function open_file(path, line, col)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  if line and col then
    vim.api.nvim_win_set_cursor(0, { line, col - 1 })
  end
end

-- ─── Public API ──────────────────────────────────────────────────────────────
function M.find_files()
  state.mode = "files"
  state.items = {}
  create_ui(" Find Files ")
  setup_keymaps()
  vim.cmd("startinsert!")

  scan_files_async(function(files)
    state.items = vim.tbl_map(function(f)
      local rel = vim.fs.normalize(vim.fn.fnamemodify(f, ":.:"))
      return { display = rel, action = function() open_file(f) end }
    end, files)
    debounced_filter()
  end)
end

function M.live_grep()
  state.mode = "grep"
  state.items = {}
  create_ui(" Live Grep ")
  setup_keymaps()
  vim.cmd("startinsert!")

  local seen = {}
  local add_line = function(line)
    if seen[line] then return end
    seen[line] = true
    -- Greedy .+ backtracks to match the last :line:col: pair, safely handling Windows drives & colons in paths
    local file, lnum, col, text = line:match("^(.+):(%d+):(%d+):(.*)$")
    if not file then return end
    local full_path = vim.fs.normalize(vim.fn.joinpath(vim.fn.getcwd(), file))
    table.insert(state.items, {
      display = string.format("%s:%s:%s  %s", file, lnum, col, text),
      action = function() open_file(full_path, tonumber(lnum), tonumber(col)) end,
    })
    debounced_filter()
  end

  vim.api.nvim_clear_autocmds({ group = GREP_AUGROUP, buffer = state.prompt_buf })
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = GREP_AUGROUP,
    buffer = state.prompt_buf,
    callback = function()
      local query = vim.api.nvim_buf_get_lines(state.prompt_buf, 0, 1, false)[1] or ""
      query = query:match("^%s*(.-)%s*$")
      if #query < 2 then return end
      if state.job_id then vim.fn.jobstop(state.job_id) end
      state.items, seen = {}, {}
      run_grep_async(query, add_line, function() end)
    end,
  })
end

function M.setup()
  vim.api.nvim_create_user_command("ScopeFiles", M.find_files, { desc = "Scope: Find Files" })
  vim.api.nvim_create_user_command("ScopeGrep", M.live_grep, { desc = "Scope: Live Grep" })
end

return M
