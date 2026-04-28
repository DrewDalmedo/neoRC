vim.api.nvim_create_autocmd("FileType", {
    pattern = "netrw",
    callback = function()
        -- enable line numbers
        vim.opt_local.number = true
        vim.opt_local.relativenumber = true
    end,
})

-- entering text files
vim.api.nvim_create_autocmd("BufEnter", {
    pattern = "*.txt",
    callback = function()
        -- help files
        if vim.bo.buftype == "help" then
            vim.opt_local.number = true
            vim.opt_local.relativenumber = true
        end
    end,
})

-- man pages
vim.api.nvim_create_autocmd("FileType", {
    pattern = "man",
    callback = function()
        vim.opt_local.number = true
        vim.opt_local.relativenumber = true
    end,
})

-- terminal
vim.api.nvim_create_autocmd("TermOpen", {
    pattern = "*",
    callback = function()
        vim.opt_local.relativenumber = true
    end,
})
