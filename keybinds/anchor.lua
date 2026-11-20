vim.keymap.set("n", "<leader>a", "<cmd>Anchor add<cr>", { desc = "Anchor: Add File" })
vim.keymap.set("n", "<leader>m", "<cmd>Anchor menu<cr>", { desc = "Anchor: Edit the List" })
-- Slots 1 to 4, in this order; the statusline shows an anchored file's key
-- ("[C-t] neo: init.lua"). Not <C-m> for 4: terminals send it as <CR>, so
-- mapping it would take over Enter (in quickfix and the cmdline window too).
require("neo.plugins.anchor").map({ "<C-p>", "<C-t>", "<C-s>", "<C-n>" })
