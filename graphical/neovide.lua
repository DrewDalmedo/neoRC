vim.o.background = "dark"
vim.cmd("color retrobox")

vim.g.neovide_cursor_animation_length = 0

-- fullscreen
vim.keymap.set("n", "<F11>", "<cmd>lua vim.g.neovide_fullscreen = not vim.g.neovide_fullscreen<cr>", { noremap = true, silent = true })

-- live resizing
vim.keymap.set({ "n", "v" }, "<C-=>", "<cmd>lua vim.g.neovide_scale_factor = vim.g.neovide_scale_factor + 0.1<cr>", { noremap = true, silent = true })
vim.keymap.set({ "n", "v" }, "<C-->", "<cmd>lua vim.g.neovide_scale_factor = vim.g.neovide_scale_factor - 0.1<cr>", { noremap = true, silent = true })
vim.keymap.set({ "n", "v" }, "<C-0>", "<cmd>lua vim.g.neovide_scale_factor = 1<cr>", { noremap = true, silent = true })
