local M = {}

M.terminal_bufnr = nil

local valid_term_buf = function()
    return M.terminal_bufnr and vim.api.nvim_buf_is_valid(M.terminal_bufnr) and
        vim.api.nvim_buf_get_option(M.terminal_bufnr, "buftype") == "terminal"
end

function M.open_terminal_tab()
    if valid_term_buf() then
        local found_tab = false

        for i = 1, vim.fn.tabpagenr("$") do
            local tab_buffers = vim.fn.tabpagebuflist(i)

            for _, bufnr in ipairs(tab_buffers) do
                if bufnr == M.terminal_bufnr then
                    -- switch to terminal tab
                    vim.cmd(i .. "tabnext")
                    -- ensure we're focused on the terminal window within the tab
                    local win_id = vim.fn.win_findbuf(M.terminal_bufnr)[1]

                    if win_id then
                        vim.api.nvim_set_current_win(win_id)
                    end

                    found_tab = true
                    break
                end
            end

            if found_tab then break end
        end

        -- if terminal exists but not in a tab, open it in a new tab
        if not found_tab then
            vim.cmd("tabnew")
            vim.api.nvim_win_set_buf(0, M.terminal_bufnr)
        end
    else
        vim.cmd("tabnew")
        vim.cmd("terminal")

        M.terminal_bufnr = vim.api.nvim_get_current_buf()

        vim.cmd("startinsert")
    end
end

function M.open_terminal_buf() 
    -- check if terminal buffer exists and is valid
    if valid_term_buf() then
        local current_buf = vim.api.nvim_get_current_buf()

        if current_buf ~= M.terminal_bufnr then
            vim.api.nvim_set_current_buf(M.terminal_bufnr)
            vim.cmd("startinsert")
        end
    else -- no valid terminal exists, create new terminal buffer
        vim.cmd("terminal")

        M.terminal_bufnr = vim.api.nvim_get_current_buf()

        vim.cmd("startinsert")
    end
end

return M
