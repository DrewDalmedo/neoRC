-- lua/neo/plugins/lc/cli.lua
-- Running lc: every call goes through `lc ... --json`, whose output is
-- described in lcclone's docs/json.md.
--
-- lc runs as a job (jobstart) rather than through vim.system: in Neovim
-- 0.10, vim.system closes the output pipes as soon as the process exits,
-- which can lose lc's last line (the done event). A job's on_exit comes
-- after its output, in every version.

local config = require("neo.plugins.lc.config")

local M = {}

--- The JSON schema this plugin reads.
M.SCHEMA = 1

--- Standards set with :Lc std for this session, passed to every lc process
--- as LC_CSTD and LC_CXXSTD. nil leaves lc's own setting.
M.std = { c = nil, cpp = nil }

--- The command line for lc with these arguments.
function M.argv(args)
    local cmd = config.get().cmd
    local argv = type(cmd) == "string" and { cmd } or vim.deepcopy(cmd)
    return vim.list_extend(argv, args)
end

--- Environment variables lc gets on top of Neovim's.
function M.env()
    local env = {}
    if M.std.c then
        env.LC_CSTD = M.std.c
    end
    if M.std.cpp then
        env.LC_CXXSTD = M.std.cpp
    end
    return next(env) and env or nil
end

--- Decodes one line of lc's JSON. JSON null becomes nil.
function M.decode(line)
    local ok, doc = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(doc) == "table" then
        return doc
    end
    return nil
end

--- A document's error, if it is an error document or of another schema.
function M.doc_error(doc)
    if doc.schema ~= M.SCHEMA then
        return ("lc writes JSON schema %s but the lc plugin reads schema %d: update the older one"):format(
            tostring(doc.schema),
            M.SCHEMA
        )
    end
    if doc.error then
        return doc.error.message or "lc failed"
    end
    return nil
end

--- A job's exit status as lc's exit code and the signal that killed it.
--- A job killed by signal N exits with 128 + N; lc itself exits with 130
--- after ^C, which means the same as being killed by SIGINT.
local function exit_status(code)
    if code > 128 and code ~= 130 then
        return code, code - 128
    end
    return code, nil
end

local function start_job(args, opts)
    local argv = M.argv(args)
    if vim.fn.executable(argv[1]) ~= 1 then
        return nil, ("can't run %s: no such executable"):format(argv[1])
    end
    opts = vim.tbl_extend("force", { env = M.env(), stdin = "null" }, opts)
    local ok, id = pcall(vim.fn.jobstart, argv, opts)
    if not ok or type(id) ~= "number" or id <= 0 then
        return nil, ("can't run %s%s"):format(argv[1], ok and "" or ": " .. tostring(id))
    end
    return id
end

--- Runs `lc <args> --json` and waits for it. Returns the document, or nil
--- and an error message (lc's own, when it gave one) and the error
--- document if there was one.
function M.json(args, timeout)
    local out, err = {}, {}
    local id, serr = start_job(vim.list_extend(vim.deepcopy(args), { "--json" }), {
        stdout_buffered = true,
        stderr_buffered = true,
        on_stdout = function(_, data)
            out = data
        end,
        on_stderr = function(_, data)
            err = data
        end,
    })
    if not id then
        return nil, serr
    end
    local status = vim.fn.jobwait({ id }, timeout or 30000)[1]
    if status < 0 then
        pcall(vim.fn.jobstop, id)
        return nil, status == -1 and "lc took too long" or "lc was interrupted"
    end
    local line = table.concat(out, "\n"):match("[^\n]+")
    local doc = line and M.decode(line)
    if not doc then
        local msg = vim.trim(table.concat(err, "\n")):gsub("^lc: ", "")
        if msg == "" then
            local code, signal = exit_status(status)
            msg = signal and ("lc was killed by signal %d"):format(signal) or ("lc exited with status %d"):format(code)
        end
        return nil, msg
    end
    local derr = M.doc_error(doc)
    if derr then
        return nil, derr, doc
    end
    return doc
end

-- A running lc.
local Proc = {}
Proc.__index = Proc

--- Sends the process a signal (a number), unless it has exited.
function Proc:kill(signal)
    if self.pid and not self.exited then
        pcall(vim.uv.kill, self.pid, signal)
    end
end

--- Runs `lc <args> --json` in the background. on_doc(doc) is called for
--- every JSON line as it arrives, then on_exit(code, stderr, signal) once
--- lc has exited and its output has been read. Returns an object with
--- :kill(signal), or nil and an error message.
function M.stream(args, on_doc, on_exit)
    local partial, stderr = "", {}
    local proc = setmetatable({}, Proc)

    local function deliver(line)
        if line ~= "" then
            local doc = M.decode(line)
            if doc then
                on_doc(doc)
            end
        end
    end

    local id, err = start_job(vim.list_extend(vim.deepcopy(args), { "--json" }), {
        -- data is a list of lines: the first continues the last call's
        -- unfinished line, and the last is unfinished ("" after a newline).
        on_stdout = function(_, data)
            data[1] = partial .. data[1]
            partial = table.remove(data)
            for _, line in ipairs(data) do
                deliver(line)
            end
        end,
        -- Joining each call's lines with newlines gives back the stream.
        on_stderr = function(_, data)
            stderr[#stderr + 1] = table.concat(data, "\n")
        end,
        on_exit = function(_, status)
            proc.exited = true
            local last = partial
            partial = ""
            deliver(last)
            local code, signal = exit_status(status)
            on_exit(code, table.concat(stderr), signal)
        end,
    })
    if not id then
        return nil, err
    end
    proc.id, proc.pid = id, vim.fn.jobpid(id)
    return proc
end

return M
