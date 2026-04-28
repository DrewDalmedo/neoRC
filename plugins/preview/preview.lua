local M = {
    _preview_registry = {},
}

function M.register(ft, cmd) 
    M._preview_registry[ft] = cmd
end

function M.run_preview()
    local ft = vim.bo.filetype
    local cmd = M._preview_registry[ft]

    if cmd then
        vim.cmd(cmd)
    else
        vim.notify("No preview registered for filetype: " .. ft, vim.log.levels.ERROR)
    end
end

return M
