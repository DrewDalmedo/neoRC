vim.keymap.set("n", "<leader>a", "<cmd>Anchor add<cr>", { desc = "Anchor: Add File" })
vim.keymap.set("n", "<leader>m", "<cmd>Anchor menu<cr>", { desc = "Anchor: Edit the List" })
-- Slots 1 to 4. Not <C-m> for 4: terminals send it as <CR>, so mapping it
-- would take over Enter (in quickfix and the cmdline window too).
for i, key in ipairs({ "<C-p>", "<C-t>", "<C-s>", "<C-n>" }) do
    vim.keymap.set("n", key, "<cmd>Anchor " .. i .. "<cr>", { desc = "Anchor: Go to Slot " .. i })
end
