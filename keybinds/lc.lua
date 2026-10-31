-- lc is only loaded where lcclone's lc runs (see plugins/lc/init.lua)
if not require("neo.plugins.lc").enabled then return end

vim.keymap.set("n", "<leader>tl", "<cmd>Lc list<cr>", { desc = "lc: Pick a Problem" })
vim.keymap.set("n", "<leader>tt", "<cmd>Lc test<cr>", { desc = "lc: Test" })
vim.keymap.set("n", "<leader>ts", "<cmd>Lc submit<cr>", { desc = "lc: Submit" })
vim.keymap.set("n", "<leader>tr", "<cmd>Lc result<cr>", { desc = "lc: Show the Result" })
vim.keymap.set("n", "<leader>tx", "<cmd>Lc cancel<cr>", { desc = "lc: Cancel the Run" })
