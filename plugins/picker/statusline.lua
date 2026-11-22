-- lua/neo/plugins/picker/statusline.lua
-- The file name on the statusline, with the project in front of it. A file
-- inside the working directory shows as
--
--   neo: sub/file.txt
--
-- where %f alone shows sub/file.txt. The project is the window's working
-- directory (its own after :lcd or :tcd), named after its basename unless
-- a namer knows better: the projects plugin registers one, so a project it
-- lists under another name (name = "Config") shows under that name. The
-- home directory and the filesystem root aren't projects. Everything that
-- isn't a file inside a project (files elsewhere, help, terminals, netrw,
-- [No Name]) shows the way %f shows it.
--
-- A file anchored in the window's project shows its slot first, as the key
-- that opens it, or its number for a slot without one,
--
--   [T] neo: sub/file.txt
--
-- (and "[T] " goes in front of %f's name for one outside the project).
-- The anchor plugin registers the slotter that knows the slots, as the
-- projects plugin registers the namer.
--
-- setup() puts M.file() where 'statusline' has %f (Neovim's default
-- statusline when none is set) and keeps the rest of it as it was.
local M = {}

local ITEM = "%{%v:lua.require('neo.plugins.picker.statusline').file()%}"
-- The item for a %< right before %f. It carries the %< itself, after the
-- slot, so a name too long for the window is cut without losing the slot.
local CUT_ITEM = "%{%v:lua.require('neo.plugins.picker.statusline').file(1)%}"
-- Older Neovim leaves 'statusline' empty for its built-in one; this is
-- that one written out.
local BUILTIN = "%<%f %h%w%m%r%=%-14.(%l,%c%V%) %P"

local namer = nil
local slotter = nil
-- Project names by working directory: the namer can walk the tracked
-- directories, and the statusline is drawn on every cursor move. "" marks
-- a directory that isn't a project.
local names = {}

local function real(path)
    return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

-- fn(dir) gets an absolute directory and returns the project's name, or
-- nil to leave it to the basename.
function M.set_namer(fn)
    namer = fn
    names = {}
end

-- fn(path, dir) gets a buffer's file (absolute) and a window's working
-- directory, and returns what to show for the file's slot in that project
-- (a number, or text such as the key that opens it), or nil when it has
-- none. It is asked on every redraw of every statusline, so it has to be
-- cheap.
function M.set_slotter(fn)
    slotter = fn
end

-- Drop the remembered names, for when the namer's answers change (the
-- projects plugin calls it when the tracked set does).
function M.forget()
    names = {}
end

-- The name of the project at dir (default: the current window's working
-- directory), or nil when dir is the home directory or a root.
function M.project(dir)
    dir = dir or vim.fn.getcwd(0)
    if names[dir] == nil then
        local ok, name = pcall(function() return namer and namer(dir) end)
        if not ok or type(name) ~= "string" or name == "" then
            local path = real(dir)
            name = path ~= real(vim.uv.os_homedir()) and vim.fs.basename(path) or ""
        end
        names[dir] = name
    end
    return names[dir] ~= "" and names[dir] or nil
end

local windows = vim.fn.has("win32") == 1
-- file names that differ only in case are the same file here
local fold_case = windows or vim.fn.has("mac") == 1

-- path relative to dir, or nil when it isn't inside dir. Not
-- fnamemodify(":."): that goes by the current window's directory, and a
-- statusline can be another window's, with its own :lcd.
local function relative(path, dir)
    path = vim.fs.normalize(path, { expand_env = false })
    dir = vim.fs.normalize(dir, { expand_env = false }):gsub("/$", "") .. "/"
    local head = path:sub(1, #dir)
    if #path <= #dir or (head ~= dir and not (fold_case and head:lower() == dir:lower())) then
        return nil
    end
    local rel = path:sub(#dir + 1)
    if windows and not vim.o.shellslash then
        rel = rel:gsub("/", "\\")
    end
    return rel
end

-- "project: path/to/file.txt" for buffer buf (default: the current one)
-- shown in the current window, or nil when the buffer isn't a file inside
-- that window's project.
function M.label(buf)
    buf = buf or 0
    if vim.bo[buf].buftype ~= "" then return nil end
    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" then return nil end
    -- getcwd(0), not getcwd(): drawing another window's statusline, the
    -- latter gives the current window's directory
    local dir = vim.fn.getcwd(0)
    local rel = relative(name, dir)
    local project = rel and M.project(dir)
    return project and (project .. ": " .. rel) or nil
end

-- The slot of buffer buf (default: the current one) in the current
-- window's project, as text to show ("T", "2"), or nil when it has none
-- or isn't a file.
function M.slot(buf)
    buf = buf or 0
    if not slotter or vim.bo[buf].buftype ~= "" then return nil end
    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" then return nil end
    local ok, slot = pcall(slotter, name, vim.fn.getcwd(0))
    if not ok then return nil end
    if type(slot) == "number" and slot >= 1 and slot % 1 == 0 then
        return ("%d"):format(slot)
    end
    if type(slot) == "string" and slot ~= "" then
        return slot
    end
    return nil
end

-- text as statusline text: its %s are literal
local function escape(text)
    return (text:gsub("%%", "%%%%"))
end

-- The statusline item: %{%...%} evaluates it in the window whose statusline
-- is being drawn, and reads the result as statusline text. With cut, the
-- statusline's truncation point (%<) goes between the slot and the name.
function M.file(cut)
    local ok, slot = pcall(M.slot)
    local prefix = ok and slot and escape("[" .. slot .. "] ") or ""
    if cut then prefix = prefix .. "%<" end
    local label
    ok, label = pcall(M.label)
    if not ok or not label then return prefix .. "%f" end
    return prefix .. escape(label)
end

-- Put M.file() in place of %f in the global 'statusline', taking over a %<
-- right before it. A statusline without %f is left alone.
function M.setup()
    local current = vim.go.statusline
    if current:find(ITEM, 1, true) or current:find(CUT_ITEM, 1, true) then return end
    local line = current ~= "" and current or BUILTIN
    -- item by item, so a literal %% followed by an f isn't taken for %f
    local found, cut = false, false
    local with = line:gsub("()%%(.)", function(pos, c)
        if found then return nil end
        if c == "<" and line:sub(pos + 2, pos + 3) == "%f" then
            cut = true
            return ""
        end
        if c == "f" then
            found = true
            return cut and CUT_ITEM or ITEM
        end
    end)
    if found then
        vim.go.statusline = with
    end
end

return M
