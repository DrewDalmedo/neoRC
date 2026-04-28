-- general
map({"n", "v"}, "<C-;>", "<cmd>w<cr>")
map("i", "<C-;>", function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    vim.cmd("write")
end)
map("t", "<C-;>", "<C-\\><C-n><cr>")

map("n", "<leader>f", "<cmd>Ex<cr>")

map("n", "<C-d>", "<C-d>zz")
map("n", "<C-u>", "<C-u>zz")
map("n", "n", "nzzzv")
map("n", "N", "Nzzzv")
map("n", "<C-h>", "<C-6>")

map("n", "<leader>nv", "<cmd>noh<cr>")

map("n", "<leader>e", "<cmd>enew<cr>")

local home_path = vim.fn.expand("~")
local config_path = vim.fs.joinpath(vim.fn.stdpath("config"), "lua/neo")

map("n", "<leader>cc", "<cmd>cd %:p:h<cr>")
map("n", "<leader>ch", "<cmd>cd " .. home_path .. "<cr>")
map("n", "<leader>cn", "<cmd>cd " .. config_path .. "<cr>")

